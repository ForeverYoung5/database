begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;
select plan(37);
select ok(not has_function_privilege('anon', 'private.worker_expire_ai_suggestions(integer)', 'execute'), 'anonymous cannot invoke internal expiry');
select ok(not has_function_privilege('authenticated', 'private.worker_expire_ai_suggestions(integer)', 'execute'), 'authenticated cannot invoke internal expiry');
select ok(not has_function_privilege('service_role', 'private.worker_expire_ai_suggestions(integer)', 'execute'), 'service callers cannot sweep the internal queue');
set local role service_role;
select throws_ok('select private.worker_expire_ai_suggestions(50)', '42501', null, 'direct service expiry invocation is denied');
reset role;
set local role authenticated;
select throws_ok('select private.worker_expire_ai_suggestions(50)', '42501', null, 'direct authenticated expiry invocation is denied');
reset role;
select is((select count(*) from cron.job where jobname='worker-ai-deadline-expiry' and schedule='* * * * *' and command='set statement_timeout = ''8s''; select private.worker_expire_ai_suggestions(50);' and active), 1::bigint, 'one bounded minute scheduler settles deadlines without a consumer');
select is(private.worker_expire_ai_suggestions(), 0, 'empty expiry is a no-op');
insert into auth.users(id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values ('82800000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'task828@example.invalid', '{}', '{}');
create temporary table task828_jobs(label text primary key, id uuid, lease_token uuid, before_row jsonb);
create temporary table task828_responses(label text primary key, response jsonb);
grant all on task828_jobs, task828_responses to public;
select set_config('request.jwt.claim.role','service_role',true);
insert into task828_jobs(label,id)
select label, (api.svc_ai_tidas_suggestion_enqueue('82800000-0000-4000-8000-000000000001', 'process', jsonb_build_object('processDataSet',jsonb_build_object('name',label)))#>>'{data,id}')::uuid
from unnest(array['expired','boundary','stale','orphan','max_orphan','live','fresh','null','terminal','future_cancelled']) label;
update private.worker_jobs j set timeout_at=case when t.label='null' then null when t.label in ('fresh','future_cancelled') then now()+interval '1h' when t.label='boundary' then now() else now()-interval '1h' end
from task828_jobs t where t.id=j.id;
update private.worker_jobs j set status='stale' from task828_jobs t where t.id=j.id and t.label='stale';
update private.worker_jobs j set status='running', attempt_count=case when t.label='max_orphan' then max_attempts else 1 end, started_at=now()-interval '2h', leased_by='task828-worker', lease_token=gen_random_uuid(), lease_expires_at=case when t.label='live' then now()+interval '1h' else now()-interval '1m' end
from task828_jobs t where t.id=j.id and t.label in ('orphan','max_orphan','live');
update private.worker_jobs j set status='cancelled',cancelled_at=now(),finished_at=now() from task828_jobs t where t.id=j.id and t.label in ('terminal','future_cancelled');
update task828_jobs t set lease_token=j.lease_token, before_row=to_jsonb(j) from private.worker_jobs j where t.id=j.id;
select is(private.worker_expire_ai_suggestions(2), 2, 'expiry respects the requested batch bound');
select is(private.worker_expire_ai_suggestions(50), 3, 'remaining pending and lost-lease deadlines settle');
select is((select count(*) from private.worker_jobs j join task828_jobs t using(id) where t.label in ('expired','boundary','stale','orphan','max_orphan') and j.status='cancelled'),5::bigint,'queued, exact-boundary, stale, orphan and max-attempt orphan cancel');
select is((select count(*) from private.worker_jobs j join task828_jobs t using(id) where t.label in ('expired','boundary','stale','orphan','max_orphan') and j.error_code='worker_job_timeout' and j.cancelled_at=now() and j.finished_at=now() and j.lease_token is null and j.leased_by is null and j.lease_expires_at is null),5::bigint,'expiry timestamps and ownership release are atomic');
select ok(not exists(select 1 from private.worker_jobs j join task828_jobs t using(id) where t.label in ('expired','boundary','stale','orphan','max_orphan') and to_jsonb(j)-array['status','cancelled_at','cancelled_by','leased_by','lease_token','lease_expires_at','error_code','error_message','updated_at','finished_at'] is distinct from t.before_row-array['status','cancelled_at','cancelled_by','leased_by','lease_token','lease_expires_at','error_code','error_message','updated_at','finished_at']), 'expiry preserves payload, request identity, diagnostics, attempt and attribution');
select is((select count(*) from private.worker_job_events e join task828_jobs t on e.job_id=t.id where e.event_type='cancelled' and e.details->>'errorCode'='worker_job_timeout'),5::bigint,'one compact cancellation event per expired row');
select is((select count(*) from private.worker_job_events e join task828_jobs t on e.job_id=t.id where e.event_type='enqueued'),10::bigint,'original enqueue history remains');
select ok(not exists(select 1 from private.worker_jobs j join task828_jobs t using(id) where t.label in ('live','fresh','null','terminal','future_cancelled') and to_jsonb(j) is distinct from t.before_row), 'live leases, fresh/null deadlines and terminal rows remain byte-identical');
select is(private.worker_expire_ai_suggestions(),0,'repeated expiry is idempotent');
select is(private.worker_retry_job((select id from task828_jobs where label='expired'))->>'code','WORKER_JOB_DEADLINE_EXPIRED','explicit retry rejects an elapsed AI deadline');
select is(private.worker_retry_job((select id from task828_jobs where label='future_cancelled'))->>'ok','true','explicit retry preserves unelapsed AI deadline behavior');
select is((select timeout_at from private.worker_jobs j join task828_jobs t using(id) where label='future_cancelled'),now()+interval '1h','retry retains the original future deadline');
insert into task828_responses values('reenqueue',api.svc_ai_tidas_suggestion_enqueue('82800000-0000-4000-8000-000000000001','process','{"processDataSet":{"name":"expired"}}'));
select is((select response->>'ok' from task828_responses where label='reenqueue'),'true','a new explicit request is admitted after deadline cancellation');
select isnt((select response#>>'{data,id}' from task828_responses where label='reenqueue'),(select id::text from task828_jobs where label='expired'),'new request gets a new identity');
select is((select timeout_at from private.worker_jobs where id=(select (response#>>'{data,id}')::uuid from task828_responses where label='reenqueue')),now()+interval '30min','fresh request receives a fresh 30-minute admission deadline');
-- Claim must reject expired rows even if the bounded reaper has more work than its batch.
insert into task828_jobs(label,id)
select 'overflow_'||n,(api.svc_ai_tidas_suggestion_enqueue('82800000-0000-4000-8000-000000000001','process',jsonb_build_object('processDataSet',jsonb_build_object('name','overflow_'||n)))#>>'{data,id}')::uuid from generate_series(1,53)n;
update private.worker_jobs j set timeout_at=now()-interval '1h',priority=1000 from task828_jobs t where t.id=j.id and t.label like 'overflow_%';
insert into task828_responses values('claim',private.worker_claim_jobs('ai','task828-worker',1,900));
select is((select response->>'ok' from task828_responses where label='claim'),'true','AI claim still succeeds');
select is((select jsonb_array_length(response->'data') from task828_responses where label='claim'),1,'AI claim admits a fresh row beyond expired high-priority backlog');
select is((select count(*) from private.worker_jobs j join task828_jobs t using(id) where t.label like 'overflow_%' and j.status='running'),0::bigint,'expired rows are never claimed beyond the reaper batch');
select is((select count(*) from private.worker_jobs j join task828_jobs t using(id) where t.label like 'overflow_%' and j.status='cancelled'),1::bigint,'claim-triggered reaping uses its own bounded limit');
select is(private.worker_expire_ai_suggestions(999),50,'oversized batch input clamps to 50');
select is(private.worker_expire_ai_suggestions(),2,'bounded cron-style calls settle the remaining backlog');
select is(private.worker_record_job_result((select id from task828_jobs where label='orphan'),(select lease_token from task828_jobs where label='orphan'),'failed',p_error_code=>'test')->>'code','WORKER_JOB_NOT_RUNNING','late orphan results cannot overwrite timeout cancellation');
select is(private.worker_heartbeat_job((select id from task828_jobs where label='orphan'),(select lease_token from task828_jobs where label='orphan'))->>'code','WORKER_JOB_NOT_RUNNING','late orphan heartbeat cannot resurrect cancelled work');
select is(private.worker_heartbeat_job((select id from task828_jobs where label='live'),(select lease_token from task828_jobs where label='live'),p_lease_seconds=>900)->>'ok','true','current AI lease can renew after the admission deadline');
insert into task828_responses values('live_complete',private.worker_record_job_result((select id from task828_jobs where label='live'),(select lease_token from task828_jobs where label='live'),'completed','{"schemaVersion":"ai.tidas_suggestion.result.v1","status":"complete","dataType":"process","data":{"processDataSet":{}}}','ai.tidas_suggestion.result.v1'));
select is((select response->>'ok' from task828_responses where label='live_complete'),'true','current AI lease may complete after admission deadline');
select is(private.worker_record_job_result((select id from task828_jobs where label='live'),(select lease_token from task828_jobs where label='live'),'completed','{"schemaVersion":"ai.tidas_suggestion.result.v1","status":"complete","dataType":"process","data":{"processDataSet":{}}}','ai.tidas_suggestion.result.v1')->>'ok','true','same-lease exact terminal replay stays idempotent');
insert into task828_jobs(label,id) select 'solver',(private.worker_enqueue_job(p_job_kind=>'lca.solve_one',p_payload_json=>'{}',p_requested_by=>'82800000-0000-4000-8000-000000000001',p_timeout_at=>now()-interval '1h')#>>'{data,id}')::uuid;
select is(private.worker_expire_ai_suggestions(),0,'AI scheduler does not reap a solver deadline');
select is((private.worker_claim_jobs('solver','task828-solver',1,300)#>>'{data,0,id}'),(select id::text from task828_jobs where label='solver'),'non-AI claim behavior is unchanged');
select is(api.svc_worker_cancel_job((select id from task828_jobs where label='expired'),null,'repeat')->>'ok','true','supported cancellation remains idempotent after deadline expiry');
select is((select count(*) from private.worker_job_events e join task828_jobs t on e.job_id=t.id where t.label='expired' and event_type='cancelled'),1::bigint,'repeated cancellation does not append duplicate audit');
select * from finish();
rollback;
