#!/usr/bin/env python3
"""Rollback-only, same-fixture summary/navigation benchmark on an explicit local container.

Seeds through real public projection writers (only unrelated authoring/jobs are
suppressed inside the transaction), compares the actual pre-change September
facade with the new facade, and rolls back fixtures, trigger changes and DDL.
No hosted connection string, credentials, production data or force-index flags.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
PREVIOUS=ROOT/'supabase/migrations/20260908090300_portal_composite_names_cutover.sql'
CURRENT=ROOT/'supabase/migrations/20260919160000_portal_catalog_summary_bounded.sql'


def facade(path: Path) -> str:
    source=path.read_text()
    match=re.search(r'CREATE OR REPLACE FUNCTION api\.portal_catalog_summary_v1\(\).*?\$function\$\s*;',source,re.I|re.S)
    if not match: raise RuntimeError(f'Cannot find exact facade in {path.name}')
    return match.group(0)


def run(container: str, sql: str) -> subprocess.CompletedProcess:
    return subprocess.run(['docker','exec','-i',container,'psql','-h','/var/run/postgresql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-Atq'],input=sql,text=True,capture_output=True)


def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--container',required=True)
    p.add_argument('--process-datasets',type=int,default=2000)
    p.add_argument('--flow-datasets',type=int,default=3000)
    p.add_argument('--samples',type=int,default=5)
    p.add_argument('--direct-projection-fixture',action='store_true',help='Bulk-load consistent public projections for read-scale measurement; writers are tested separately')
    p.add_argument('--report',type=Path,required=True)
    a=p.parse_args()
    if not re.fullmatch(r'supabase_db_[a-z0-9-]+',a.container): p.error('Explicit local Supabase container required')
    if not 1<=a.process_datasets<=50000 or not 1<=a.flow_datasets<=50000 or not 1<=a.samples<=20: p.error('Fixture/sample bounds exceeded')
    context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'): p.error('Docker must use a local Unix socket')
    check=run(a.container,"select inet_server_addr() is null; select count(*) from private.portal_catalog_search_rows_v1; select count(*) from private.portal_catalog_search_rows_v2;")
    if check.returncode or check.stdout.strip().splitlines()!=['t','0','0']: p.error('Refusing a nonempty or non-local fixture database')
    fixture='''
begin;
set local statement_timeout='10min';
grant portal_public_executor,api_internal_executor to postgres;
grant create on schema api to portal_public_executor;
alter table public.processes disable trigger user;
alter table public.processes enable trigger portal_catalog_projection_content_sync_v1;
alter table public.processes enable trigger portal_catalog_projection_content_sync_v2;
alter table public.flows disable trigger user;
alter table public.flows enable trigger portal_catalog_projection_content_sync_v1;
create function pg_temp.payload(n text,g text,c text,f boolean,v integer) returns jsonb language sql immutable as $$
select jsonb_build_object(case when f then 'flowDataSet' else 'processDataSet' end,jsonb_build_object(
case when f then 'flowInformation' else 'processInformation' end,jsonb_build_object(
 'dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName',n,'treatmentStandardsRoutes','route','mixAndLocationTypes','mix'),
 'CASNumber',case when f and n='BenchFlow 1' and v=1 then '50-00-0' end,
 'classificationInformation',jsonb_build_object('common:classification',jsonb_build_object('common:class',jsonb_build_object('@classId',c)))),
 'geography',jsonb_build_object(case when f then 'locationOfSupply' else 'locationOfOperationSupplyOrProduction' end,jsonb_build_object('@location',g))),
 'administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:licenseType','Free of charge for all users and uses'))))
$$;
'''
    if a.direct_projection_fixture:
        fixture+="""
create temp table original_triggers as
select tgrelid::regclass::text as relation,tgname,tgenabled from pg_trigger
where not tgisinternal and tgrelid in ('private.portal_catalog_search_rows_v1'::regclass,'private.portal_catalog_search_rows_v2'::regclass,'private.portal_catalog_facet_rows_v1'::regclass);
alter table private.portal_catalog_search_rows_v1 disable trigger user;
alter table private.portal_catalog_search_rows_v2 disable trigger user;
alter table private.portal_catalog_facet_rows_v1 disable trigger user;
create temp table templates as
select k,st,g,
 private.catalog_portal_projection_payload_v1(k,st,pg_temp.payload('Bench'||initcap(k),g,case when k='process' then '0111' else '17100' end,k='flow',1)) as old,
 case when k='process' then private.catalog_portal_projection_payload_cn1(k,st,pg_temp.payload('Bench'||initcap(k),g,'0111',false,1)) end as current
