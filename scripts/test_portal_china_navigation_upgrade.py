#!/usr/bin/env python3
"""Exercise the real populated pre-revision database, never a hosted target.

Start a uniquely named issue-662 isolated Supabase project from the base commit,
then pass its Docker database container. This applies the revision directly;
reset that disposable project afterwards to verify the complete migration history.
"""
import argparse
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / 'supabase/migrations/20260920095651_portal_china_administrative_navigation.sql'

SEED = r"""
\set ON_ERROR_STOP on
begin;
do $$ begin
  if exists(select 1 from public.processes) or exists(select 1 from public.flows) then
    raise exception 'Upgrade fixture requires an empty disposable source database';
  end if;
  if (select count(*) from private.portal_navigation_node_v1
      where node_id in ('geo:tw','geo:hk','geo:mo') and parent_node_id is null) <> 3 then
    raise exception 'Upgrade fixture requires the actual pre-revision hierarchy';
  end if;
end $$;
create temp table prior_roles as
  select roleid from pg_auth_members where member='postgres'::regrole;
grant portal_public_executor,api_internal_executor to postgres;
create temp table prior_triggers as
  select tgrelid,tgname,tgenabled from pg_trigger
  where tgrelid in ('public.processes'::regclass,'public.flows'::regclass) and not tgisinternal;
alter table public.processes disable trigger user;
alter table public.processes enable trigger portal_catalog_projection_content_sync_v1;
alter table public.processes enable trigger portal_catalog_projection_content_sync_v2;
alter table public.flows disable trigger user;
alter table public.flows enable trigger portal_catalog_projection_content_sync_v1;
create function pg_temp.payload(code text,is_flow boolean) returns jsonb language sql as $$
 select jsonb_build_object(case when is_flow then 'flowDataSet' else 'processDataSet' end,
 jsonb_build_object(case when is_flow then 'flowInformation' else 'processInformation' end,
 jsonb_build_object('dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName',
 jsonb_build_object('@xml:lang','en','#text','Upgrade662'))),
 'geography',jsonb_build_object(case when is_flow then 'locationOfSupply' else 'locationOfOperationSupplyOrProduction' end,
 jsonb_build_object('@location',code))),
 'administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object(
 'common:licenseType','Free of charge for all users and uses'))))
$$;
insert into public.processes(id,version,json,state_code,modified_at)
select ('66210000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 '01.00.'||lpad(v::text,3,'0'),pg_temp.payload(code,false),100,'2026-09-20'
from unnest(array['TW','HK','MO','CN','US']) with ordinality g(code,i),generate_series(0,15) v;
insert into public.flows(id,version,json,state_code,modified_at)
select ('66220000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 '01.00.'||lpad(v::text,3,'0'),pg_temp.payload(code,true),100,'2026-09-20'
from unnest(array['TW','HK','MO','CN','US']) with ordinality g(code,i),generate_series(0,15) v;
set constraints all immediate;
create temp table prior_nodes as select * from private.portal_navigation_node_v1;
create temp table prior_members as select * from private.portal_navigation_membership_v1;
create temp table prior_versions as select * from private.portal_navigation_versions_v1;
create temp table prior_sources as
 select 'process' kind,id,version,json,state_code,modified_at from public.processes
 union all select 'flow',id,version,json,state_code,modified_at from public.flows;
do $$ begin
 if (select count(*) from prior_members where dimension='geography' and node_id='geo:cn') <> 32 then
   raise exception 'The pre-revision country must contain only its 32 direct versions';
 end if;
end $$;
commit;
"""

