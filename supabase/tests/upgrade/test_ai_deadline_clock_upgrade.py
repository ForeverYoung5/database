#!/usr/bin/env python3
"""Rollback-only populated upgrade from already-applied #828 to fresh-clock repair."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[3]
CONTAINER='supabase_db_database-task828'
BASE='f90d05fc2da9101b1a00d6bba49cb7e4e30a316c'
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--receipt',type=Path,required=True)
a=p.parse_args()
if a.receipt.exists():p.error('Receipt must be new')
owner=json.loads(Path('/tmp/database-task828-local/owner.json').read_text())
endpoint=subprocess.check_output(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'],text=True).strip()
labels=json.loads(subprocess.check_output(['docker','inspect',CONTAINER,'--format','{{json .Config.Labels}}'],text=True))
if owner.get('owner')!='Database#828' or not endpoint.startswith('unix:///') or os.environ.get('DOCKER_HOST') or labels.get('com.supabase.cli.project')!='database-task828':p.error('Exact owned local Unix Docker required')
cmd=['docker','exec','-i',CONTAINER,'psql','-X','-Atq','-U','postgres','-v','ON_ERROR_STOP=1']
r=subprocess.run(cmd,input="select current_setting('server_version');select count(*) from private.worker_jobs;",text=True,capture_output=True,check=True)
if r.stdout.strip().splitlines()!=['17.11','0']:p.error('Empty local17.11 queue required')
base='\n'.join(subprocess.check_output(['git','show',BASE+':supabase/workspace/schemas/private/functions/'+name+'/definition.sql'],cwd=ROOT,text=True) for name in ('worker_expire_ai_suggestions','worker_claim_jobs','worker_retry_job'))
candidate=(ROOT/'supabase/migrations/20261011143718_ai_deadline_fresh_clock.sql').read_text()
sql="begin;set local statement_timeout='30s';set local lock_timeout='1s';\n"+base+r"""
insert into auth.users(id,aud,role,email) values('82800000-0000-4000-8000-000000000064','authenticated','authenticated','task828-forward-upgrade@example.invalid');
select set_config('request.jwt.claim.role','service_role',true);
create temporary table clock_upgrade_jobs(label text,id uuid);
insert into clock_upgrade_jobs select label,(api.svc_ai_tidas_suggestion_enqueue('82800000-0000-4000-8000-000000000064','process',jsonb_build_object('processDataSet',jsonb_build_object('name',label)))#>>'{data,id}')::uuid from unnest(array['expired','live','fresh'])label;
update private.worker_jobs j set timeout_at=clock_timestamp()+interval '200ms' from clock_upgrade_jobs t where t.id=j.id and t.label<>'fresh';
update private.worker_jobs j set status='running',attempt_count=1,started_at=now(),leased_by='task828-upgrade-clock',lease_token=gen_random_uuid(),lease_expires_at=clock_timestamp()+interval '1h' from clock_upgrade_jobs t where t.id=j.id and t.label='live';
select pg_sleep(0.3);
savepoint legacy_repro;
do $$begin
 if jsonb_array_length(private.worker_claim_jobs('ai','task828-old-clock',1,900)->'data')<>1 then raise exception 'legacy clock bug witness missing';end if;
end$$;
rollback to legacy_repro;
create temporary table saved_rows as select id,to_jsonb(j) as body from private.worker_jobs j;
create temporary table saved_events as select id,to_jsonb(e) as body from private.worker_job_events e;
create temporary table saved_functions as select p.oid,p.proname,pg_get_functiondef(p.oid) definition,p.proowner,p.proacl,p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('private','api','util') and p.prokind='f';
create temporary table saved_cron as select jobid,to_jsonb(j) as body from cron.job j;
create function pg_temp.verify_preserved() returns void language plpgsql as $$begin
 if exists(select 1 from saved_rows s join private.worker_jobs j using(id) where s.body is distinct from to_jsonb(j)) then raise exception 'canonical row drift';end if;
 if exists(select 1 from saved_events s join private.worker_job_events e using(id) where s.body is distinct from to_jsonb(e)) then raise exception 'prior audit drift';end if;
 if exists(select 1 from saved_functions s join pg_proc p using(oid) where s.proowner<>p.proowner or s.proacl is distinct from p.proacl or s.proconfig is distinct from p.proconfig or (s.proname not in('worker_expire_ai_suggestions','worker_claim_jobs','worker_retry_job') and s.definition<>pg_get_functiondef(p.oid))) then raise exception 'unrelated routine or ACL drift';end if;
 if exists(select 1 from saved_cron s join cron.job j using(jobid) where s.body is distinct from to_jsonb(j)) then raise exception 'cron drift';end if;
end$$;
savepoint failed_forward_upgrade;
"""+candidate+r"""
\set ON_ERROR_STOP off
do $$begin raise exception 'expected synthetic forward migration failure';end$$;
rollback to failed_forward_upgrade;
\set ON_ERROR_STOP on
do $$begin if exists(select 1 from saved_functions s join pg_proc p using(oid) where s.definition<>pg_get_functiondef(p.oid)) then raise exception 'failed forward upgrade leaked definition';end if;end$$;
select pg_temp.verify_preserved();
"""+candidate+r"""
select pg_temp.verify_preserved();
do $$begin
 if private.worker_expire_ai_suggestions(50)<>1 then raise exception 'fresh clock failed to settle populated expired row';end if;
 if exists(select 1 from private.worker_jobs j join clock_upgrade_jobs t using(id) join saved_rows s using(id) where t.label in('live','fresh') and to_jsonb(j) is distinct from s.body) then raise exception 'current lease or fresh row drift';end if;
 if exists(select 1 from saved_events s join private.worker_job_events e using(id) where to_jsonb(e) is distinct from s.body) then raise exception 'old audit changed';end if;
end$$;
select jsonb_build_object('alreadyAppliedDeadlineMigration',true,'legacyClockWitness',true,'populatedRows',3,'atomicFailureRollback',true,'canonicalAndAuditPreserved',true,'unrelatedFunctionsAclCronPreserved',true,'expiredSettled',1,'activeLeasePreserved',true);
rollback;
"""
r=subprocess.run(cmd,input=sql,text=True,capture_output=True,timeout=90)
if r.returncode:
 a.receipt.write_text(json.dumps({'pass':False,'diagnostics':'withheld','cleanup':'rollback-on-session-exit'})+'\n');raise SystemExit('Owned local forward upgrade failed; raw diagnostics withheld')
rows=[json.loads(x) for x in r.stdout.splitlines() if x.startswith('{')]
if len(rows)!=1:raise SystemExit('Unexpected forward-upgrade receipt shape')
r=subprocess.run(cmd,input="select count(*) from private.worker_jobs;select count(*) from auth.users where id='82800000-0000-4000-8000-000000000064';",text=True,capture_output=True,check=True)
if r.stdout.strip().splitlines()!=['0','0']:raise SystemExit('Synthetic forward-upgrade fixture residue')
a.receipt.write_text(json.dumps({'owner':'Database#828','pass':True,'proof':rows[0],'cleanup':'verified rollback'},indent=2)+'\n')
print('Already-applied #828 populated forward upgrade and atomic-failure rollback PASS')
