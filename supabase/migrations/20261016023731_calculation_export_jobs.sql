-- Database #846 / Worker #320. Optional exports have their own canonical Worker lifecycle.
insert into private.worker_job_kinds (
  job_kind, worker_runtime, worker_queue, default_visibility, default_priority,
  default_max_attempts, default_lease_seconds, payload_schema_version,
  result_schema_version, user_visible, description
) values (
  'lca.calculation_export', 'calculator', 'solver', 'user', -10, 1, 3600,
  'lca.calculation_export.request.v1', 'lca.calculation_export.result.v1', false,
  'Explicit optional export from a completed immutable Calculation Bundle; never recalculates.'
) on conflict (job_kind) do nothing;

create index worker_jobs_calculation_export_identity_idx
  on private.worker_jobs(concurrency_key, created_at desc, id)
  where job_kind = 'lca.calculation_export';

create or replace function api.svc_lca_calculation_export(
  p_requested_by uuid, p_package_id uuid, p_format text default 'parquet',
  p_enqueue boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_package private.lcia_result_packages%rowtype;
  v_bundle jsonb;
  v_job private.worker_jobs%rowtype;
  v_hash text;
  v_key text;
  v_enqueued jsonb;
begin
  if not coalesce(util.is_service_request(), false) then
    return api.lcia_result_error('SERVICE_ROLE_REQUIRED', 403, 'SERVICE ROLE REQUIRED');
  end if;
  if p_requested_by is null or not exists (
    select 1 from private.roles where user_id = p_requested_by
      and team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and role = 'data_product_manager'
  ) then
    return api.lcia_result_error('not_data_product_manager', 403, 'not data product manager');
  end if;
  if p_format is null or p_format not in ('parquet', 'csv', 'lcia_xlsx', 'lcia_csv', 'audit') then
    return api.lcia_result_error('invalid_export_format', 400, 'invalid export format');
  end if;
  select * into v_package from private.lcia_result_packages where id = p_package_id;
  if v_package.id is null then
    return api.lcia_result_error('package_not_found', 404, 'package not found');
  end if;
  if v_package.status <> 'preview_ready' or v_package.result_id is null then
    return api.lcia_result_error('calculation_not_ready', 409, 'calculation not ready');
  end if;
  select coalesce(v_package.artifact_manifest->'calculationBundle', diagnostics->'calculation_bundle')
    into v_bundle from private.lca_results where id = v_package.result_id;
  if v_bundle is null or coalesce(v_bundle->>'bundleContentHash', '') !~ '^[0-9a-f]{64}$'
    or coalesce(v_bundle->>'manifestSha256', '') !~ '^[0-9a-f]{64}$'
    or coalesce(v_bundle->>'schemaVersion', '') <> 'tiangong.calculation-bundle.v2' then
    return api.lcia_result_error('calculation_bundle_not_available', 409, 'calculation bundle not available');
  end if;
  v_hash := encode(extensions.digest(convert_to(jsonb_build_array(
    'lca.calculation_export.request.v1', p_package_id, v_bundle->>'bundleContentHash',
    v_bundle->>'manifestSha256', p_format
  )::text, 'UTF8'), 'sha256'), 'hex');
  v_key := 'lca.calculation_export:' || v_hash;
  perform pg_advisory_xact_lock(hashtextextended(v_key, 0));
  select * into v_job from private.worker_jobs
    where job_kind = 'lca.calculation_export' and concurrency_key = v_key
    order by created_at desc, id limit 1;
  if v_job.id is null and coalesce(p_enqueue, false) then
    v_enqueued := private.worker_enqueue_job(
      p_job_kind => 'lca.calculation_export',
      p_payload_json => jsonb_build_object('packageId', p_package_id, 'bundle', v_bundle - 'downloads', 'format', p_format),
      p_payload_schema_version => 'lca.calculation_export.request.v1',
      p_subject_type => 'lcia_result_package', p_subject_id => p_package_id,
      p_subject_version => v_bundle->>'bundleContentHash', p_requested_by => p_requested_by,
      p_requester_type => 'user', p_idempotency_key => v_key, p_request_hash => v_hash,
      p_concurrency_key => v_key, p_queue_key => p_package_id::text, p_visibility => 'user'
    );
    if coalesce((v_enqueued->>'ok')::boolean, false) is false then return v_enqueued; end if;
    select * into v_job from private.worker_jobs where id = (v_enqueued#>>'{data,id}')::uuid;
  end if;
  -- Read/status never enqueue. Repeated explicit requests reuse terminal outcomes too.
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'packageId', p_package_id, 'format', p_format,
    'bundleContentHash', v_bundle->>'bundleContentHash',
    'sourceManifestSha256', v_bundle->>'manifestSha256',
    'workerJobId', v_job.id, 'status', coalesce(v_job.status, 'not_requested'),
    'progress', v_job.progress, 'errorCode', v_job.error_code,
    'errorMessage', v_job.error_message, 'retryable', v_job.retryable,
    'nextAction', case when v_job.status in ('failed', 'cancelled', 'blocked') then 'explicit_worker_job_retry' else null end,
    'result', case when v_job.status = 'completed' then v_job.result_json else null end
  ));
end;
$$;
alter function api.svc_lca_calculation_export(uuid,uuid,text,boolean) owner to postgres;
revoke all on function api.svc_lca_calculation_export(uuid,uuid,text,boolean) from public, anon, authenticated;
grant execute on function api.svc_lca_calculation_export(uuid,uuid,text,boolean) to service_role;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role)
values ('api.svc_lca_calculation_export(uuid, uuid, text, boolean)', 'EDGE-LCA-01', false, false, true);
comment on function api.svc_lca_calculation_export(uuid,uuid,text,boolean) is
  'Service-only manager-authorized immutable bundle export admission and readback. Readback never enqueues; every same-binding job, including failures, is reused until explicit Worker retry.';

notify pgrst, 'reload schema';
