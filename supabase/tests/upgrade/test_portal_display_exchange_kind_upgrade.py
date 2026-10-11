#!/usr/bin/env python3
"""Rollback-only #824 populated upgrade, exact response parity and local timings.

Run only on the explicitly owned empty local portal-exchanges-824 stack. Timings
are initial/repeat measurements with uncontrolled shared caches, not cold-cache,
concurrent-load or production latency qualification. No hosted credentials.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / 'supabase/migrations/20261011073000_optimize_portal_display_exchange_paging.sql'
CANDIDATE = ROOT / 'supabase/migrations/20261011100000_optimize_portal_display_exchange_kind_filter.sql'
FIXTURE = ROOT / 'supabase/tests/20261011_portal_display_exchange_kind_filter.sql'
CONTAINER = 'supabase_db_portal-exchanges-824'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--container', required=True, choices=[CONTAINER])
p.add_argument('--report', required=True, type=Path)
args = p.parse_args()
if args.report.exists():
    p.error('Report path must be new')
owner = Path('/private/tmp/lca-portal-824-20261011/OWNER.md').read_text()
if 'tiangong-lca/database#824' not in owner:
    p.error('Explicit task ownership is required')
context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
if not context['Endpoints']['docker']['Host'].startswith('unix://'):
    p.error('Only local Docker is admitted')
labels = json.loads(subprocess.check_output(['docker', 'inspect', CONTAINER,
                                            '--format', '{{json .Config.Labels}}'], text=True))
if labels.get('com.supabase.cli.project') != 'portal-exchanges-824':
    p.error('Wrong isolated stack')


def run(sql):
    return subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-U', 'postgres',
                           '-d', 'postgres', '-Atq', '-v', 'ON_ERROR_STOP=1'],
                          input=sql, text=True, capture_output=True, timeout=600)


check = run('select inet_server_addr() is null; select count(*) from private.dataset_display_settings;')
if check.returncode or check.stdout.strip().splitlines() != ['t', '0']:
    p.error('Refusing non-local or nonempty database')
base = BASE.read_text()
baseline = base[base.index('CREATE OR REPLACE FUNCTION "private"."display_api_list_process_exchanges_v1"'):base.index('update private.portal_display_contract_manifest')]
refresh = '\nupdate private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1();\n'
candidate = re.sub(r'^(begin;|commit;)$', '', CANDIDATE.read_text(), flags=re.M)
fixture = FIXTURE.read_text().split('-- End fixture.')[0].replace('select no_plan();', '')
sql = fixture + baseline + refresh
sql += """
create temp table saved_functions as select p.oid,pg_get_functiondef(p.oid) definition,p.proowner,p.proacl,p.proconfig
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('api','private') and p.prokind='f';
create temp table saved_data(relation text primary key, digest text);
create function pg_temp.data_digest(rel text) returns text language plpgsql as $$declare d text; begin
 execute format('select md5(coalesce(string_agg(md5(to_jsonb(r)::text),'''' order by md5(to_jsonb(r)::text)),'''')) from %s r',rel) into d; return d;
end$$;
insert into saved_data
select c.oid::regclass::text,pg_temp.data_digest(c.oid::regclass::text)
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where c.relkind='r' and (n.nspname='public' or (n.nspname='private' and
(c.relname like 'display_%' or c.relname in ('dataset_display_settings','portal_display_rollout','portal_display_derivation_contract'))));
create function pg_temp.verify_upgrade() returns void language plpgsql as $$begin
 if exists(select 1 from saved_data where digest is distinct from pg_temp.data_digest(relation)) then raise exception 'source/settings/projection drift'; end if;
 if exists(select 1 from saved_functions s join pg_proc p using(oid) where s.proowner<>p.proowner or s.proacl is distinct from p.proacl or s.proconfig is distinct from p.proconfig
 or (p.proname<>'display_api_list_process_exchanges_v1' and s.definition<>pg_get_functiondef(p.oid))) then raise exception 'legacy/helper/LCIA/config/ACL drift'; end if;
 perform private.portal_display_assert_contract_v1();