VERIFY = r"""
begin;
do $$ begin
 if (select count(*) from private.portal_navigation_membership_v1 m
     where dimension='geography' and node_id='geo:cn') <> 128 then
   raise exception 'Country backfill did not add exactly 96 unique ancestor versions';
 end if;
 if (select count(*) from private.portal_navigation_membership_v1
     where dimension='geography' and node_id='geo:cn' and direct) <> 32 then
   raise exception 'Existing direct country placements changed';
 end if;
 if exists(select * from prior_members except select * from private.portal_navigation_membership_v1) then
   raise exception 'Backfill removed or changed existing memberships';
 end if;
 if exists(select * from private.portal_navigation_membership_v1
   except select * from prior_members
   except select dataset_kind,id,version,'geography','geo:cn',false from prior_members
     where dimension='geography' and node_id in ('geo:tw','geo:hk','geo:mo')) then
   raise exception 'Backfill added an unrelated membership';
 end if;
 if exists(select * from prior_versions except select * from private.portal_navigation_versions_v1)
 or exists(select * from private.portal_navigation_versions_v1 except select * from prior_versions) then
   raise exception 'Narrow version facts changed';
 end if;
 if exists(select to_jsonb(n)-'parent_node_id' from prior_nodes n
   except select to_jsonb(n)-'parent_node_id' from private.portal_navigation_node_v1 n)
 or (select count(*) from private.portal_navigation_node_v1) <> (select count(*) from prior_nodes)
 or exists(select node_id,parent_node_id from private.portal_navigation_node_v1
   where node_id not in ('geo:tw','geo:hk','geo:mo')
   except select node_id,parent_node_id from prior_nodes) then
   raise exception 'Vocabulary changed beyond the three reviewed parent fields';
 end if;
 if exists(select * from prior_sources except
   (select 'process',id,version,json,state_code,modified_at from public.processes
    union all select 'flow',id,version,json,state_code,modified_at from public.flows)) then
   raise exception 'Original dataset rows changed';
 end if;
 perform private.assert_portal_navigation_projection_v1();
end $$;
set local role anon;
do $$ declare page jsonb; begin
 page:=api.portal_navigation_v1('all','Upgrade662','{}','geography','geo:cn',null,500);
 if (page#>>'{parent,count}')::integer <> 128 or (page#>>'{parent,directCount}')::integer <> 32 then
   raise exception 'Anonymous upgraded country counts do not match exact versions';
 end if;
 if (select count(*) from jsonb_array_elements(page->'nodes') n
   where n->>'nodeId' in ('geo:tw','geo:hk','geo:mo') and (n->>'count')::integer=32) <> 3 then
   raise exception 'Anonymous child counts do not match exact versions';
 end if;
end $$;
reset role;
-- Foreign-key cascades must also remove the newly backfilled ancestor rows.
delete from public.processes where id::text like '66210000-%';
delete from public.flows where id::text like '66220000-%';
do $$ declare row record; begin
 if exists(select 1 from private.portal_navigation_membership_v1) then
   raise exception 'Withdrawal left stale backfilled membership';
 end if;
 for row in select * from prior_triggers loop
   execute format('alter table %s %s trigger %I',row.tgrelid::regclass,
     case row.tgenabled when 'D' then 'disable' when 'R' then 'enable replica'
     when 'A' then 'enable always' else 'enable' end,row.tgname);
 end loop;
 if not exists(select 1 from prior_roles where roleid='portal_public_executor'::regrole) then
   revoke portal_public_executor from postgres;
 end if;
 if not exists(select 1 from prior_roles where roleid='api_internal_executor'::regrole) then
   revoke api_internal_executor from postgres;
 end if;
end $$;
commit;
select 'PASS populated upgrade: 160 exact public versions; 96 ancestor inserts; raw data, direct counts and guards preserved';
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local-container', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'supabase_db_[a-z0-9_-]*662[a-z0-9_-]*isolated[a-z0-9_-]*', args.local_container):
        parser.error('target must be an explicitly named issue-662 isolated local container')
    endpoint = subprocess.check_output(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], text=True).strip()
    if not endpoint.startswith('unix://'):
        parser.error('only a local Unix-socket Docker context is accepted')
    start = time.monotonic()
    subprocess.run(['docker', 'exec', '-i', args.local_container, 'psql', '-X', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
                   input=SEED + '\\timing on\n' + MIGRATION.read_text() + VERIFY, text=True, check=True)
    print(f'Complete populated upgrade proof: {time.monotonic()-start:.2f}s')


if __name__ == '__main__':
    main()
