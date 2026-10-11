CREATE OR REPLACE FUNCTION "private"."worker_expire_ai_suggestions"("p_limit" integer DEFAULT 50) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 50));
  v_count integer;
begin
  with candidates as (
    select j.id
    from private.worker_jobs j
    where j.worker_runtime = 'calculator' and j.worker_queue = 'ai'
      and j.job_kind = 'ai.tidas_suggestion'
      and j.timeout_at <= now()
      and (j.status in ('queued', 'stale')
        or (j.status = 'running' and j.lease_expires_at < now()))
    order by j.timeout_at, j.id
    limit v_limit
    for update skip locked
  ), expired as (
    update private.worker_jobs j
    set status = 'cancelled', cancelled_at = now(), cancelled_by = null,
        leased_by = null, lease_token = null, lease_expires_at = null,
        error_code = 'worker_job_timeout',
        error_message = 'AI suggestion deadline expired before admission or lease recovery',
        updated_at = now(), finished_at = now()
    from candidates c
    where j.id = c.id
      -- Recheck ownership eligibility at the locked row, never cancel a live lease.
      and j.timeout_at <= now()
      and (j.status in ('queued', 'stale')
        or (j.status = 'running' and j.lease_expires_at < now()))
    returning j.id, j.timeout_at
  ), events as (
    insert into private.worker_job_events(job_id, event_type, status, message, details)
    select id, 'cancelled', 'cancelled',
      'AI suggestion deadline expired before admission or lease recovery',
      jsonb_build_object('errorCode', 'worker_job_timeout', 'timeoutAt', timeout_at)
    from expired
    returning id
  )
  select count(*)::integer into v_count from events;
  return v_count;
end;
$$;

ALTER FUNCTION "private"."worker_expire_ai_suggestions"("p_limit" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."worker_expire_ai_suggestions"("p_limit" integer) FROM PUBLIC;