end$$;
savepoint failed_upgrade;
"""
# Apply only the changed function, then simulate a mid-migration failure.
sql += candidate.split('update private.portal_display_contract_manifest')[0]
sql += r"""
\set ON_ERROR_STOP off
do $$begin raise exception 'expected injected upgrade failure'; end$$;
rollback to failed_upgrade;
\set ON_ERROR_STOP on
do $$begin if exists(select 1 from saved_functions s join pg_proc p using(oid) where s.definition<>pg_get_functiondef(p.oid)) then raise exception 'failed upgrade leaked'; end if; end$$;
select pg_temp.verify_upgrade();
"""
sql += candidate + 'select pg_temp.verify_upgrade();\n' + candidate + 'select pg_temp.verify_upgrade();\n'
sql += """
create temp table measurements(phase text,iteration integer,scenario text,shape text,seconds numeric,response text,plan jsonb);
grant insert,select on measurements to anon;
create function pg_temp.probe(phase text,iteration integer,scenario text,shape text,q text,explain_plan boolean default false)
returns void language plpgsql as $$declare started timestamptz; v jsonb; x jsonb; begin
 started:=clock_timestamp();
 begin execute q into v; exception when others then v:=jsonb_build_object('sqlstate',sqlstate,'message',sqlerrm); end;
 if shape not like '%-invalid' and v ? 'sqlstate' then raise exception 'unexpected response: % % % %',phase,scenario,shape,v; end if;
 insert into measurements values(phase,iteration,scenario,shape,extract(epoch from clock_timestamp()-started),v::text,null);
 if explain_plan then execute 'explain (analyze,buffers,format json) '||q into x;
 update measurements set plan=x where measurements.phase=probe.phase and measurements.iteration=probe.iteration and measurements.scenario=probe.scenario and measurements.shape=probe.shape;
 end if;
