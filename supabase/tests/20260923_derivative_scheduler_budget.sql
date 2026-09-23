begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

\ir fixtures/derivative_scheduler703.sql
select pg_temp.scheduler703_seed(0, 66, 6, 5);

savepoint ready_behind_waiters;
update util.dataset_derivative_rebuild_requests request
set status = case when target.ordinal <= 60 then 'dispatching' else 'queued' end,
    phase = case when target.ordinal <= 60 then 'failure_draining' else 'admitted' end,
    failure_release_not_before = case when target.ordinal <= 60 then clock_timestamp() + interval '1 hour' end,
    drain_not_before = clock_timestamp() + interval '1 hour',
    updated_at = clock_timestamp() - case when target.ordinal <= 60 then interval '2 hours' else interval '1 hour' end
from pg_temp.scheduler703_targets target where request.id = target.request_id;
create temporary table scheduler703_call as select util.process_dataset_derivative_rebuilds(25) visits;
select
  (select count(*)::integer from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where t.ordinal>60 and r.phase='quarantining') as ready,
  (select visits from scheduler703_call) as visits,
  (select count(*)::integer from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where t.ordinal<=60 and r.updated_at>clock_timestamp()-interval '30 seconds') as audited,
  (select count(*)::integer from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where t.ordinal<=60 and r.status='failed') as failed
\gset ready_
rollback to ready_behind_waiters;
select is(:'ready_ready'::integer,6,'six ready requests behind sixty drain waiters progress in one call');
select ok(:'ready_visits'::integer<=25,'visit count never exceeds p_limit or 25');
select ok(:'ready_audited'::integer<=5,'at most five waiting rows consume audit work');
select is(:'ready_failed'::integer,0,'future failure drains never release early');

savepoint dispatch_cap;
update util.dataset_derivative_rebuild_requests r
set status='dispatching', phase='quarantining', drain_not_before=clock_timestamp()-interval '1 second'
from pg_temp.scheduler703_targets t where r.id=t.request_id;
create temporary table scheduler703_call as select util.process_dataset_derivative_rebuilds(25) visits;
select
  (select count(*)::integer from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where r.markdown_request_id is not null) as dispatched,
  (select visits from scheduler703_call) as visits,
  (select count(distinct r.actor_user_id)::integer from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where r.markdown_request_id is not null) as actors
\gset cap_
select util.process_dataset_derivative_rebuilds(25) as visits \gset cap2_
select util.process_dataset_derivative_rebuilds(25) as visits \gset cap3_
select util.process_dataset_derivative_rebuilds(25) as visits \gset cap4_
select
  (select count(distinct r.actor_user_id)::integer from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where r.markdown_request_id is not null) as actors,
  (select count(distinct r.batch_id)::integer from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where r.markdown_request_id is not null) as batches
\gset cap_final_
rollback to dispatch_cap;
select is(:'cap_dispatched'::integer,5,'twenty-five visit allowance dispatches at most five Markdown requests');
select ok(:'cap_visits'::integer<=25,'dispatch and audit share the total visit bound');
select is(:'cap_actors'::integer,5,'five dispatch slots serve five actors rather than one actor backlog');
select is(:'cap_final_actors'::integer,6,'every actor receives progress under the finite-cohort service bound');
select is(:'cap_final_batches'::integer,18,'actor-local batches alternate: all eighteen batches receive service in four ticks');

savepoint audit_overflow_drift;
update util.dataset_derivative_rebuild_requests r
set status='dispatching', phase='quarantining', drain_not_before=clock_timestamp()-interval '1 second',
    expected_json_sha256=repeat('f',64)
from pg_temp.scheduler703_targets t where r.id=t.request_id;
select util.process_dataset_derivative_rebuilds(25) as visits \gset overflow_call_
select
  count(*) filter(where r.last_error->>'code'='DERIVATIVE_PRIMARY_DRIFT') as drift,
  count(*) filter(where r.last_error->>'code'='DERIVATIVE_PRIMARY_DRIFT' and to_jsonb(r)->>'scheduler_selected_at' is null) as audit_drift,
  count(*) filter(where r.status='failed') as failed
from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id
\gset overflow_
rollback to audit_overflow_drift;
select ok(:'overflow_drift'::integer>5,'ready overflow receives independent primary-drift audit after five progress slots');
select ok(:'overflow_audit_drift'::integer>0,'audit finding does not masquerade as progress selection');
select is(:'overflow_failed'::integer,0,'audited primary drift preserves the full nonterminal failure drain');

