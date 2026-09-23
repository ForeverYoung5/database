CREATE OR REPLACE FUNCTION "private"."pick_dataset_derivative_rebuild_request"("p_seen" "uuid"[], "p_lane" "text", "p_allow_external" boolean, "p_now" timestamp with time zone) RETURNS TABLE("request_id" "uuid", "is_ready" boolean, "dispatch_capable" boolean)
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  with active as materialized (
    select r.id, r.actor_user_id, coalesce(r.batch_id, r.id) as scheduling_batch,
      r.status, r.phase, r.updated_at, r.admitted_at, r.drain_not_before,
      r.failure_release_not_before, r.markdown_request_id, r.markdown_deadline_at,
      r.embedding_queue_msg_id, r.embedding_pending_job_id, r.embedding_deadline_at
    from util.dataset_derivative_rebuild_requests r
    where r.status not in ('completed', 'stale', 'failed')
      and not (r.id = any(coalesce(p_seen, array[]::uuid[])))
  ), actors as materialized (
    select history.actor_user_id,
      coalesce(max(history.scheduler_selected_at), min(history.admitted_at)) as last_served
    from util.dataset_derivative_rebuild_requests history
    where history.actor_user_id in (select active.actor_user_id from active)
    group by history.actor_user_id
  ), batches as materialized (
    select history.actor_user_id, coalesce(history.batch_id, history.id) as scheduling_batch,
      coalesce(max(history.scheduler_selected_at), min(history.admitted_at)) as last_served
    from util.dataset_derivative_rebuild_requests history
    where (history.actor_user_id, coalesce(history.batch_id, history.id)) in
      (select active.actor_user_id, active.scheduling_batch from active)
    group by history.actor_user_id, coalesce(history.batch_id, history.id)
  ), readiness as materialized (
    select active.*,
      coalesce(case
        when active.status = 'queued' then true
        when active.status = 'dispatching' and active.phase = 'quarantining'
          then active.drain_not_before <= p_now
        when active.status = 'dispatching' and active.phase = 'failure_draining'
          then active.failure_release_not_before <= p_now
        when active.status = 'markdown_pending' then
          exists (select 1 from net._http_response response where response.id = active.markdown_request_id)
          or active.markdown_deadline_at <= p_now
        when active.status = 'embedding_pending' then
          case
            when active.embedding_queue_msg_id is not null then
              not exists (select 1 from pgmq.q_embedding_jobs job where job.msg_id = active.embedding_queue_msg_id)
              or active.embedding_deadline_at <= p_now
            when active.embedding_pending_job_id is null then true
            when pending.status = 'pending' then active.embedding_deadline_at <= p_now
            else true -- bridge, lost or malformed proof: let the unchanged body decide
          end
        else false
      end, false) as ready
    from active
    left join util.pending_embedding_jobs pending on pending.id = active.embedding_pending_job_id
  ), classified as (
    select readiness.*,
      ready and (status = 'markdown_pending'
        or (status = 'dispatching' and phase = 'quarantining')) as external
    from readiness
  )
  select locked.id, classified.ready, classified.external
  from classified
  join util.dataset_derivative_rebuild_requests locked on locked.id = classified.id
  join actors on actors.actor_user_id = classified.actor_user_id
  join batches on batches.actor_user_id = classified.actor_user_id
    and batches.scheduling_batch = classified.scheduling_batch
  where locked.status not in ('completed', 'stale', 'failed')
    and (p_lane in ('audit', 'any') or (p_lane = 'ready' and classified.ready))
    and (p_lane = 'audit' or not classified.external or p_allow_external)
  order by
    case when p_lane in ('audit', 'any') then classified.updated_at else actors.last_served end,
    case when p_lane in ('audit', 'any') then classified.admitted_at else batches.last_served end,
    classified.updated_at, classified.admitted_at, classified.id
  -- Lock/skip first, then count the actual row. Pre-limiting a ranked candidate
  -- list would strand runnable peers behind another session's locked quota.
  for update of locked skip locked
  limit 1
$$;

ALTER FUNCTION "private"."pick_dataset_derivative_rebuild_request"("p_seen" "uuid"[], "p_lane" "text", "p_allow_external" boolean, "p_now" timestamp with time zone) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."pick_dataset_derivative_rebuild_request"("p_seen" "uuid"[], "p_lane" "text", "p_allow_external" boolean, "p_now" timestamp with time zone) FROM PUBLIC;
