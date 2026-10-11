#!/usr/bin/env python3
"""Database #829: rollback-only, order-balanced full scoped RPC comparison.

Only the explicitly labelled local PostgreSQL17.11 task container is admitted.
Synthetic projection fixtures measure readers; real writers are separate tests.
No remote URL, credentials, forced planner settings or larger public budgets.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import benchmark_portal_catalog_bounded as fixture_source

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = 'supabase_db_database-829-portal-tail'
CANDIDATE = ROOT/'supabase/migrations/20261011151720_optimize_portal_scoped_navigation_facets.sql'
TABLES = ('display_catalog_search_rows_v1','display_catalog_search_rows_v2','display_catalog_facet_rows_v1','display_navigation_versions_v1','display_navigation_membership_v1','dataset_display_settings')


def run(sql: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(['docker','exec','-i',CONTAINER,'psql','-h','/var/run/postgresql','-U','supabase_admin','-d','postgres','-Atq','-v','ON_ERROR_STOP=1'],input=sql,text=True,capture_output=True,timeout=1200)


def reader_sql(text: str) -> str:
    view = re.search(r'create or replace view.*?;(?=\n)',text,re.I|re.S)
    func = re.search(r'create or replace function.*?as (\$[^$]*\$).*?\1;',text,re.I|re.S)
    if not view:
        raise ValueError('Missing request scope view definition')
    return view.group()+'\n'+(func.group() if func else '')+"\nupdate private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1() where singleton;\n"


def baseline(ref: str) -> str:
    paths = ('views/display_request_visible_settings_v1','functions/portal_display_brand_facets_v1')
    text='\n'.join(subprocess.check_output(['git','show',f'{ref}:supabase/workspace/schemas/private/{p}/definition.sql'],cwd=ROOT,text=True) for p in paths)
    return reader_sql(text)


def cases(scope: str) -> dict[str,str]:
    brands="array["+','.join(fixture_source.sql_literal(v) for v in scope.split(','))+"]"
    result={}
    for kind in ('all','process','flow'):
        for suffix,query,filters in (('empty','','{}'),('geo','','{"geographyNodeId":"geo:cn-ah"}'),('zero','','{"source":"missing-829"}')):
            result[f'facets_{kind}_{suffix}']=f"select api.portal_facets_v4({brands},'{kind}',{fixture_source.sql_literal(query)},{fixture_source.sql_literal(filters)})"
    for label,kind,dimension,parent,filters in (
        ('navigation_world','all','geography',None,'{}'),
        ('navigation_process_class','process','classification','class:isic','{}'),
        ('navigation_flow_class','flow','classification','class:cpc','{}'),
        ('navigation_geo','all','geography','geo:cn','{}'),
        ('navigation_filtered','process','classification','class:isic','{"geographyNodeId":"geo:cn-ah"}'),
        ('navigation_direct','all','classification',None,'{"geographyNodeId":"geo:cn","geographyScope":"direct"}'),
        ('navigation_zero','all','geography',None,'{"source":"missing-829"}')):
        parent_sql='null' if parent is None else fixture_source.sql_literal(parent)
        result[label]=f"select api.portal_navigation_v2({brands},'{kind}','',{fixture_source.sql_literal(filters)},'{dimension}',{parent_sql},null,100)"
    for suffix,query in (('lexical','benchprocess 00000001'),('uuid','723be000-0000-4000-8000-000000000001'),('escaped','%_'),('one','b')):
        result[f'facets_{suffix}']=f"select api.portal_facets_v4({brands},'process',{fixture_source.sql_literal(query)},'{{}}')"
    result['facets_brand']=f"select api.portal_facets_v4({brands},'all',''," + fixture_source.sql_literal('{"brand":"bafu"}') + ")"
    return result


def fixture(processes: int, flows: int, padding: int) -> str:
    s=fixture_source.fixture(processes,flows,padding)
    s=s.replace('begin;',"begin;do $$begin if not pg_try_advisory_xact_lock(829,1) then raise exception 'Another #829 fixture owns this database';end if;end$$;",1)
    for a,b in [('portal_catalog_search_rows','display_catalog_search_rows'),('portal_catalog_facet_rows','display_catalog_facet_rows'),('portal_navigation_versions','display_navigation_versions'),('portal_navigation_membership','display_navigation_membership'),('portal_catalog_search_current_v2','display_catalog_search_current_v2')]:s=s.replace(a,b)
    # Source tables and real vocabulary stay distinct; direct projections measure readers only.
    s=s.replace("set constraints all immediate;", """
    reset role;
    create temp table display_original_triggers as select tgrelid::regclass::text relation,tgname,tgenabled from pg_trigger where not tgisinternal and tgrelid in('private.dataset_display_settings'::regclass,'private.display_catalog_search_rows_v1'::regclass,'private.display_catalog_search_rows_v2'::regclass);
    alter table private.dataset_display_settings disable trigger user;
    alter table private.display_catalog_search_rows_v1 disable trigger user;
    alter table private.display_catalog_search_rows_v2 disable trigger user;
    update private.display_catalog_search_rows_v1 set brand=case when right(id::text,1) in ('0','1','2','3','4','5','6') then 'tiangong_lca' when right(id::text,1)='7' then 'bafu' when right(id::text,1)='8' then 'uslci' else 'worldsteel' end;
    update private.display_catalog_search_rows_v2 p set brand=v.brand from private.display_catalog_search_rows_v1 v where(p.dataset_kind,p.id,p.version)=(v.dataset_kind,v.id,v.version);
    insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand) select dataset_kind,id,version,true,brand from private.display_catalog_search_rows_v1;
    do $$declare t record;begin for t in select * from display_original_triggers loop execute format('alter table %s %s trigger %I',t.relation,case t.tgenabled when 'D' then 'disable' when 'A' then 'enable always' when 'R' then 'enable replica' else 'enable' end,t.tgname);end loop;end$$;
    update private.portal_display_rollout set mode='display';
    analyze private.dataset_display_settings;
    set constraints all immediate;
    """)
    # Original loader disables only public and projection table triggers; displays have copied triggers too.
    # Suppress relevant derivative maintenance for synthetic load, and restore prior states.
    p=s.index('create temp table templates')
    s=s[:p]+"\ncreate temp table additional_triggers as select tgrelid::regclass::text relation,tgname,tgenabled from pg_trigger where not tgisinternal and tgrelid in('private.display_navigation_versions_v1'::regclass,'private.display_navigation_membership_v1'::regclass);alter table private.display_navigation_versions_v1 disable trigger user;alter table private.display_navigation_membership_v1 disable trigger user;\n"+s[p:]
    s=s.replace('set constraints all immediate;',"do $$declare t record;begin for t in select * from additional_triggers loop execute format('alter table %s %s trigger %I',t.relation,case t.tgenabled when 'D' then 'disable' when 'A' then 'enable always' when 'R' then 'enable replica' else 'enable' end,t.tgname);end loop;end$$;set constraints all immediate;")
    s=s.replace("from private.display_navigation_versions_v1 v join private.portal_navigation_node_v1 n on", "from private.display_navigation_versions_v1 v cross join lateral (select * from private.portal_navigation_node_v1 n where n.node_id in ('geo:cn','geo:cn-ah-hfe','class:isic:0.0.0.0','class:cpc:1.6.0.0.0')) n where")
    s=s.replace('grant select,insert on measurements,plans to portal_public_executor;','grant select,insert on measurements,plans to anon;')
    s=s.replace('set local role portal_public_executor;', 'reset role;')
    return s


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',required=True,choices=[CONTAINER])
    parser.add_argument('--base-ref',required=True)
    parser.add_argument('--samples',type=int,default=20,choices=range(2,21))
    parser.add_argument('--process-datasets',type=int,default=10000,choices=range(1,20001))
    parser.add_argument('--flow-datasets',type=int,default=59000,choices=range(1,70001))
    parser.add_argument('--card-padding',type=int,default=1024,choices=range(0,4097))
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    artifacts=[args.report,args.report.with_suffix('.sql'),args.report.with_suffix('.log')]
    if any(p.exists() for p in artifacts):parser.error('Evidence paths must be new')
    context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):parser.error('Only local Unix Docker is admitted')
    if os.environ.get('DOCKER_HOST') not in (None,'',context['Endpoints']['docker']['Host']):parser.error('Conflicting Docker endpoint override refused')
    inspected=json.loads(subprocess.check_output(['docker','inspect',CONTAINER],text=True))[0]
    labels=inspected['Config']['Labels'] or {}
    if labels.get('io.tiangong.workspace.task')!='database#829' or labels.get('io.tiangong.workspace.classification')!='disposable-test':parser.error('Task-owned disposable labels required')
    guard="select inet_server_addr() is null;select current_setting('server_version');"+';'.join(f'select count(*) from private.{t}' for t in TABLES)+';'
    expected=['t','17.11']+['0']*len(TABLES)
    checked=run(guard)
    if checked.returncode or checked.stdout.strip().splitlines()!=expected:parser.error('Refusing nonempty, unknown or wrong-version target')
    base=subprocess.check_output(['git','rev-parse',f'{args.base_ref}^{{commit}}'],cwd=ROOT,text=True).strip()
    candidate=CANDIDATE.read_text()
    definitions={'baseline':baseline(base),'candidate':reader_sql(candidate)}
    scopes=('tiangong_lca','bafu,tiangong_lca,uslci,worldsteel')
    all_cases={scope:cases(scope) for scope in scopes}
    sql=fixture(args.process_datasets,args.flow_datasets,args.card_padding)
    sql+='''
grant execute on function pg_temp.measure(text,text,integer,text),pg_temp.capture_plan(text,text,text) to anon;
create function pg_temp.next_cursor(v text,l text,i integer) returns text language plpgsql stable as $$
declare c text;begin select payload->>'nextCursor' into c from measurements where variant=v and label=l and ordinal=i;if c is null then raise exception 'Expected a real continuation cursor';end if;return c;end$$;
grant execute on function pg_temp.next_cursor(text,text,integer) to anon;
'''
    for ordinal in range(-1,args.samples):
        for variant in (('baseline','candidate') if ordinal%2==0 else ('candidate','baseline')):
            sql+='reset role;'+definitions[variant]+'set local role anon;\n'
            for scope,statements in all_cases.items():
                for label,statement in statements.items():
                    sql+=f"select pg_temp.measure('{variant}',{fixture_source.sql_literal(scope+':'+label)},{ordinal},{fixture_source.sql_literal(statement)});\n"
                brands="array["+','.join(fixture_source.sql_literal(v) for v in scope.split(','))+"]"
                cursor=f"pg_temp.next_cursor('{variant}',{fixture_source.sql_literal(scope+':navigation_world')},{ordinal})"
                statement=f"select api.portal_navigation_v2({brands},'all','','{{}}','geography',null,{cursor},100)"
                sql+=f"select pg_temp.measure('{variant}',{fixture_source.sql_literal(scope+':navigation_page2')},{ordinal},{fixture_source.sql_literal(statement)});\n"
    sql+='reset role;load \'auto_explain\';set local auto_explain.log_min_duration=0;set local auto_explain.log_analyze=on;set local auto_explain.log_timing=off;set local auto_explain.log_buffers=on;set local auto_explain.log_nested_statements=on;set local auto_explain.log_format=json;set local auto_explain.log_level=notice;\n'
    for variant in ('baseline','candidate'):
        sql+='reset role;set local auto_explain.log_min_duration=-1;'+definitions[variant]+'set local auto_explain.log_min_duration=0;set local role anon;\n'
        for scope in scopes:
            for label in ('navigation_world','navigation_filtered','facets_all_empty','facets_flow_empty','facets_lexical','facets_all_zero'):
                sql+=f"select pg_temp.capture_plan('{variant}',{fixture_source.sql_literal(scope+':'+label)},{fixture_source.sql_literal(all_cases[scope][label])});\n"
    sql+='''
reset role;set local auto_explain.log_min_duration=-1;
select jsonb_build_object(
 'versions',(select count(*) from private.display_navigation_versions_v1),
 'memberships',(select count(*) from private.display_navigation_membership_v1),
 'cursorProof',(select bool_and(payload->>'nextCursor' is not null) from measurements where label like '%:navigation_world'),
 'samples',(select jsonb_agg(jsonb_build_object('variant',variant,'label',label,'ordinal',ordinal,'ms',elapsed_ms,'error',error) order by label,ordinal,variant) from measurements where ordinal>=0),
 'equivalence',(select jsonb_agg(jsonb_build_object('label',b.label,'ordinal',b.ordinal,'equal',b.payload=c.payload,'baselineError',b.error,'candidateError',c.error) order by b.label,b.ordinal) from measurements b join measurements c using(label,ordinal) where b.variant='baseline' and c.variant='candidate'),
 'plans',(select jsonb_agg(jsonb_build_object('variant',variant,'label',label,'plan',payload,'error',error) order by label,variant) from plans));
rollback;
'''
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.with_suffix('.sql').write_text(sql)
    try:
        result=run(sql)
        args.report.with_suffix('.log').write_text(result.stdout+'\n'+result.stderr)
    finally:
        cleanup=run(guard)
        if cleanup.returncode or cleanup.stdout.strip().splitlines()!=expected:raise RuntimeError('Rollback target/fixture guard failed')
    if result.returncode:print(result.stderr[-2500:]);return result.returncode
    rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    if len(rows)!=1:raise RuntimeError('Unique complete benchmark result required')
    report=rows[0]
    report.update({'baseCommit':base,'candidateSha256':hashlib.sha256(candidate.encode()).hexdigest(),'sqlSha256':hashlib.sha256(sql.encode()).hexdigest(),'collectorSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'containerId':inspected['Id'],'dockerContext':context['Name'],'scope':'synthetic local order-balanced warm full RPC comparison; not hosted p95 or writer proof','cleanupRows':0})
    report['medians']={label:{variant:statistics.median(s['ms'] for s in report['samples'] if s['label']==label and s['variant']==variant) for variant in ('baseline','candidate')} for label in {s['label'] for s in report['samples']}}
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    failures=[r for r in report['equivalence'] if not r['equal'] or r['baselineError'] or r['candidateError']]
    errors=[r for r in report['plans'] if r['error']]
    print(json.dumps({'report':str(args.report),'comparisons':len(report['equivalence']),'failures':failures,'planErrors':errors,'cursorProof':report['cursorProof'],'medians':report['medians']},indent=2))
    return int(bool(failures or errors or report['cursorProof'] is not True))


if __name__=='__main__':raise SystemExit(main())
