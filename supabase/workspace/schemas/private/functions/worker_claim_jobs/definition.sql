CREATE OR REPLACE FUNCTION "private"."worker_claim_jobs"("p_worker_queue" "text", "p_worker_id" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 10, "p_lease_seconds" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'api', 'public', 'util', 'extensions', 'pg_temp'
    AS $$
declare
  v_worker_queue text := lower(trim(coalesce(p_worker_queue, '')));
  v_worker_id text := nullif(trim(p_worker_id), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 10), 50));
  v_lease_seconds integer := greatest(1, least(coalesce(p_lease_seconds, 300), 86400));
  v_jobs jsonb := '[]'::jsonb;
begin
  if not coalesce(util.is_service_request(), false) then
    return jsonb_build_object(
      'ok', false,
      'code', 'SERVICE_ROLE_REQUIRED',
      'status', 403,
      'message', 'Service role is required to claim worker jobs'
    );
  end if;

  if v_worker_queue not in (
    'solver', 'review_submit', 'review_submit_gate', 'review_quality',
    'package', 'maintenance', 'ai'
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'INVALID_WORKER_QUEUE',
      'status', 400,
      'message', 'Unsupported worker queue'
    );
  end if;

  if v_worker_queue = 'ai' then
    perform private.worker_expire_ai_suggestions(v_limit);
  end if;

  with expired_candidates as (
    select id
    from private.worker_jobs
    where worker_runtime = 'calculator'
      and worker_queue = v_worker_queue
      and status = 'running'
      and lease_expires_at < case when job_kind = 'ai.tidas_suggestion'
        then clock_timestamp() else now() end
      and attempt_count >= max_attempts
      and (job_kind <> 'ai.tidas_suggestion' or timeout_at is null or timeout_at > clock_timestamp())
    order by lease_expires_at asc, created_at asc
    limit v_limit
    for update skip locked
  ),
  failure_clock as materialized (
    select id, clock_timestamp() as failed_at from expired_candidates
  ),
  expired as (
    update private.worker_jobs as j
      set status = 'failed',
          error_code = coalesce(j.error_code, 'lease_expired_max_attempts'),
          error_message = coalesce(
            j.error_message,
            'Worker job lease expired after the maximum attempt count'
          ),
          error_details = coalesce(j.error_details, '{}'::jsonb)
            || jsonb_build_object(
              'leasedBy', j.leased_by,
              'leaseExpiresAt', j.lease_expires_at,
              'attemptCount', j.attempt_count,
              'maxAttempts', j.max_attempts
            ),
          leased_by = null,
          lease_token = null,
          lease_expires_at = null,
          heartbeat_at = coalesce(j.heartbeat_at, case when j.job_kind = 'ai.tidas_suggestion'
            then c.failed_at else now() end),
          updated_at = case when j.job_kind = 'ai.tidas_suggestion'
            then c.failed_at else now() end,
          finished_at = case when j.job_kind = 'ai.tidas_suggestion'
            then c.failed_at else now() end
    from failure_clock c
    where j.id = c.id
    returning j.*
  ),
  expired_events as (
    insert into private.worker_job_events (
      job_id, event_type, status, worker_id, message, details, created_at
    )
    select
      expired.id,
      'failed',
      expired.status,
      expired.leased_by,
      'Worker job lease expired after the maximum attempt count',
      jsonb_build_object(
        'errorCode', expired.error_code,
        'attemptCount', expired.attempt_count,
        'maxAttempts', expired.max_attempts
      ),
      case when expired.job_kind = 'ai.tidas_suggestion'
        then expired.finished_at else now() end
    from expired
    returning id
  ),
  candidate as (
    select id
    from private.worker_jobs
    where worker_runtime = 'calculator'
      and worker_queue = v_worker_queue
      and run_after <= now()
      and attempt_count < max_attempts
      and (job_kind <> 'ai.tidas_suggestion' or timeout_at is null or timeout_at > clock_timestamp())
      and (
        status in ('queued', 'stale')
        or (status = 'running' and lease_expires_at < case when job_kind = 'ai.tidas_suggestion'
        then clock_timestamp() else now() end)
      )
    order by priority desc, run_after asc, created_at asc
    limit v_limit
    for update skip locked
  ),
  admission_clock as materialized (
    -- FOR UPDATE has completed before any AI admission timestamp is captured.
    select id, clock_timestamp() as admitted_at from candidate
  ),
  updated as (
    update private.worker_jobs as j
      set status = 'running',
          attempt_count = j.attempt_count + 1,
          leased_by = v_worker_id,
          lease_token = gen_random_uuid(),
          lease_expires_at = (case when j.job_kind = 'ai.tidas_suggestion'
            then c.admitted_at else now() end) + make_interval(secs => v_lease_seconds),
          heartbeat_at = case when j.job_kind = 'ai.tidas_suggestion'
            then c.admitted_at else now() end,
          started_at = coalesce(j.started_at, case when j.job_kind = 'ai.tidas_suggestion'
            then c.admitted_at else now() end),
          updated_at = case when j.job_kind = 'ai.tidas_suggestion'
            then c.admitted_at else now() end,
          diagnostics = case
            when j.attempt_count > 0 then '{}'::jsonb
            else j.diagnostics
          end,
          error_code = null,
          error_message = null,
          error_details = null
    from admission_clock c
    where j.id = c.id
      and (j.job_kind <> 'ai.tidas_suggestion' or j.timeout_at is null
        or j.timeout_at > c.admitted_at)
    returning j.*
  ),
  claim_events as (
    insert into private.worker_job_events (
      job_id, event_type, status, phase, progress, worker_id, lease_token, details, created_at
    )
    select
      updated.id,
      'claimed',
      updated.status,
      updated.phase,
      updated.progress,
      updated.leased_by,
      updated.lease_token,
      jsonb_build_object(
        'attemptCount', updated.attempt_count,
        'leaseExpiresAt', updated.lease_expires_at
      ),
      case when updated.job_kind = 'ai.tidas_suggestion'
        then updated.updated_at else now() end
    from updated
    returning id
  )
  select coalesce(
    jsonb_agg(private.worker_job_payload(updated, true)),
    '[]'::jsonb
  ) into v_jobs
  from updated;

  return jsonb_build_object('ok', true, 'data', v_jobs);
end;
$$;

ALTER FUNCTION "private"."worker_claim_jobs"("p_worker_queue" "text", "p_worker_id" "text", "p_limit" integer, "p_lease_seconds" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."worker_claim_jobs"("p_worker_queue" "text", "p_worker_id" "text", "p_limit" integer, "p_lease_seconds" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."worker_claim_jobs"("p_worker_queue" "text", "p_worker_id" "text", "p_limit" integer, "p_lease_seconds" integer) TO "service_role";

GRANT ALL ON FUNCTION "private"."worker_claim_jobs"("p_worker_queue" "text", "p_worker_id" "text", "p_limit" integer, "p_lease_seconds" integer) TO "api_internal_executor";
