#!/usr/bin/env python3
"""Database #829: exact local upgrade, metadata, idempotence and scope isolation.

Only the task-labelled disposable PostgreSQL17.11 container is admitted. The
concurrency fixture lives in a uniquely named clone, which is removed afterwards.
No remote DSN or deployment authority is accepted.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
CONTAINER='supabase_db_database-829-portal-tail'
DATABASE='portal829_scope_concurrency'
CANDIDATE=ROOT/'supabase/migrations/20261011142438_optimize_portal_scoped_navigation_facets.sql'


def sql(source: str,database: str='postgres') -> str:
    result=subprocess.run(['docker','exec','-i',CONTAINER,'psql','-U','supabase_admin','-d',database,'-Atq','-v','ON_ERROR_STOP=1'],input=source,text=True,capture_output=True,timeout=180)
    if result.returncode:raise RuntimeError(result.stderr[-2500:])
    return result.stdout


SNAPSHOT="""select jsonb_build_object(
 'functions',(select md5(jsonb_agg(jsonb_build_array(p.oid,p.prosrc,p.proowner,p.proacl,p.proconfig,p.prosecdef,p.provolatile,p.proparallel,p.prolang) order by p.oid)::text) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('api','private')),
 'view',(select jsonb_build_array(c.oid,c.relowner,c.relacl,c.reloptions,(select jsonb_agg(jsonb_build_array(attname,atttypid,attnotnull) order by attnum) from pg_attribute where attrelid=c.oid and attnum>0 and not attisdropped)) from pg_class c where c.oid='private.display_request_visible_settings_v1'::regclass),
 'mode',(select mode from private.portal_display_rollout where singleton),
 'settings',(select count(*) from private.dataset_display_settings),
 'catalog',(select count(*) from private.display_catalog_search_rows_v1),
 'navigation',(select count(*) from private.display_navigation_versions_v1),
 'memberships',(select count(*) from private.display_navigation_membership_v1));"""


def client(reverse: bool) -> list[dict]:
    outer='bafu' if reverse else 'tiangong_lca'
    source=f"set application_name='portal829-scope-{int(reverse)}';begin;select set_config('portal.display_brands','{outer}',true);set local role anon;set local plan_cache_mode='force_generic_plan';"
    source+="""prepare portal829_scoped(text[]) as select jsonb_build_object(
     'totals',api.portal_navigation_v2($1,'all','','{}','classification')->'totals',
     'brandCounts',(select coalesce(jsonb_object_agg(v->>'value',v->'count'),'{}'::jsonb) from jsonb_array_elements(api.portal_facets_v4($1,'all','','{}')->'groups') g cross join lateral jsonb_array_elements(g->'values') v where g->>'id'='brand'),
     'outer',current_setting('portal.display_brands',true));"""
    scopes=[['tiangong_lca'],['bafu'],['bafu','tiangong_lca'],['worldsteel']]
    if reverse:scopes.reverse()
    expected=[]
    for _ in range(8):
        for brands in scopes:
            array='array['+','.join("'"+b+"'" for b in brands)+']'
            source+=f'execute portal829_scoped({array});select pg_sleep(0.005);'
            expected.append({'brandCounts':({'tiangong_lca':1} if brands==['tiangong_lca'] else {'bafu':2} if brands==['bafu'] else {'bafu':2,'tiangong_lca':1} if len(brands)==2 else {}),'totals':({'process':1,'flow':0} if brands==['tiangong_lca'] else {'process':1,'flow':1} if brands==['bafu'] else {'process':2,'flow':1} if len(brands)==2 else {'process':0,'flow':0}),'outer':outer})
    source+='deallocate portal829_scoped;rollback;'
    rows=[json.loads(line) for line in sql(source,DATABASE).splitlines() if line.startswith('{')]
    assert rows==expected,'Concurrent prepared scope/outer-state mismatch'
    return rows


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',required=True,choices=[CONTAINER])
    parser.add_argument('--report',required=True,type=Path)
    parser.add_argument('--base-ref',required=True)
    args=parser.parse_args()
    if args.report.exists():parser.error('Evidence path must be new')
    context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):parser.error('Only local Unix Docker is admitted')
    if os.environ.get('DOCKER_HOST') not in (None,'',context['Endpoints']['docker']['Host']):parser.error('Conflicting Docker endpoint override refused')
    target=json.loads(subprocess.check_output(['docker','inspect',CONTAINER],text=True))[0]
    labels=target['Config']['Labels'] or {}
    if labels.get('io.tiangong.workspace.task')!='database#829' or labels.get('io.tiangong.workspace.classification')!='disposable-test':parser.error('Explicit task ownership required')
    assert sql("select inet_server_addr() is null;select current_setting('server_version');").strip().splitlines()==['t','17.11']
    before=json.loads(sql(SNAPSHOT))
    assert all(before[k]==0 for k in ('settings','catalog','navigation','memberships')),'Upgrade requires empty local fixture target'
    base=subprocess.check_output(['git','rev-parse',f'{args.base_ref}^{{commit}}'],cwd=ROOT,text=True).strip()
    predecessor=subprocess.check_output(['git','show',f'{base}:supabase/workspace/schemas/private/views/display_request_visible_settings_v1/definition.sql'],cwd=ROOT,text=True)
    definition=re.search(r'CREATE OR REPLACE VIEW.*?;',predecessor,re.S)
    assert definition,'Exact predecessor scope view required'
    sql(definition.group()+"update private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1() where singleton;select private.portal_display_assert_contract_v1();")
    predecessor_digest=sql("select md5(pg_get_viewdef('private.display_request_visible_settings_v1'::regclass,true));").strip()
    migration=CANDIDATE.read_text()
    sql(migration)
    after=json.loads(sql(SNAPSHOT))
    assert before==after,'Function, role/ACL/view metadata, mode or rows changed'
    view_after=sql("select md5(pg_get_viewdef('private.display_request_visible_settings_v1'::regclass,true));")
    assert view_after.strip()!=predecessor_digest,'Upgrade did not change the predecessor view'
    sql(migration)
    assert json.loads(sql(SNAPSHOT))==after and sql("select md5(pg_get_viewdef('private.display_request_visible_settings_v1'::regclass,true));")==view_after,'Repeat application drift'
    head=CANDIDATE.name.split('_')[0]
    assert head.isdigit() and len(head)==14
    sql(f"insert into supabase_migrations.schema_migrations(version,name) values('{head}','optimize_portal_scoped_navigation_facets') on conflict do nothing;")
    assert sql(f"select count(*) from pg_database where datname='{DATABASE}';").strip()=='0','Concurrency clone already exists'
    created=False
    cleanup=False
    rows=[]
    overlap=0
    try:
        # The two image-provided background workers attach to postgres. Admit
        # only those exact task-local worker identities, never user sessions.
        workers=json.loads(sql("select coalesce(jsonb_agg(jsonb_build_object('pid',pid,'application',application_name,'type',backend_type)),'[]'::jsonb) from pg_stat_activity where datname='postgres' and pid<>pg_backend_pid();"))
        assert all((w['application'],w['type']) in (('pg_net 0.20.4','pg_net 0.20.4 worker'),('pg_cron scheduler','pg_cron launcher'),('','autovacuum worker')) for w in workers),'Unexpected source database session'
        try:
            sql("alter database postgres allow_connections=false;select pg_terminate_backend(pid) from pg_stat_activity where datname='postgres';"+f"create database {DATABASE} template postgres strategy file_copy;",'template1')
            created=True
        finally:
            sql('alter database postgres allow_connections=true;','template1')
        assert sql("select datallowconn from pg_database where datname='postgres';").strip()=='t','Source connections were not restored'
        seed=(ROOT/'supabase/tests/20261010_portal_display_readers.sql').read_text().split('select is((select count(*)::integer from private.display_catalog_search_rows_v2)')[0]
        sql(seed+"update private.portal_display_rollout set mode='display';commit;",DATABASE)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(client,reverse) for reverse in (False,True)]
            while not all(f.done() for f in futures):
                active=int(sql("select count(*) from pg_stat_activity where datname='"+DATABASE+"' and application_name like 'portal829-scope-%' and state='active';").strip())
                overlap=max(overlap,active)
                time.sleep(0.01)
            rows=[future.result() for future in futures]
            assert overlap==2,'Concurrent execution was not observed'
    finally:
        if created:
            sql(f'drop database {DATABASE};')
            cleanup=sql(f"select count(*) from pg_database where datname='{DATABASE}';").strip()=='0'
        report={'passed':len(rows)==2 and cleanup,'baseCommit':base,'predecessorViewDigest':predecessor_digest,'candidateViewDigest':view_after.strip(),'migrationSha256':hashlib.sha256(migration.encode()).hexdigest(),'metadataUnchanged':before==after,'idempotence':True,'concurrentConnections':len(rows),'observedActiveOverlap':overlap,'preparedScopeComparisons':sum(len(r) for r in rows),'cloneDatabase':DATABASE,'cloneRemoved':cleanup,'sourceConnectionsRestored':sql("select datallowconn from pg_database where datname='postgres';").strip()=='t','containerId':target['Id'],'dockerContext':context['Name'],'scope':'synthetic local upgrade and cross-session/prepared request-scope isolation'}
        args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2));return int(not report['passed'])


if __name__=='__main__':raise SystemExit(main())