savepoint waiting_drift;
update util.dataset_derivative_rebuild_requests r
set status='markdown_pending',phase='markdown_dispatched',markdown_request_id=-7030000-t.ordinal,
    markdown_dispatched_at=clock_timestamp(),markdown_deadline_at=clock_timestamp()+interval '1 hour',
    expected_json_sha256=repeat('f',64)
from pg_temp.scheduler703_targets t where r.id=t.request_id;
select util.process_dataset_derivative_rebuilds(25) as visits \gset waiting_call_
select count(*) as drift from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where r.last_error->>'code'='DERIVATIVE_PRIMARY_DRIFT'
\gset waiting_
rollback to waiting_drift;
select is(:'waiting_drift'::integer,5,'waiting HTTP rows still receive a bounded primary-drift audit');

savepoint limit_contract;
select util.process_dataset_derivative_rebuilds(0) as zero,
  util.process_dataset_derivative_rebuilds(null) as null_limit,
  util.process_dataset_derivative_rebuilds(1) as one,
  util.process_dataset_derivative_rebuilds(999) as max_visits,
  pg_get_function_arguments('util.process_dataset_derivative_rebuilds(integer)'::regprocedure) as signature
\gset limits_
rollback to limit_contract;
select is(:'limits_zero'::integer,0,'zero visit limit is unchanged');
select is(:'limits_null_limit'::integer,0,'NULL visit limit is unchanged');
select is(:'limits_one'::integer,1,'one visit remains one visit');
select ok(:'limits_max_visits'::integer<=25,'large visit input remains clamped to twenty-five');
select is(:'limits_signature'::text,'p_limit integer DEFAULT 5'::text,'public signature/default keep their visit-count meaning');

savepoint invalid_markdown_proof;
update util.dataset_derivative_rebuild_requests r
set status=case when t.ordinal<=6 then 'markdown_pending' else 'dispatching' end,
    phase=case when t.ordinal<=6 then 'markdown_dispatched' else 'failure_draining' end,
    failure_release_not_before=clock_timestamp()+interval '1 hour',
    markdown_request_id=-7040000-t.ordinal,
    markdown_dispatched_at=clock_timestamp()-interval '1 second',
    markdown_deadline_at=clock_timestamp()+interval '1 hour'
from pg_temp.scheduler703_targets t where r.id=t.request_id;
insert into net._http_response(id,status_code,content_type,headers,content,timed_out,error_msg,created)
select r.markdown_request_id,200,'application/json','{}'::jsonb,
  jsonb_build_object('success',true,'results',jsonb_build_array(jsonb_build_object(
    'id',r.target_id,'version',r.target_version,'table',r.target_table,'status','success')))::text,
  false,null,clock_timestamp()
from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id where t.ordinal<=6;
select util.process_dataset_derivative_rebuilds(25) as visits \gset invalid_md_call_
select count(*) filter(where r.last_error->>'code'='DERIVATIVE_MARKDOWN_PROPOSAL_MISMATCH') as rejected,
  count(*) filter(where r.embedding_queue_msg_id is not null) as enqueued
from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id
\gset invalid_md_
rollback to invalid_markdown_proof;
select is(:'invalid_md_rejected'::integer,5,'present HTTP response without a proposal is ready for rejection, not invisible');
select is(:'invalid_md_enqueued'::integer,0,'invalid Markdown proof cannot create embedding work');

savepoint absent_embedding_proof;
update util.dataset_derivative_rebuild_requests r
set status=case when t.ordinal<=6 then 'embedding_pending' else 'dispatching' end,
    phase=case when t.ordinal<=6 then 'embedding_queued' else 'failure_draining' end,
    failure_release_not_before=clock_timestamp()+interval '1 hour',
    embedding_queue_msg_id=-7050000-t.ordinal,
    embedding_queued_at=clock_timestamp()-interval '1 second',
    embedding_deadline_at=clock_timestamp()+interval '1 hour'
from pg_temp.scheduler703_targets t where r.id=t.request_id;
select util.process_dataset_derivative_rebuilds(25) as visits \gset invalid_embedding_call_
select count(*) filter(where r.last_error->>'code'='DERIVATIVE_EMBEDDING_PROPOSAL_MISMATCH') as rejected,
  count(*) filter(where r.status='completed') as completed
from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id
\gset invalid_embedding_
rollback to absent_embedding_proof;
select is(:'invalid_embedding_rejected'::integer,6,'queue ACK without a proposal is selected for the existing failure drain');
select is(:'invalid_embedding_completed'::integer,0,'queue absence alone never fabricates terminal completion');