from unnest(array['process','flow']) k cross join unnest(array[100,200]) st cross join unnest(array['CN','CN-AH-HFE']) g;
"""
        for kind,count,prefix in [('process',a.process_datasets,'656be000'),('flow',a.flow_datasets,'656bf000')]:
            for version_table in ([1,2] if kind=='process' else [1]):
                payload='current' if version_table==2 else 'old'
                fixture+=f"""
insert into private.portal_catalog_search_rows_v{version_table}(dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version)
select '{kind}',('{prefix}-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.00'||v,
case when v=0 then 100 else 200 end,'2026-09-19'::timestamptz+(i%100)*interval '1 second',
t.{payload}->'card',t.{payload}->>'document',{version_table}
from generate_series(1,{count}) i cross join generate_series(0,1) v
join templates t on t.k='{kind}' and t.st=case when v=0 then 100 else 200 end and t.g=case when i%2=0 then 'CN-AH-HFE' else 'CN' end;
"""
        fixture+="""
insert into private.portal_catalog_facet_rows_v1(dataset_kind,id,version,state_code,modified_at,facet_access_level,facet_geography,facet_reference_year,facet_process_subtype,facet_source,facet_contract_version)
select dataset_kind,id,version,state_code,modified_at,card->>'accessLevel',lower(btrim(card#>>'{geography,code}')),card->>'referenceYear',lower(btrim(card->>'processSubtype')),lower(btrim(card->>'source')),1
from private.portal_catalog_search_rows_v1;
insert into private.portal_navigation_versions_v1(dataset_kind,id,version,access_level,geography_code,classification_codes,reference_year,process_subtype,source)
select dataset_kind,id,version,card->>'accessLevel',lower(btrim(card#>>'{geography,code}')),
array(select distinct lower(btrim(c->>'code')) from jsonb_array_elements(card->'classifications') c),
(card->>'referenceYear')::integer,lower(btrim(card->>'processSubtype')),lower(btrim(card->>'source'))
from private.portal_catalog_search_current_v2;
with recursive placements as (
select v.dataset_kind,v.id,v.version,n.node_id,n.parent_node_id,n.dimension,true as direct
from private.portal_navigation_versions_v1 v join private.portal_navigation_node_v1 n on
  (n.dimension='geography' and n.node_id='geo:'||v.geography_code)
  or (n.dimension='classification' and n.taxonomy=case when v.dataset_kind='process' then 'isic' else 'cpc' end and lower(n.code)=any(v.classification_codes))
union all
select p.dataset_kind,p.id,p.version,n.node_id,n.parent_node_id,n.dimension,false
from placements p join private.portal_navigation_node_v1 n on n.node_id=p.parent_node_id
) insert into private.portal_navigation_membership_v1(dataset_kind,id,version,node_id,dimension,direct)
select dataset_kind,id,version,node_id,dimension,bool_or(direct) from placements group by dataset_kind,id,version,node_id,dimension;
do $$ declare t record; begin for t in select * from original_triggers loop
 execute format('alter table %s %s trigger %I',t.relation,case t.tgenabled when 'D' then 'disable' when 'A' then 'enable always' when 'R' then 'enable replica' else 'enable' end,t.tgname);
end loop; end $$;
"""
    else:
        for kind,count,prefix,code in [('process',a.process_datasets,'656be000','0111'),('flow',a.flow_datasets,'656bf000','17100')]:
            flow='true' if kind=='flow' else 'false'
            fixture+=f"""
    insert into public.{kind}es(id,version,json,state_code,modified_at)
    select ('{prefix}-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.00'||v,
    pg_temp.payload('Bench{kind.title()} '||i,case when i%2=0 then 'CN-AH-HFE' else 'CN' end,'{code}',{flow},v),
    case when v=0 then 100 else 200 end,'2026-09-19'::timestamptz + (i%100)*interval '1 second'
    from generate_series(1,{count}) i cross join generate_series(0,1) v;
    """.replace('public.flowes','public.flows')
    if a.direct_projection_fixture:
        # Context decorators deliberately bind selected rows to authoritative raw
        # metadata. Materialise the bounded first-page support rows, without
        # re-running the bulk fixtures' derivation. Trigger states roll back.
        fixture+="alter table public.processes disable trigger user; alter table public.flows disable trigger user;\n"
        for kind,count,prefix,code in [('process',a.process_datasets,'656be000','0111'),('flow',a.flow_datasets,'656bf000','17100')]:
            table='processes' if kind=='process' else 'flows'
            flow='true' if kind=='flow' else 'false'
            fixture+=f"""
insert into public.{table}(id,version,json,state_code,modified_at)
select ('{prefix}-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.00'||v,
pg_temp.payload('Bench{kind.title()}',case when i%2=0 then 'CN-AH-HFE' else 'CN' end,'{code}',{flow},v),
case when v=0 then 100 else 200 end,'2026-09-19'::timestamptz+(i%100)*interval '1 second'
from generate_series(1,{min(count,100)}) i cross join generate_series(0,1) v;
"""
    fixture+='''
set constraints all immediate;
analyze private.portal_catalog_search_rows_v1;
analyze private.portal_catalog_search_rows_v2;
analyze private.portal_catalog_facet_rows_v1;
analyze private.portal_navigation_versions_v1;
analyze private.portal_navigation_membership_v1;
create temp table query_plans(label text,payload jsonb);
grant select,insert on query_plans to portal_public_executor;
create temp table measurements(variant text,ordinal integer,elapsed_ms numeric,payload jsonb,error text);
grant select,insert on measurements to portal_public_executor;
set local role portal_public_executor;
create function pg_temp.measure(v text,i integer,statement text) returns void language plpgsql as $$
declare started timestamptz:=clock_timestamp(); result jsonb;
begin
 begin
   execute statement into result;
   insert into measurements values(v,i,extract(epoch from clock_timestamp()-started)*1000,result,null);
 exception when others then
   insert into measurements values(v,i,extract(epoch from clock_timestamp()-started)*1000,null,sqlstate||':'||sqlerrm);
 end;
end;
$$;
set local statement_timeout='15s';
'''
    for variant,definition in [('current',facade(CURRENT)),('previous',facade(PREVIOUS))]:
        fixture+=definition+'\n'
        for i in range(a.samples): fixture+=f"select pg_temp.measure('{variant}',{i},'select api.portal_catalog_summary_v1()');\n"
    fixture+=facade(CURRENT)+'\n'
    statements={
      'navigation_empty':"select api.portal_navigation_v1('all','','{}','geography',null,null,500)",
      'navigation_filter':"select api.portal_navigation_v1('process','','{\"geographyNodeId\":\"geo:cn-ah\"}','classification','class:isic',null,50)",
      'search_filter':"select api.portal_search_processes_v3('','{\"geographyNodeId\":\"geo:cn-ah\"}')",
      'facets_filter':"select api.portal_facets_v3('process','','{\"geographyNodeId\":\"geo:cn-ah\"}')",
    }
    for label,statement in statements.items():
        for i in range(a.samples): fixture+=f"select pg_temp.measure('{label}',{i},'{statement.replace(chr(39),chr(39)*2)}');\n"
    fixture+="""
create function pg_temp.capture_plan(label text,statement text) returns void language plpgsql as $$
declare result jsonb; begin execute 'explain (analyze,buffers,format json) '||statement into result; insert into query_plans values(label,result); end $$;
select pg_temp.capture_plan('province_membership','select count(*) from private.portal_navigation_membership_v1 where dimension=''geography'' and node_id=''geo:cn-ah'' and dataset_kind=''process''');
select pg_temp.capture_plan('exact_geography','select count(*) from private.portal_navigation_versions_v1 where geography_code=''cn-ah-hfe'' and dataset_kind=''process''');
"""
    fixture+='''
select jsonb_build_object('schemaVersion','portal.synthetic-query-benchmark.v1',
 'scope','rollback-only local synthetic fixture; first read follows fixture insertion, not a cold production measurement',
 'samples',(select jsonb_agg(jsonb_build_object('variant',variant,'ordinal',ordinal,'elapsedMs',elapsed_ms,'bytes',octet_length(payload::text),'sha256',encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex'),'error',error) order by variant,ordinal) from measurements),
 'responsesIdentical',(select count(distinct payload)=1 from measurements where variant in ('current','previous')),
 'plans',(select jsonb_object_agg(label,payload) from query_plans),
 'counts',(select payload->'counts' from measurements where variant='current' limit 1));
rollback;
'''
    result=run(a.container,fixture)
    if result.returncode:
        print(result.stderr[-5000:],file=sys.stderr);return result.returncode
    outputs=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    if len(outputs)!=1: raise RuntimeError('Missing unique benchmark report')
    report=outputs[0]
    report['fixture']={'processVersions':a.process_datasets*2,'flowVersions':a.flow_datasets*2,'previousMigration':PREVIOUS.name,'writer': 'bulk consistent public projections for read-scale only; writer correctness is independently exercised by the navigation SQL suite' if a.direct_projection_fixture else 'raw public source with projection writers enabled'}
    a.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    errors=[sample for sample in report['samples'] if sample['error']]
    return 1 if errors or not report['responsesIdentical'] else 0

if __name__=='__main__': raise SystemExit(main())