end$$;
grant update on measurements to anon;
grant execute on function pg_temp.probe(text,integer,text,text,text,boolean) to anon;
"""


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def call(n, kind='all', cursor='null', limit=20, scope='worldsteel'):
    return f"select api.portal_list_process_exchanges_v2(array['{scope}'],'82400000-0000-4000-8000-{n:012d}','01.00.000','{kind}',{cursor},{limit})"


def cursor(n, internal_id, kind='all', row_kind='technosphere'):
    return "private.display_cursor_encode_v1(jsonb_build_object('v',1,'processId','82400000-0000-4000-8000-%012d','processVersion','01.00.000','filterKind','%s','internalId','%s','kind','%s'))" % (n, kind, internal_id, row_kind)


# Inspect the actual candidate grouping SQL under the display executor, retaining
# the natural plan (no planner switches). Exact Flow lookups must use the PK.
group_query = candidate[candidate.index('with raw_exchanges as materialized'):candidate.index('    loop\n      -- Only a same-ID group')].strip()
for key, value in {
    'v_process_json': "(select json from public.processes where id='82400000-0000-4000-8000-000000002556' and version='01.00.000')",
    'v_kind': "'waste'::text", 'v_cursor': 'null::jsonb',
    'v_cursor_internal': 'null::integer',
}.items():
    group_query = re.sub(r'\b' + key + r'\b', lambda _: value, group_query)
sql += "create temp table kind_plans(plan jsonb); grant insert on kind_plans to portal_display_executor; select set_config('portal.display_brands','worldsteel',true); select set_config('portal.display_global','false',true); select set_config('portal.display_filter_brand','',true); set local role portal_display_executor;\n"
sql += f"do $plan$ declare x jsonb; begin execute {literal('explain (analyze,buffers,format json) ' + group_query)} into x; insert into kind_plans values(x); end $plan$; reset role;\n"

for iteration in range(1, 4):
    for phase in (['baseline', 'candidate'] if iteration % 2 else ['candidate', 'baseline']):
        sql += ((baseline + refresh) if phase == 'baseline' else candidate) + "\nset local statement_timeout='8s';\n"
        sql += "set local statement_timeout='8s'; select set_config('portal.display_brands','worldsteel',true); select set_config('portal.display_global','false',true); select set_config('portal.display_filter_brand','',true);\n"
        for n in (2540, 2556):
            for kind in ['all', 'technosphere', 'elementary', 'waste']:
                ids = [i for i in range(1, n+1) if kind == 'all' or
                       (kind == 'technosphere' and (i == 1 or i % 61 == 0)) or
                       (kind == 'waste' and i != 1 and i % 61 != 0 and i % 67 == 0) or
                       (kind == 'elementary' and i != 1 and i % 61 != 0 and i % 67 != 0)]
                for shape, offset in [('first', 0), ('second', 20), ('last', (len(ids)-1)//20*20)]:
                    prior = ids[offset-1] if offset else None
                    row_kind = ('technosphere' if prior == 1 or prior and prior % 61 == 0 else 'waste' if prior and prior % 67 == 0 else 'elementary')
                    c = cursor(n, str(prior), kind, row_kind) if prior else 'null'
                    sql += f"select set_config('test.cursor',coalesce({c},''),true);\nset local role anon;\n"
                    q = call(n, kind, cursor="nullif(current_setting('test.cursor'),'')")
                    sql += f"select pg_temp.probe('{phase}',{iteration},'{n}-{kind}','{shape}',{literal(q)},{str(iteration == 1 and shape == 'first').lower()});\nreset role;\n"
        sql += 'select pg_temp.verify_upgrade();\n'

# Exhaust the large arrays with no matching kinds, preserving the fixture afterward.
sql += "set local statement_timeout='60s'; update public.flows set json=jsonb_set(json,'{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}','\"Elementary flow\"') where id::text like '82400000%' and right(id::text,12)::bigint>10000;\n"
for phase in ['baseline', 'candidate']:
    sql += ((baseline + refresh) if phase == 'baseline' else candidate) + "\nset local statement_timeout='8s';\n"
    for n in (2540, 2556):
        for kind in ['technosphere', 'waste']:
            sql += f"set local role anon; select pg_temp.probe('{phase}',1,'no-match-{n}','{kind}',{literal(call(n,kind))}); reset role;\n"
sql += "set local statement_timeout='60s'; update public.flows set json=jsonb_set(json,'{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}',to_jsonb(case when right(id::text,12)::integer-10000=1 or (right(id::text,12)::integer-10000)%61=0 then 'Product flow' when (right(id::text,12)::integer-10000)%67=0 then 'Waste flow' else 'Elementary flow' end)) where id::text like '82400000%' and right(id::text,12)::bigint>10000;\n"

# Reuse the adversarial source update from the pgTAP regression unchanged.
text = FIXTURE.read_text()
a = text.index('update public.processes set json=jsonb_set(json,\'{processDataSet,exchanges,exchange}\'', text.index('-- Sparse valid rows,'))
b = text.index('delete from exchange_pages;', a)
sql += text[a:b]
for phase in ['baseline', 'candidate']:
    sql += ((baseline + refresh) if phase == 'baseline' else candidate) + "\nset local statement_timeout='8s';\n"
    for kind in ['all', 'technosphere', 'elementary', 'waste']:
        q = call(2540, kind, limit=2)
        sql += 'set local role anon;\n'
        sql += f"select pg_temp.probe('{phase}',1,'adversarial','{kind}-first',{literal(q)});\n"
        # Actual first-page cursor, then final page (at most 7 supported rows).
        for page in range(2, 5):
            c = f"(select response::jsonb->>'nextCursor' from measurements where phase='{phase}' and scenario='adversarial' and shape='{kind}-{'first' if page == 2 else page-1}')"
            q = f"select case when {c} is null then null else ({call(2540, kind, cursor=c, limit=2)}) end"
            sql += f"select pg_temp.probe('{phase}',1,'adversarial','{kind}-{page}',{literal(q)});\n"
        for shape, q in [('invalid', call(2540, kind, "'invalid'")), ('outside', call(2540, kind, scope='uslci'))]:
            sql += f"select pg_temp.probe('{phase}',1,'adversarial','{kind}-{shape}',{literal(q)});\n"
        sql += 'reset role;\n'
# Hidden dependencies and invalid functional units agree without changing metadata.
for mutation in ["update private.dataset_display_settings set is_visible=false where dataset_kind='unitgroup'",
                 "update private.dataset_display_settings set is_visible=true where dataset_kind='unitgroup'; update public.processes set json=jsonb_set(json,'{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}','\"999\"') where id::text like '82400000%' "]:
    scenario = 'hidden' if 'false' in mutation else 'invalid-functional-unit'
    sql += mutation + ';\n'
    for phase in ['baseline', 'candidate']:
        sql += ((baseline + refresh) if phase == 'baseline' else candidate) + "\nset local statement_timeout='8s';\n"
        sql += f"set local role anon; select pg_temp.probe('{phase}',1,'{scenario}','first',{literal(call(2540))}); reset role;\n"
sql += "select jsonb_build_object('phase',phase,'iteration',iteration,'scenario',scenario,'shape',shape,'seconds',seconds,'digest',md5(response),'row_count',jsonb_array_length(response::jsonb->'rows'),'first_id',response::jsonb#>>'{rows,0,internalId}','error',response::jsonb->>'sqlstate','plan',plan) from measurements; select jsonb_build_object('kind_plan',plan) from kind_plans; rollback;"
result = run(sql)
if result.returncode:
    raise RuntimeError(result.stderr[-4000:])
records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
rows = [r for r in records if 'phase' in r]
kind_plan = next(r['kind_plan'] for r in records if 'kind_plan' in r)
def plan_nodes(node):
    yield node
    for child in node.get('Plans', []):
        yield from plan_nodes(child)


nodes = list(plan_nodes(kind_plan[0]['Plan']))
flow_reads = [n for n in nodes if n.get('Relation Name') == 'flows']
assert flow_reads and all(n['Actual Loops'] == 2556 and n['Actual Rows'] == 1 for n in flow_reads), 'One exact Flow row per distinct reference required'
assert any(n.get('Index Name') == 'flows_pkey' for n in nodes), 'Exact Flow primary-key plan required'
assert len(rows) == 204, len(rows)
for scenario, shape in {(r['scenario'], r['shape']) for r in rows}:
    group = [r for r in rows if (r['scenario'], r['shape']) == (scenario, shape)]
    assert {r['phase'] for r in group} == {'baseline', 'candidate'}
    assert len({r['digest'] for r in group}) == 1, (scenario, shape, 'byte response drift')
for r in rows:
    if r['scenario'].startswith(('2540-', '2556-')):
        n_text, kind = r['scenario'].split('-')
        ids = [i for i in range(1, int(n_text)+1) if kind == 'all' or
               (kind == 'technosphere' and (i == 1 or i % 61 == 0)) or
               (kind == 'waste' and i != 1 and i % 61 != 0 and i % 67 == 0) or
               (kind == 'elementary' and i != 1 and i % 61 != 0 and i % 67 != 0)]
        offset = {'first': 0, 'second': 20, 'last': (len(ids)-1)//20*20}[r['shape']]
        assert r['row_count'] == min(20, len(ids)-offset) and r['first_id'] == str(ids[offset]) and r['error'] is None, r
    elif r['scenario'].startswith('no-match-'):
        assert r['row_count'] == 0 and r['error'] is None, r
    elif r['shape'].endswith('-invalid'):
        assert r['error'] == '22023', r
assert max(r['seconds'] for r in rows if r['phase'] == 'candidate') < 8
check = run('select count(*) from private.dataset_display_settings; select private.portal_display_assert_contract_v1();')
assert check.returncode == 0 and check.stdout.strip() == '0', 'Rollback cleanup/contract failed'
report = {'passed': True, 'classification': 'local sequential initial/repeat, uncontrolled shared caches; no cold-cache or load qualification',
          'fixture_exchange_counts': [2540, 2556], 'rows': rows, 'kind_plan': kind_plan,
          'sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [BASE, CANDIDATE, FIXTURE, Path(__file__)]},
          'upgrade': 'populated predecessor; injected failure rollback; repeat apply; unchanged source/settings/projection, other functions, ACL/owners/config and LCIA',
          'cleanup': 'rolled back, empty settings, manifest valid'}
args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'passed': True, 'measurements': len(rows), 'report': str(args.report)}))