savepoint paused_policy;
insert into util.embedding_queue_policy(scope_schema,scope_table,scope_edge_function,scope_embedding_column,mode)
values('public','processes','embedding_ft','embedding_ft','paused')
on conflict(scope_schema,scope_table,scope_edge_function,scope_embedding_column)
do update set mode='paused',updated_at=clock_timestamp();
update util.dataset_derivative_rebuild_requests r
set status=case when t.ordinal<=6 then 'markdown_pending' else 'dispatching' end,
    phase=case when t.ordinal<=6 then 'markdown_dispatched' else 'failure_draining' end,
    failure_release_not_before=clock_timestamp()+interval '1 hour',
    markdown_request_id=-7060000-t.ordinal,
    markdown_dispatched_at=clock_timestamp()-interval '1 second',
    markdown_deadline_at=clock_timestamp()+interval '1 hour'
from pg_temp.scheduler703_targets t where r.id=t.request_id;
select pg_temp.scheduler703_ideal_worker() as simulated \gset paused_worker_
select util.process_dataset_derivative_rebuilds(25) as visits \gset paused_first_
select count(*) filter(where r.phase='embedding_policy_paused') as pending,
  (select count(*) from pgmq.q_embedding_jobs) as queued
from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id
\gset paused_initial_
select util.process_dataset_derivative_rebuilds(25) as visits \gset paused_second_
select util.process_dataset_derivative_rebuilds(25) as visits \gset paused_audit_
select count(*) filter(where r.phase='embedding_policy_paused') as pending,
  count(*) filter(where r.status in ('completed','failed')) as terminal
from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id
\gset paused_waiting_
update util.embedding_queue_policy set mode='normal',updated_at=clock_timestamp()
where scope_schema='public' and scope_table='processes' and scope_edge_function='embedding_ft' and scope_embedding_column='embedding_ft';
select util.enqueue_pending_embeddings(5,'public','processes','embedding_ft','embedding_ft') as released \gset resumed_first_
select util.process_dataset_derivative_rebuilds(25) as visits \gset resumed_bridge_
select pg_temp.scheduler703_ideal_worker() as simulated \gset resumed_worker_
select util.process_dataset_derivative_rebuilds(25) as visits \gset resumed_commit_
select util.enqueue_pending_embeddings(1,'public','processes','embedding_ft','embedding_ft') as released \gset resumed_last_
select util.process_dataset_derivative_rebuilds(25) as visits \gset resumed_bridge_last_
select pg_temp.scheduler703_ideal_worker() as simulated \gset resumed_worker_last_
select util.process_dataset_derivative_rebuilds(25) as visits \gset resumed_commit_last_
select count(*) filter(where r.status='completed') as completed,
  count(*) filter(where r.status='failed') as failed
from util.dataset_derivative_rebuild_requests r join pg_temp.scheduler703_targets t on r.id=t.request_id
\gset resumed_result_
rollback to paused_policy;
select is(:'paused_initial_pending'::integer,5,'pending admissions share the same five-external-advance cap');
select is(:'paused_initial_queued'::integer,0,'paused policy does not leak embedding jobs');
select is(:'paused_waiting_pending'::integer,6,'paused requests remain waiting without repeated admission');
select is(:'paused_waiting_terminal'::integer,0,'auditing a paused request never releases its fence');
select is(:'resumed_result_completed'::integer,6,'normal release uses the real pending bridge, staged proposals and paired commit');
select is(:'resumed_result_failed'::integer,0,'legitimate paused-to-normal resumption preserves valid causal evidence');

savepoint public_projection;
select set_config('request.jwt.claim.sub',(select actor_user_id::text from pg_temp.scheduler703_targets where ordinal=1),true);
select api.cmd_dataset_derivative_rebuild_read(request_id) as payload
from pg_temp.scheduler703_targets where ordinal=1 \gset public_before_
update util.dataset_derivative_rebuild_requests r set scheduler_selected_at=clock_timestamp()
from pg_temp.scheduler703_targets t where r.id=t.request_id and t.ordinal=1;
select api.cmd_dataset_derivative_rebuild_read(request_id) as payload
from pg_temp.scheduler703_targets where ordinal=1 \gset public_after_
rollback to public_projection;
select ok((:'public_before_payload'::jsonb->>'ok')::boolean,'public projection comparison uses an actual authorized owner result');
select is(:'public_after_payload'::jsonb,:'public_before_payload'::jsonb,
  'scheduler metadata changes neither public read payload nor its bound plan/request hashes');
select ok(not has_function_privilege('authenticated',
  'private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamp with time zone)','execute'),
  'new selector stays owner-only');
select ok(not (select prosecdef from pg_proc where oid=
  'private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamp with time zone)'::regprocedure),
  'owner-only selector needs no new SECURITY DEFINER authority');

select * from finish();
rollback;
