CREATE OR REPLACE FUNCTION "api"."cmd_dataset_alias_execution_execute_v2"("p_request_id" "uuid", "p_nonce" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "lock_timeout" TO '5s'
    SET "statement_timeout" TO '60s'
    AS $_$
declare
  v_request util.dataset_alias_execution_v2_requests%rowtype;
  v_preflight util.dataset_alias_execution_v2_preflights%rowtype;
  v_alias_result jsonb;
  v_primary_closure jsonb;
  v_batch_result jsonb;
  v_alias_audit_count integer;
  v_failure jsonb;
  v_committed_at timestamp with time zone;
begin
  if not coalesce(util.is_service_request(), false) then
    return jsonb_build_object(
      'ok', false,
      'code', 'SERVICE_ROLE_REQUIRED',
      'status', 403,
      'message', 'Service role is required'
    );
  end if;

  if p_request_id is null
    or p_nonce is null
    or p_nonce !~ '^[a-f0-9]{64}$' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_INVALID_SERVICE_REQUEST',
      'status', 400,
      'message', 'Exact request ID and executor nonce are required'
    );
  end if;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
  for update;

  if v_request.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_REQUEST_NOT_FOUND',
      'status', 404,
      'message', 'Protected execution request not found'
    );
  end if;

  if util.dataset_alias_execution_v2_sha256(p_nonce)
      is distinct from v_request.nonce_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_NONCE_MISMATCH',
      'status', 403,
      'message', 'Executor nonce does not match the admitted request'
    );
  end if;

  if v_request.status is distinct from 'dispatched'
    or v_request.dispatch_count <> 1 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ALREADY_STARTED',
      'status', 409,
      'message', 'The one-shot executor may start only once',
      'request_status', v_request.status,
      'retry_allowed', false
    );
  end if;

  select preflight.*
  into v_preflight
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = p_request_id
    and preflight.actor_user_id = v_request.actor_user_id;

  if v_preflight.id is null
    or v_preflight.consumed_at is null
    or v_preflight.preflight_proof_sha256
      is distinct from v_request.preflight_proof_sha256 then
    update util.dataset_alias_execution_v2_requests
    set
      status = 'indeterminate',
      terminal_at = pg_catalog.clock_timestamp(),
      last_error = jsonb_build_object(
        'phase', 'executor_precondition',
        'code', 'ALIAS_EXECUTION_PREFLIGHT_LEDGER_MISMATCH'
      ),
      updated_at = pg_catalog.clock_timestamp()
    where id = p_request_id;

    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_LEDGER_MISMATCH',
      'status', 'indeterminate',
      'retry_allowed', false
    );
  end if;

  update util.dataset_alias_execution_v2_requests
  set
    status = 'running',
    started_at = pg_catalog.clock_timestamp(),
    updated_at = pg_catalog.clock_timestamp()
  where id = p_request_id;

  -- The service request remains authenticated by its secret headers.  Only
  -- auth.uid()/auth.email() are rebound so the existing owner-draft alias
  -- validators execute against the originally admitted actor.
  perform pg_catalog.set_config(
    'request.jwt.claim.sub',
    v_request.actor_user_id::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.email',
    v_preflight.actor_email,
    true
  );

  begin
    v_alias_result := private.cmd_dataset_alias_plan_v2_guarded(v_preflight.plan);

    if coalesce((v_alias_result->>'ok')::boolean, false) is not true
      or coalesce((v_alias_result->>'idempotent_replay')::boolean, true)
      or v_alias_result->>'plan_sha256' is distinct from v_request.plan_sha256
      or v_alias_result->>'operation_id' is distinct from v_request.operation_id
      or v_alias_result->>'plan_request_sha256'
        is distinct from v_request.plan_request_sha256
      or (v_alias_result #>> '{counts,action_count}') is distinct from (v_preflight.plan #>> '{expected,action_count}')
      or (v_alias_result #>> '{counts,exchange_count}') is distinct from (v_preflight.plan #>> '{expected,exchange_count}') then
      v_failure := jsonb_build_object(
        'phase', 'alias',
        'code', 'ALIAS_EXECUTION_PRIMARY_REJECTED',
        'result', coalesce(v_alias_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected primary alias execution rejected';
    end if;

    -- The audit topology is the one the plan declared and the plan executor already verified: one row
    -- audit per action, one summary per batch and the whole-plan summary. The ledger is counted here,
    -- never trusted from the executor's response.
    select count(*)
    into v_alias_audit_count
    from private.command_audit_log as audit
    where audit.actor_user_id = v_request.actor_user_id
      and audit.payload->>'plan_sha256' = v_request.plan_sha256
      and (
        (
          audit.command = 'cmd_dataset_alias_batch_v2_guarded'
          and audit.payload->>'record_type' in ('row', 'plan')
        )
        or (
          audit.command = 'cmd_dataset_alias_plan_v2_guarded'
          and audit.payload->>'record_type' = 'plan_summary'
        )
      );

    if v_alias_audit_count is distinct from
      (v_preflight.plan #>> '{expected,audit_count}')::bigint then
      v_failure := jsonb_build_object(
        'phase', 'alias_audit',
        'code', 'ALIAS_EXECUTION_AUDIT_COUNT_MISMATCH',
        'expected', (v_preflight.plan #>> '{expected,audit_count}')::bigint,
        'observed', v_alias_audit_count
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected alias audit set is incomplete';
    end if;

    v_primary_closure :=
      util.read_dataset_alias_execution_v2_primary_closure(
        v_request.actor_user_id,
        v_preflight.plan
      );

    if coalesce(
        (v_primary_closure->>'live_closure_proof')::boolean,
        false
      ) is not true
      or v_primary_closure->>'row_count' is distinct from (v_preflight.plan #>> '{expected,action_count}')
      or v_primary_closure->>'exchange_count' is distinct from (v_preflight.plan #>> '{expected,exchange_count}')
      or v_primary_closure->>'invalid_action_count' is distinct from '0' then
      v_failure := jsonb_build_object(
        'phase', 'primary_closure',
        'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_MISMATCH',
        'proof', coalesce(v_primary_closure, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected primary/support live closure is incomplete';
    end if;

    v_batch_result := util.admit_dataset_derivative_rebuild_batch(
      v_request.actor_user_id,
      v_request.id,
      v_request.plan_sha256,
      v_request.operation_id,
      'PROTECTED_ALIAS_DERIVATIVE_CLOSURE',
      v_preflight.derivative_targets
    );

    if coalesce((v_batch_result->>'ok')::boolean, false) is not true
      or (v_batch_result->>'target_count')::integer is distinct from
        (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
      or coalesce(v_batch_result->>'flow_count', v_batch_result->>'flows')::integer is distinct from
        (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'flows')
      or coalesce(v_batch_result->>'process_count', v_batch_result->>'processes')::integer is distinct from
        (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'processes') then
      v_failure := jsonb_build_object(
        'phase', 'derivative_batch',
        'code', 'ALIAS_EXECUTION_DERIVATIVE_ADMISSION_MISMATCH',
        'result', coalesce(v_batch_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected derivative batch admission rejected';
    end if;

    v_committed_at := pg_catalog.clock_timestamp();

    update util.dataset_alias_execution_v2_requests
    set
      status = 'derivatives_pending',
      primary_committed_at = v_committed_at,
      alias_result = v_alias_result || jsonb_build_object(
        'primary_closure', v_primary_closure
      ),
      derivative_admission = v_batch_result,
      updated_at = v_committed_at
    where id = p_request_id;
  exception
    when others then
      if v_failure is null then
        v_failure := jsonb_build_object(
          'phase', 'executor',
          'code', 'ALIAS_EXECUTION_TRANSACTION_FAILED',
          'sqlstate', sqlstate,
          'message', sqlerrm
        );
      end if;
  end;

  if v_failure is not null then
    update util.dataset_alias_execution_v2_requests
    set
      status = 'failed',
      terminal_at = pg_catalog.clock_timestamp(),
      last_error = v_failure,
      updated_at = pg_catalog.clock_timestamp()
    where id = p_request_id;

    return jsonb_build_object(
      'ok', false,
      'command', 'cmd_dataset_alias_execution_execute_v2',
      'request_id', p_request_id,
      'status', 'failed',
      'primary_rolled_back', true,
      'retry_allowed', false,
      'error', v_failure
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_execute_v2',
    'request_id', p_request_id,
    'status', 'derivatives_pending',
    'plan_sha256', v_request.plan_sha256,
    'operation_id', v_request.operation_id,
    'plan_request_sha256', v_request.plan_request_sha256,
    'primary_committed_at', v_committed_at,
    'row_count', (select (preflight.plan #>> '{expected,action_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'exchange_count', (select (preflight.plan #>> '{expected,exchange_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'alias_audit_count', (select (preflight.plan #>> '{expected,audit_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'primary_closure', v_primary_closure,
    'derivative_target_count', (select (preflight.plan #>> '{expected,derivative_target_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'retry_allowed', false
  );
end;
$_$;

ALTER FUNCTION "api"."cmd_dataset_alias_execution_execute_v2"("p_request_id" "uuid", "p_nonce" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_dataset_alias_execution_execute_v2"("p_request_id" "uuid", "p_nonce" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_dataset_alias_execution_execute_v2"("p_request_id" "uuid", "p_nonce" "text") TO "service_role";
