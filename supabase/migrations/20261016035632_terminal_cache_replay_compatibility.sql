-- Forward-only Preview upgrade: synchronize terminal cache state and preserve blocked replay mode.
-- Database #846 / Worker #320: terminal cache observations never enqueue successors.
create or replace function api.svc_lca_cached_job_enqueue(
  p_scope text,
  p_snapshot_id uuid,
  p_request_key text,
  p_request_payload jsonb,
  p_job_kind text,
  p_job_id uuid,
  p_payload jsonb,
  p_payload_schema_version text,
  p_requested_by uuid,
  p_idempotency_key text,
  p_queue_key text default null
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_scope text := nullif(btrim(p_scope), '');
  v_request_key text := nullif(btrim(p_request_key), '');
  v_cache private.lca_result_cache%rowtype;
  v_worker private.worker_jobs%rowtype;
  v_enqueue jsonb;
  v_worker_id uuid;
  v_resolved_job_id uuid;
  v_resolved_snapshot_id uuid;
  v_worker_status text;
begin
  if p_job_kind not in ('lca.solve_one', 'lca.solve_batch', 'lca.solve_all_unit', 'lca.contribution_path')
     or v_scope is null or p_snapshot_id is null or v_request_key is null
     or p_job_id is null or p_requested_by is null then
    return jsonb_build_object('ok', false, 'code', 'INVALID_LCA_JOB_REQUEST', 'status', 400);
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'lca.cache:' || v_scope || ':' || p_snapshot_id::text || ':' || v_request_key, 0
  ));

  select * into v_cache from private.lca_result_cache
  where scope = v_scope and snapshot_id = p_snapshot_id and request_key = v_request_key
  for update;

  if v_cache.id is not null then
    update private.lca_result_cache set
      hit_count = hit_count + 1, last_accessed_at = now(), updated_at = now()
    where id = v_cache.id returning * into v_cache;
    if v_cache.status = 'ready' and v_cache.result_id is not null then
      return jsonb_build_object(
        'ok', true, 'mode', 'cache_hit', 'cache_id', v_cache.id,
        'job_id', v_cache.job_id, 'worker_job_id', v_cache.worker_job_id,
        'result_id', v_cache.result_id
      );
    end if;
    if v_cache.worker_job_id is not null then
      select * into v_worker from private.worker_jobs where id = v_cache.worker_job_id;
      if v_worker.status in ('queued', 'running', 'waiting', 'stale') then
        return jsonb_build_object(
          'ok', true, 'mode', 'in_progress', 'cache_id', v_cache.id,
          'job_id', v_cache.job_id, 'worker_job_id', v_cache.worker_job_id
        );
      end if;
      if v_worker.status in ('failed', 'cancelled', 'blocked', 'completed') then
        update private.lca_result_cache set
          status = 'failed',
          error_code = coalesce(error_code, v_worker.error_code),
          error_message = coalesce(error_message, v_worker.error_message),
          updated_at = now()
        where id = v_cache.id returning * into v_cache;
        return jsonb_build_object(
          'ok', false,
          'code', case when v_worker.status = 'failed' and v_worker.retryable is false
            then 'WORKER_REQUEST_NON_RETRYABLE_FAILURE' else 'LCA_REQUEST_TERMINAL' end,
          'status', 409,
          'mode', case when v_worker.status = 'blocked' then 'blocked' else 'failed_cache_hit' end,
          'message', 'The cached worker request is terminal; polling cannot restart it',
          'next_action', case when v_worker.status = 'completed' then 'inspect_missing_result' else 'explicit_worker_job_retry' end,
          'terminal', true,
          'reused', true,
          'reuseReason', 'terminal_request',
          'cache_id', v_cache.id,
          'job_id', v_cache.job_id,
          'worker_job_id', v_worker.id,
          'error_code', coalesce(v_cache.error_code, v_worker.error_code),
          'error_message', coalesce(v_cache.error_message, v_worker.error_message),
          'retryable', v_worker.retryable,
          'details', jsonb_build_object(
            'workerJob', private.worker_job_payload(v_worker, false)
          )
        );
      end if;
    end if;
    if v_cache.status = 'failed' then
      return jsonb_build_object(
        'ok', false, 'code', 'LCA_REQUEST_TERMINAL', 'status', 409,
        'mode', 'failed_cache_hit', 'terminal', true, 'reused', true,
        'message', 'The failed cached request has no active worker; polling cannot restart it',
        'next_action', 'inspect_missing_worker', 'cache_id', v_cache.id,
        'job_id', v_cache.job_id, 'worker_job_id', v_cache.worker_job_id,
        'error_code', v_cache.error_code, 'error_message', v_cache.error_message
      );
    end if;
  end if;

  v_enqueue := private.worker_enqueue_job(
    p_job_kind => p_job_kind,
    p_payload_json => coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('job_id', p_job_id),
    p_payload_schema_version => p_payload_schema_version,
    p_subject_type => 'lca_job',
    p_subject_id => p_job_id,
    p_subject_version => p_snapshot_id::text,
    p_requested_by => p_requested_by,
    p_requester_type => 'user',
    p_idempotency_key => p_idempotency_key,
    p_request_hash => v_request_key,
    p_concurrency_key => v_scope || ':' || p_snapshot_id::text || ':' || v_request_key,
    p_queue_key => p_queue_key,
    p_visibility => 'user'
  );
  if coalesce((v_enqueue ->> 'ok')::boolean, false) is false then return v_enqueue; end if;
  v_worker_id := (v_enqueue #>> '{data,id}')::uuid;
  v_resolved_job_id := coalesce(
    nullif(v_enqueue #>> '{data,payload,job_id}', '')::uuid,
    nullif(v_enqueue #>> '{data,subjectId}', '')::uuid,
    p_job_id
  );
  v_resolved_snapshot_id := coalesce(
    nullif(v_enqueue #>> '{data,subjectVersion}', '')::uuid,
    p_snapshot_id
  );
  v_worker_status := v_enqueue #>> '{data,status}';
  if v_resolved_snapshot_id <> p_snapshot_id then
    return jsonb_build_object('ok', false, 'code', 'LCA_JOB_IDEMPOTENCY_CONFLICT', 'status', 409);
  end if;

  insert into private.lca_result_cache as cache (
    scope, snapshot_id, request_key, request_payload, status,
    job_id, worker_job_id, hit_count, last_accessed_at, created_at, updated_at
  ) values (
    v_scope, p_snapshot_id, v_request_key, coalesce(p_request_payload, '{}'::jsonb),
    case when v_worker_status = 'blocked' then 'failed' else 'pending' end,
    v_resolved_job_id, v_worker_id, 1, now(), now(), now()
  ) on conflict (scope, snapshot_id, request_key) do update set
    request_payload = excluded.request_payload,
    status = excluded.status,
    job_id = excluded.job_id,
    worker_job_id = excluded.worker_job_id,
    result_id = null,
    error_code = null,
    error_message = null,
    hit_count = cache.hit_count + 1,
    last_accessed_at = now(),
    updated_at = now()
  returning * into v_cache;

  return jsonb_build_object(
    'ok', true,
    'mode', case
      when v_worker_status = 'blocked' then 'blocked'
      when coalesce((v_enqueue ->> 'reused')::boolean, false) then 'in_progress'
      else 'queued'
    end,
    'cache_id', v_cache.id,
    'job_id', v_cache.job_id, 'worker_job_id', v_cache.worker_job_id
  );
end;
$$;

comment on function api.svc_lca_cached_job_enqueue(text,uuid,text,jsonb,text,uuid,jsonb,text,uuid,text,text) is 'Service-only cached solve admission. Reuses active and terminal Worker identities; terminal retries require the explicit Worker retry command.';
