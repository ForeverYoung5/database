-- Aggregate-only observation after #703. No coordinator/selector invocation,
-- request IDs, actor IDs, payloads, credentials or state mutation.
with backlog as (
  select status, phase, count(*) as requests, count(distinct actor_user_id) as actors,
    count(distinct batch_id) as batches, min(admitted_at) as oldest_admitted,
    max(scheduler_selected_at) as latest_progress_selection
  from util.dataset_derivative_rebuild_requests
  group by status, phase
), cadence as (
  select jobid, active, schedule, command
  from cron.job where jobname='process-dataset-derivative-rebuilds'
), recent as (
  select count(*) as runs, count(*) filter(where status<>'succeeded') as failed,
    avg(extract(epoch from(end_time-start_time))*1000) as mean_ms,
    percentile_cont(0.95) within group(order by extract(epoch from(end_time-start_time))*1000) as p95_ms,
    max(extract(epoch from(end_time-start_time))*1000) as max_ms
  from cron.job_run_details
  where jobid in (select jobid from cadence) and start_time>=clock_timestamp()-interval '1 hour'
), policies as (
  select name as target_table, policy.*
  from (values('flows'),('processes')) target(name)
  cross join lateral util.embedding_queue_policy_for('public',name,'embedding_ft','embedding_ft') policy
)
select jsonb_build_object(
  'observed_at',clock_timestamp(),
  'coordinator_arguments',pg_get_function_arguments('util.process_dataset_derivative_rebuilds(integer)'::regprocedure),
  'coordinator_md5',md5(pg_get_functiondef('util.process_dataset_derivative_rebuilds(integer)'::regprocedure)),
  'selector_security_definer',(select prosecdef from pg_proc where oid=
    'private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamptz)'::regprocedure),
  'cron',(select coalesce(jsonb_agg(to_jsonb(cadence)),'[]'::jsonb) from cadence),
  'last_hour_runs',(select to_jsonb(recent) from recent),
  'backlog',(select coalesce(jsonb_agg(to_jsonb(backlog) order by status,phase),'[]'::jsonb) from backlog),
  'embedding_policy',(select jsonb_agg(to_jsonb(policies) order by target_table) from policies),
  'embedding_queue_count',(select count(*) from pgmq.q_embedding_jobs),
  'embedding_pending_count',(select count(*) from util.pending_embedding_jobs where status='pending')
) as scheduler703_observation;
