#!/usr/bin/env python3
"""Fresh retry clocks after real row-lock waits on the exact owned #828 local DB."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import time

CONTAINER='supabase_db_database-task828'
ACTOR='82800000-0000-4000-8000-000000000065'
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--receipt',type=Path,required=True)
a=p.parse_args()
if a.receipt.exists():p.error('Receipt must be new')
owner=json.loads(Path('/tmp/database-task828-local/owner.json').read_text())
spec=importlib.util.spec_from_file_location('bounded_sessions',Path(__file__).with_name('20260923_derivative_scheduler_concurrency.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.CONTAINER=CONTAINER
endpoint=h.local_docker_endpoint()
labels=json.loads(subprocess.check_output(['docker','inspect',CONTAINER,'--format','{{json .Config.Labels}}'],text=True))
if owner.get('owner')!='Database#828' or not endpoint.startswith('unix:///') or os.environ.get('DOCKER_HOST') or labels.get('com.supabase.cli.project')!='database-task828':p.error('Exact owned local Unix Docker required')
c,b,peer=[h.Session(name,'task828-clock',time.monotonic()+90,endpoint) for name in ('control','blocker','retry')]
receipt={'owner':'Database#828','syntheticOnly':True,'checks':[],'cleanup':'not_needed'}
ids=[];actor_created=False;thread=None
try:
 if c.scalar("select current_setting('server_version');")!='17.11' or c.scalar('select count(*) from private.worker_jobs;')!='0':raise RuntimeError('Empty local17.11 queue required')
 c.query(f"insert into auth.users(id,aud,role,email) values('{ACTOR}','authenticated','authenticated','task828-clock-wait@example.invalid');");actor_created=True
 c.query("select set_config('request.jwt.claim.role','service_role',false);");peer.query("select set_config('request.jwt.claim.role','service_role',false);")
 for label in ('crossed','future'):
  job_id=c.scalar(f"select api.svc_ai_tidas_suggestion_enqueue('{ACTOR}','process','{{\"processDataSet\":{{\"name\":\"{label}\"}}}}')#>>'{{data,id}}';");ids.append(job_id)
  c.query(f"select api.svc_worker_cancel_job('{job_id}',null,'task828 synthetic retry-clock')->>'ok';")
 for job_id,cross in zip(ids,(True,False)):
  c.query(f"update private.worker_jobs set timeout_at=clock_timestamp()+interval '{'1s' if cross else '10s'}' where id='{job_id}';")
  b.query(f"begin;select id from private.worker_jobs where id='{job_id}' for update;")
  before=c.json(f"select to_jsonb(j) from private.worker_jobs j where id='{job_id}';")
  outcome={}
  def retry():
   try:outcome['response']=peer.json(f"select private.worker_retry_job('{job_id}');")
   except BaseException as exc:outcome['error']=type(exc).__name__
  thread=threading.Thread(target=retry);thread.start()
  for _ in range(50):
   if c.scalar(f"select count(*) from pg_stat_activity where pid={peer.pid} and wait_event_type='Lock';")=='1':break
   time.sleep(0.01)
  else:raise RuntimeError('Retry did not reach observed row-lock wait')
  if c.scalar(f"select (a.query_start<j.timeout_at)::text from pg_stat_activity a cross join private.worker_jobs j where a.pid={peer.pid} and j.id='{job_id}';")!='true':raise RuntimeError('Retry must start before the deadline')
  if cross:
   for _ in range(100):
    if c.scalar(f"select (clock_timestamp()>timeout_at)::text from private.worker_jobs where id='{job_id}';")=='true':break
    time.sleep(0.02)
   else:raise RuntimeError('Deadline crossing was not observed')
  release_at=c.scalar('select clock_timestamp()::text;')
  b.query('commit;');thread.join(10)
  if thread.is_alive() or 'error' in outcome:raise RuntimeError('Bounded retry did not complete')
  result=outcome['response']
  if cross:
   if result.get('code')!='WORKER_JOB_DEADLINE_EXPIRED':raise RuntimeError('Crossed lock wait must reject retry')
   if c.json(f"select to_jsonb(j) from private.worker_jobs j where id='{job_id}';")!=before:raise RuntimeError('Rejected retry mutated the row')
  else:
   if result.get('ok') is not True:raise RuntimeError('Future deadline retry must remain admissible')
   if c.scalar(f"select (j.updated_at>='{release_at}'::timestamptz and j.run_after=j.updated_at and e.created_at=j.updated_at)::text from private.worker_jobs j join private.worker_job_events e on e.job_id=j.id where j.id='{job_id}' and e.event_type='retried';")!='true':raise RuntimeError('Admitted retry audit must use fresh post-lock time')
  receipt['checks'].append({'case':'expired-after-wait' if cross else 'fresh-after-wait','lockWaitObserved':True,'startedBeforeDeadline':True,'pass':True})
finally:
 b.close()
 if thread is not None:thread.join(10)
 peer.close()
 try:
  if ids:
   exact=h.uuid_array(ids);c.query(f"delete from private.worker_jobs where id=any({exact}) and requested_by='{ACTOR}';")
  if actor_created:c.query(f"delete from auth.users where id='{ACTOR}';")
  if c.scalar(f"select count(*) from private.worker_jobs where requested_by='{ACTOR}';")!='0':raise RuntimeError('Exact synthetic fixture residue')
  receipt['cleanup']='verified'
 finally:
  c.close();a.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'checks':len(receipt['checks']),'cleanup':receipt['cleanup']}))
