#!/usr/bin/env python3
"""Bounded multi-session AI expiry races, only the explicitly owned #828 local DB."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

CONTAINER = 'supabase_db_database-task828'
ACTOR = '82800000-0000-4000-8000-000000000099'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--receipt', type=Path, required=True)
a = p.parse_args()
if a.receipt.exists():
    p.error('Receipt must be new')
owner = json.loads(Path('/tmp/database-task828-local/owner.json').read_text())
if owner.get('owner') != 'Database#828' or owner.get('project') != 'database-task828':
    p.error('Explicit isolated owner is required')
spec = importlib.util.spec_from_file_location('bounded_sessions', Path(__file__).with_name('20260923_derivative_scheduler_concurrency.py'))
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.CONTAINER = CONTAINER
endpoint = h.local_docker_endpoint()
if not endpoint.startswith('unix:///') or os.environ.get('DOCKER_HOST'):
    p.error('Local Unix Docker only')
labels = json.loads(subprocess.check_output(['docker', 'inspect', CONTAINER, '--format', '{{json .Config.Labels}}'], text=True))
if labels.get('com.supabase.cli.project') != 'database-task828':
    p.error('Wrong isolated container')
sessions = [h.Session(name, 'task828', time.monotonic()+120, endpoint) for name in ('control', 'blocker', 'peer')]
c, b, peer = sessions
receipt = {'owner': 'Database#828', 'syntheticOnly': True, 'checks': [], 'cleanup': 'not_needed'}
try:
    if c.scalar('select current_setting(\'server_version\');') != '17.11':
        raise RuntimeError('Exact server17.11 required')
    if c.scalar('select count(*) from private.worker_jobs;') != '0':
        raise RuntimeError('Empty isolated queue required')
    active = c.scalar("select active from cron.job where jobname='worker-ai-deadline-expiry';")
    c.query("select cron.alter_job(jobid,active:=false) from cron.job where jobname='worker-ai-deadline-expiry';")
    c.query(f"insert into auth.users(id,aud,role,email) values('{ACTOR}','authenticated','authenticated','task828-race@example.invalid');")
    c.query(f"select set_config('request.jwt.claim.role','service_role',false);")
    ids = []
    for label in ('locked', 'peer', 'fresh'):
        ids.append(c.scalar(f"select api.svc_ai_tidas_suggestion_enqueue('{ACTOR}','process','{{\"processDataSet\":{{\"name\":\"{label}\"}}}}')#>>'{{data,id}}';"))
    exact = h.uuid_array(ids)
    c.query(f"update private.worker_jobs set timeout_at=now()-interval '1h' where id in('{ids[0]}','{ids[1]}');")
    b.query(f"begin;select id from private.worker_jobs where id='{ids[0]}' for update;")
    started = time.monotonic()
    if peer.scalar('select private.worker_expire_ai_suggestions(50);') != '1':
        raise RuntimeError('Locked expired head must not prevent peer settlement')
    receipt['checks'].append({'case':'locked-peer-expiry','seconds':round(time.monotonic()-started,3)})
    b.query('rollback;')
    # A current claim wins ownership before deadline expiry. Expiry skips its lock
    # and, after commit, cannot cancel the now elapsed deadline under a live lease.
    b.query("begin;select set_config('request.jwt.claim.role','service_role',true);")
    claim = b.json("select private.worker_claim_jobs('ai','task828-race',1,900);")
    if claim['data'][0]['id'] != ids[2]:
        raise RuntimeError('Claim must expire the old pending row and admit fresh work')
    b.query(f"update private.worker_jobs set timeout_at=now()-interval '1s' where id='{ids[2]}';")
    if peer.scalar('select private.worker_expire_ai_suggestions(50);') != '0':
        raise RuntimeError('Expiry must skip in-flight claim locks')
    b.query('commit;')
    if peer.scalar('select private.worker_expire_ai_suggestions(50);') != '0':
        raise RuntimeError('Expiry must preserve a committed live lease')
    receipt['checks'].append({'case':'claim-lock-and-live-lease','pass':True})
    # Recovery sees an orphan, but an independent renewal wins the row lock first.
    c.query(f"update private.worker_jobs set lease_expires_at=now()-interval '1s' where id='{ids[2]}';")
    b.query(f"begin;update private.worker_jobs set lease_expires_at=now()+interval '1h' where id='{ids[2]}';")
    if peer.scalar('select private.worker_expire_ai_suggestions(50);') != '0':
        raise RuntimeError('Recovery must skip concurrent renewed row')
    b.query('commit;')
    if peer.scalar('select private.worker_expire_ai_suggestions(50);') != '0':
        raise RuntimeError('Recovery must recheck current renewed lease')
    receipt['checks'].append({'case':'renewal-wins-recovery','pass':True})
    # Existing supported cancellation races expiry and appends only one event.
    b.query("begin;select set_config('request.jwt.claim.role','service_role',true);")
    b.query(f"select api.svc_worker_cancel_job('{ids[2]}',null,'task828 synthetic race')->>'ok';")
    if peer.scalar('select private.worker_expire_ai_suggestions(50);') != '0':
        raise RuntimeError('Expiry must skip concurrent cancellation')
    b.query('commit;')
    if peer.scalar('select private.worker_expire_ai_suggestions(50);') != '0':
        raise RuntimeError('Terminal cancellation must stay idempotent')
    if c.scalar(f"select count(*) from private.worker_job_events where job_id='{ids[2]}' and event_type='cancelled';") != '1':
        raise RuntimeError('Race duplicated cancellation history')
    receipt['checks'].append({'case':'cancel-wins-expiry','pass':True})
finally:
    b.close()
    peer.close()
    try:
        if 'ids' in locals():
            c.query(f"delete from private.worker_jobs where id=any({exact}) and requested_by='{ACTOR}';delete from auth.users where id='{ACTOR}';")
            if c.scalar(f"select count(*) from private.worker_jobs where id=any({exact});") != '0':
                raise RuntimeError('Synthetic fixture residue')
            receipt['cleanup']='verified'
        if 'active' in locals():
            c.query("select cron.alter_job(jobid,active:="+('true' if active=='t' else 'false')+") from cron.job where jobname='worker-ai-deadline-expiry';")
    finally:
        c.close()
        a.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'checks':len(receipt['checks']),'cleanup':receipt['cleanup']}))
