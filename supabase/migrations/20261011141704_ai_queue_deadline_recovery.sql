-- AI timeout_at bounds admission and lease recovery, not an owned active lease.
-- Retain canonical rows and request identity; cancellation permits a fresh request.
create index worker_jobs_ai_deadline_idx
on private.worker_jobs (timeout_at, id)
where worker_runtime = 'calculator' and worker_queue = 'ai'
  and job_kind = 'ai.tidas_suggestion' and timeout_at is not null
  and status in ('queued', 'stale', 'running');

create or replace function private.worker_expire_ai_suggestions(p_limit integer default 50)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
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

revoke all on function private.worker_expire_ai_suggestions(integer)
  from public, anon, authenticated, service_role;
-- Only owner-owned SQL and the existing SECURITY DEFINER claim boundary invoke it.

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
      and lease_expires_at < now()
      and attempt_count >= max_attempts
      and (job_kind <> 'ai.tidas_suggestion' or timeout_at is null or timeout_at > now())
    order by lease_expires_at asc, created_at asc
    limit v_limit
    for update skip locked
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
          heartbeat_at = coalesce(j.heartbeat_at, now()),
          updated_at = now(),
          finished_at = now()
    from expired_candidates
    where j.id = expired_candidates.id
    returning j.*
  ),
  expired_events as (
    insert into private.worker_job_events (
      job_id, event_type, status, worker_id, message, details
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
      )
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
      and (job_kind <> 'ai.tidas_suggestion' or timeout_at is null or timeout_at > now())
      and (
        status in ('queued', 'stale')
        or (status = 'running' and lease_expires_at < now())
      )
    order by priority desc, run_after asc, created_at asc
    limit v_limit
    for update skip locked
  ),
  updated as (
    update private.worker_jobs as j
      set status = 'running',
          attempt_count = j.attempt_count + 1,
          leased_by = v_worker_id,
          lease_token = gen_random_uuid(),
          lease_expires_at = now() + make_interval(secs => v_lease_seconds),
          heartbeat_at = now(),
          started_at = coalesce(j.started_at, now()),
          updated_at = now(),
          diagnostics = case
            when j.attempt_count > 0 then '{}'::jsonb
            else j.diagnostics
          end,
          error_code = null,
          error_message = null,
          error_details = null
    from candidate
    where j.id = candidate.id
    returning j.*
  ),
  claim_events as (
    insert into private.worker_job_events (
      job_id, event_type, status, phase, progress, worker_id, lease_token, details
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
      )
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

CREATE OR REPLACE FUNCTION "private"."worker_retry_job"("p_job_id" "uuid", "p_run_after" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_max_attempts" integer DEFAULT NULL::integer, "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'api', 'public', 'util', 'extensions', 'pg_temp'
    AS $$
declare
  v_job private.worker_jobs%rowtype;
begin
  if not coalesce(util.is_service_request(), false) then
    return jsonb_build_object(
      'ok', false,
      'code', 'SERVICE_ROLE_REQUIRED',
      'status', 403,
      'message', 'Service role is required to retry worker jobs'
    );
  end if;

  select *
    into v_job
  from private.worker_jobs
  where id = p_job_id
  for update;

  if v_job.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'WORKER_JOB_NOT_FOUND',
      'status', 404,
      'message', 'Worker job not found'
    );
  end if;

  if v_job.status not in ('failed', 'blocked', 'stale', 'waiting', 'cancelled') then
    return jsonb_build_object(
      'ok', false,
      'code', 'WORKER_JOB_NOT_RETRYABLE',
      'status', 409,
      'message', 'Worker job is not in a retryable status'
    );
  end if;

  if v_job.job_kind = 'ai.tidas_suggestion'
    and v_job.timeout_at is not null and v_job.timeout_at <= now() then
    return jsonb_build_object(
      'ok', false, 'code', 'WORKER_JOB_DEADLINE_EXPIRED', 'status', 409,
      'message', 'Expired AI suggestions require a new request'
    );
  end if;

  update private.worker_jobs
    set status = 'queued',
        run_after = coalesce(p_run_after, now()),
        attempt_count = 0,
        max_attempts = greatest(1, coalesce(p_max_attempts, max_attempts)),
        leased_by = null,
        lease_token = null,
        lease_expires_at = null,
        diagnostics = '{}'::jsonb,
        error_code = null,
        error_message = null,
        error_details = null,
        blocker_codes = '{}'::text[],
        resolution_scope = null,
        retryable = null,
        cancelled_at = null,
        cancelled_by = null,
        finished_at = null,
        updated_at = now()
  where id = v_job.id
  returning *
    into v_job;

  insert into private.worker_job_events (
    job_id,
    event_type,
    status,
    message,
    details
  ) values (
    v_job.id,
    'retried',
    v_job.status,
    p_reason,
    jsonb_build_object('runAfter', v_job.run_after)
  );

  return jsonb_build_object(
    'ok', true,
    'data', private.worker_job_payload(v_job, true)
  );
end;
$$;

ALTER FUNCTION "private"."worker_retry_job"("p_job_id" "uuid", "p_run_after" timestamp with time zone, "p_max_attempts" integer, "p_reason" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."worker_retry_job"("p_job_id" "uuid", "p_run_after" timestamp with time zone, "p_max_attempts" integer, "p_reason" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."worker_retry_job"("p_job_id" "uuid", "p_run_after" timestamp with time zone, "p_max_attempts" integer, "p_reason" "text") TO "service_role";

GRANT ALL ON FUNCTION "private"."worker_retry_job"("p_job_id" "uuid", "p_run_after" timestamp with time zone, "p_max_attempts" integer, "p_reason" "text") TO "api_internal_executor";

-- At most 50 AI lifecycle transitions per minute, independent of consumer presence.
-- Named pg_cron jobs run as their scheduling owner; no service secret or HTTP call.
select cron.schedule(
  'worker-ai-deadline-expiry', '* * * * *',
  'set statement_timeout = ''8s''; select private.worker_expire_ai_suggestions(50);'
);
