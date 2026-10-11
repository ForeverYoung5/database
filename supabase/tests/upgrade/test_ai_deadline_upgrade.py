#!/usr/bin/env python3
"""Rollback-only populated #828 lifecycle upgrade on the exact owned local DB."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
CONTAINER = 'supabase_db_database-task828'
BASE = '91dcf239d7ab41f52f14ea0a8599d8acdb830120'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--receipt', type=Path, required=True)
a = p.parse_args()
if a.receipt.exists():
    p.error('Receipt must be new')
owner = json.loads(Path('/tmp/database-task828-local/owner.json').read_text())
endpoint = subprocess.check_output(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'],text=True).strip()
labels = json.loads(subprocess.check_output(['docker','inspect',CONTAINER,'--format','{{json .Config.Labels}}'],text=True))
if owner.get('owner')!='Database#828' or not endpoint.startswith('unix:///') or os.environ.get('DOCKER_HOST') or labels.get('com.supabase.cli.project')!='database-task828':
    p.error('Exact owned local Unix Docker required')
cmd=['docker','exec','-i',CONTAINER,'psql','-X','-Atq','-U','postgres','-v','ON_ERROR_STOP=1']
identity=subprocess.run(cmd,input="select current_setting('server_version');select count(*) from private.worker_jobs;",text=True,capture_output=True,check=True).stdout.strip().splitlines()
if identity!=['17.11','0']:
    p.error('Exact empty local17.11 queue required')
base='\n'.join(subprocess.check_output(['git','show',BASE+':supabase/workspace/schemas/private/functions/'+name+'/definition.sql'],cwd=ROOT,text=True) for name in ('worker_claim_jobs','worker_retry_job'))
candidate=(ROOT/'supabase/migrations/20261011141704_ai_queue_deadline_recovery.sql').read_text()+'\n'+(ROOT/'supabase/migrations/20261011143718_ai_deadline_fresh_clock.sql').read_text()
sql="""begin;set local statement_timeout='30s';set local lock_timeout='1s';
select cron.unschedule(jobid) from cron.job where jobname='worker-ai-deadline-expiry';
drop index private.worker_jobs_ai_deadline_idx;
"""+base+"""
drop function private.worker_expire_ai_suggestions(integer);
insert into auth.users(id,aud,role,email) values('82800000-0000-4000-8000-000000000088','authenticated','authenticated','task828-upgrade@example.invalid');
select set_config('request.jwt.claim.role','service_role',true);
create temporary table upgrade_jobs(label text,id uuid);
insert into upgrade_jobs select label,(api.svc_ai_tidas_suggestion_enqueue('82800000-0000-4000-8000-000000000088','process',jsonb_build_object('processDataSet',jsonb_build_object('name',label)))#>>'{data,id}')::uuid from unnest(array['expired','live','fresh'])label;
update private.worker_jobs j set timeout_at=now()-interval '1h' from upgrade_jobs t where t.id=j.id and t.label<>'fresh';
update private.worker_jobs j set status='running',attempt_count=1,started_at=now(),leased_by='task828-upgrade',lease_token=gen_random_uuid(),lease_expires_at=now()+interval '1h' from upgrade_jobs t where t.id=j.id and t.label='live';
create temporary table saved_rows as select id,to_jsonb(j) as body from private.worker_jobs j;
create temporary table saved_events as select id,to_jsonb(e) as body from private.worker_job_events e;
create temporary table saved_functions as select p.oid,p.proname,pg_get_functiondef(p.oid) definition,p.proowner,p.proacl,p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('private','api','util') and p.prokind='f';
create temporary table saved_cron as select jobid,to_jsonb(j) as body from cron.job j;
create function pg_temp.verify_preserved() returns void language plpgsql as $$begin
 if exists(select 1 from saved_rows s join private.worker_jobs j using(id) where s.body is distinct from to_jsonb(j)) then raise exception 'canonical row drift';end if;
 if exists(select 1 from saved_events s join private.worker_job_events e using(id) where s.body is distinct from to_jsonb(e)) then raise exception 'audit history drift';end if;
 if exists(select 1 from saved_functions s join pg_proc p using(oid) where s.proowner<>p.proowner or s.proacl is distinct from p.proacl or s.proconfig is distinct from p.proconfig or (s.proname not in('worker_claim_jobs','worker_retry_job') and s.definition<>pg_get_functiondef(p.oid))) then raise exception 'unrelated routine or ACL drift';end if;
 if exists(select 1 from saved_cron s join cron.job j using(jobid) where s.body is distinct from to_jsonb(j)) then raise exception 'unrelated cron drift';end if;
end$$;
savepoint failed_upgrade;
"""+candidate+"""
\set ON_ERROR_STOP off
do $$begin raise exception 'expected synthetic migration failure';end$$;
rollback to failed_upgrade;
\set ON_ERROR_STOP on
do $$begin
 if exists(select 1 from saved_functions s join pg_proc p using(oid) where s.definition<>pg_get_functiondef(p.oid)) or to_regprocedure('private.worker_expire_ai_suggestions(integer)') is not null or to_regclass('private.worker_jobs_ai_deadline_idx') is not null or exists(select 1 from cron.job where jobname='worker-ai-deadline-expiry') then raise exception 'failed upgrade residue';end if;
end$$;
select pg_temp.verify_preserved();
"""+candidate+"""
select pg_temp.verify_preserved();
do $$begin
 if private.worker_expire_ai_suggestions(50)<>1 then raise exception 'populated expired fixture did not settle';end if;
 if exists(select 1 from private.worker_jobs j join upgrade_jobs t using(id) join saved_rows s using(id) where t.label in('live','fresh') and to_jsonb(j) is distinct from s.body) then raise exception 'live/fresh upgrade drift';end if;
 if exists(select 1 from saved_events s join private.worker_job_events e using(id) where to_jsonb(e) is distinct from s.body) then raise exception 'prior audit changed';end if;
end$$;
select jsonb_build_object('populatedRows',3,'failedUpgradeRollback',true,'canonicalAndAuditPreserved',true,'unrelatedFunctionsAndAclPreserved',true,'unrelatedCronPreserved',true,'expiredSettled',1,'activeLeasePreserved',true);
rollback;
"""
r=subprocess.run(cmd,input=sql,text=True,capture_output=True,timeout=90)
if r.returncode:
    a.receipt.write_text(json.dumps({'pass':False,'diagnostics':'withheld','cleanup':'rollback-on-session-exit'})+'\n')
    raise SystemExit('Owned local upgrade failed; raw diagnostics withheld')
rows=[json.loads(x) for x in r.stdout.splitlines() if x.startswith('{')]
if len(rows)!=1:
    raise SystemExit('Unexpected upgrade receipt shape')
identity=subprocess.run(cmd,input="select count(*) from private.worker_jobs;select count(*) from auth.users where id='82800000-0000-4000-8000-000000000088';",text=True,capture_output=True,check=True).stdout.strip().splitlines()
if identity!=['0','0']:
    raise SystemExit('Owned upgrade fixture residue')
a.receipt.write_text(json.dumps({'owner':'Database#828','pass':True,'proof':rows[0],'cleanup':'verified rollback'},indent=2)+'\n')
print('Populated upgrade and atomic-failure rollback PASS; fixture cleanup verified')
