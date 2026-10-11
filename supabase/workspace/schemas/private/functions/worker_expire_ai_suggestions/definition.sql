CREATE OR REPLACE FUNCTION "private"."worker_expire_ai_suggestions"("p_limit" integer DEFAULT 50) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 50));
  v_count integer;
  v_cutoff timestamptz := clock_timestamp();
begin
  with candidates as (
    select j.id
    from private.worker_jobs j
    where j.worker_runtime = 'calculator' and j.worker_queue = 'ai'
      and j.job_kind = 'ai.tidas_suggestion'
      and j.timeout_at <= v_cutoff
      and (j.status in ('queued', 'stale')
        or (j.status = 'running' and j.lease_expires_at < v_cutoff))
    order by j.timeout_at, j.id
    limit v_limit
    for update skip locked
  ), transition_clock as materialized (
    -- Candidate rows are already locked; timestamp the actual owned transition.
    select id, clock_timestamp() as expired_at from candidates
  ), expired as (
    update private.worker_jobs j
    set status = 'cancelled', cancelled_at = c.expired_at, cancelled_by = null,
        leased_by = null, lease_token = null, lease_expires_at = null,
        error_code = 'worker_job_timeout',
        error_message = 'AI suggestion deadline expired before admission or lease recovery',
        updated_at = c.expired_at, finished_at = c.expired_at
    from transition_clock c
    where j.id = c.id
      -- Recheck ownership eligibility at the locked row, never cancel a live lease.
      and j.timeout_at <= c.expired_at
      and (j.status in ('queued', 'stale')
        or (j.status = 'running' and j.lease_expires_at < c.expired_at))
    returning j.id, j.timeout_at, j.finished_at
  ), events as (
    insert into private.worker_job_events(job_id, event_type, status, message, details, created_at)
    select id, 'cancelled', 'cancelled',
      'AI suggestion deadline expired before admission or lease recovery',
      jsonb_build_object('errorCode', 'worker_job_timeout', 'timeoutAt', timeout_at),
      finished_at
    from expired
    returning id
  )
  select count(*)::integer into v_count from events;
  return v_count;
end;
$$;

ALTER FUNCTION "private"."worker_expire_ai_suggestions"("p_limit" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."worker_expire_ai_suggestions"("p_limit" integer) FROM PUBLIC;
