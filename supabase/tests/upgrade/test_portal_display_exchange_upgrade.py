#!/usr/bin/env python3
"""Rollback-only #821 populated upgrade, exact response parity and local timings.

Run only on the explicitly owned empty local portal-exchanges-821 stack. Timings
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
BASE = ROOT / 'supabase/migrations/20261010171202_portal_display_without_license_gates.sql'
CANDIDATE = ROOT / 'supabase/migrations/20261011073000_optimize_portal_display_exchange_paging.sql'
FIXTURE = ROOT / 'supabase/tests/20261011_portal_display_exchange_paging.sql'
CONTAINER = 'supabase_db_portal-exchanges-821'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--container', required=True, choices=[CONTAINER])
p.add_argument('--report', required=True, type=Path)
args = p.parse_args()
if args.report.exists():
    p.error('Report path must be new')
owner = Path('/private/tmp/lca-portal-821-20261011/OWNER.md').read_text()
if 'tiangong-lca/database#821' not in owner:
    p.error('Explicit task ownership is required')
context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
if not context['Endpoints']['docker']['Host'].startswith('unix://'):
    p.error('Only local Docker is admitted')
labels = json.loads(subprocess.check_output(['docker', 'inspect', CONTAINER,
                                            '--format', '{{json .Config.Labels}}'], text=True))
if labels.get('com.supabase.cli.project') != 'portal-exchanges-821':
    p.error('Wrong isolated stack')


def run(sql):
    return subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-U', 'postgres',
                           '-d', 'postgres', '-Atq', '-v', 'ON_ERROR_STOP=1'],
                          input=sql, text=True, capture_output=True, timeout=600)


check = run('select inet_server_addr() is null; select count(*) from private.dataset_display_settings;')
if check.returncode or check.stdout.strip().splitlines() != ['t', '0']:
    p.error('Refusing non-local or nonempty database')
base = BASE.read_text()
baseline = base[base.index('CREATE OR REPLACE FUNCTION "private"."display_api_list_process_exchanges_v1"'):base.index('-- Policy-only rewrite')]
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
 if shape not like '%-invalid' and v ? 'sqlstate' then raise exception 'unexpected response: % % %',scenario,shape,v; end if;
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
    return f"select api.portal_list_process_exchanges_v2(array['{scope}'],'82100000-0000-4000-8000-{n:012d}','01.00.000','{kind}',{cursor},{limit})"


def cursor(n, internal_id, kind='all', row_kind='technosphere'):
    return "private.display_cursor_encode_v1(jsonb_build_object('v',1,'processId','82100000-0000-4000-8000-%012d','processVersion','01.00.000','filterKind','%s','internalId','%s','kind','%s'))" % (n, kind, internal_id, row_kind)


for iteration in range(1, 4):
    for phase in (['baseline', 'candidate'] if iteration % 2 else ['candidate', 'baseline']):
        sql += (baseline + refresh) if phase == 'baseline' else candidate
        sql += "set local statement_timeout='8s'; select set_config('portal.display_brands','worldsteel',true); select set_config('portal.display_global','false',true); select set_config('portal.display_filter_brand','',true);\n"
        for n in (2540, 2556):
            # Construct a valid last-page cursor without measuring 127 preceding pages.
            for shape, c in [('first', 'null'), ('second', cursor(n, '20')), ('last', cursor(n, str((n-1)//20*20)))]:
                # Private cursor encoder is not anonymous; resolve it before SET ROLE.
                sql += f"select set_config('test.cursor',coalesce({c},''),true);\nset local role anon;\n"
                q = call(n, cursor="nullif(current_setting('test.cursor'),'')")
                sql += f"select pg_temp.probe('{phase}',{iteration},'{n}','{shape}',{literal(q)},{str(iteration == 1 and shape == 'first').lower()});\nreset role;\n"
        sql += 'select pg_temp.verify_upgrade();\n'

# Reuse the adversarial source update from the pgTAP regression unchanged.
text = FIXTURE.read_text()
a = text.index('update public.processes set json=jsonb_set(json,\'{processDataSet,exchanges,exchange}\'')
b = text.index('delete from exchange_pages;', a)
sql += text[a:b]
for phase in ['baseline', 'candidate']:
    sql += (baseline + refresh) if phase == 'baseline' else candidate
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
                 "update private.dataset_display_settings set is_visible=true where dataset_kind='unitgroup'; update public.processes set json=jsonb_set(json,'{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}','\"999\"') where id::text like '82100000%' "]:
    scenario = 'hidden' if 'false' in mutation else 'invalid-functional-unit'
    sql += mutation + ';\n'
    for phase in ['baseline', 'candidate']:
        sql += (baseline + refresh) if phase == 'baseline' else candidate
        sql += f"set local role anon; select pg_temp.probe('{phase}',1,'{scenario}','first',{literal(call(2540))}); reset role;\n"
sql += "select jsonb_build_object('phase',phase,'iteration',iteration,'scenario',scenario,'shape',shape,'seconds',seconds,'digest',md5(response),'row_count',jsonb_array_length(response::jsonb->'rows'),'first_id',response::jsonb#>>'{rows,0,internalId}','error',response::jsonb->>'sqlstate','plan',plan) from measurements; rollback;"
result = run(sql)
if result.returncode:
    raise RuntimeError(result.stderr[-4000:])
rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
assert len(rows) == 88, len(rows)
for scenario, shape in {(r['scenario'], r['shape']) for r in rows}:
    group = [r for r in rows if (r['scenario'], r['shape']) == (scenario, shape)]
    assert {r['phase'] for r in group} == {'baseline', 'candidate'}
    assert len({r['digest'] for r in group}) == 1, (scenario, shape, 'byte response drift')
for r in rows:
    if r['scenario'] in ('2540', '2556'):
        n = int(r['scenario'])
        first = {'first': 1, 'second': 21, 'last': (n-1)//20*20+1}[r['shape']]
        assert r['first_id'] == str(first) and r['row_count'] == min(20,n-first+1), r
    elif r['shape'].endswith('-invalid'):
        assert r['error'] == '22023', r
assert max(r['seconds'] for r in rows if r['phase'] == 'candidate') < 8
check = run('select count(*) from private.dataset_display_settings; select private.portal_display_assert_contract_v1();')
assert check.returncode == 0 and check.stdout.strip() == '0', 'Rollback cleanup/contract failed'
report = {'passed': True, 'classification': 'local sequential initial/repeat, uncontrolled shared caches; no cold-cache or load qualification',
          'fixture_exchange_counts': [2540, 2556], 'rows': rows,
          'sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [BASE, CANDIDATE, FIXTURE, Path(__file__)]},
          'upgrade': 'populated predecessor; injected failure rollback; repeat apply; unchanged source/settings/projection, other functions, ACL/owners/config and LCIA',
          'cleanup': 'rolled back, empty settings, manifest valid'}
args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'passed': True, 'measurements': len(rows), 'report': str(args.report)}))
