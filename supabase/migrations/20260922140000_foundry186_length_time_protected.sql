-- Foundry #186 / Database #674: protected-lifecycle dispatch for the closed Length*time profile.
--
-- The reviewed Time lifecycle is the foundation and is not widened. Exactly one closed discriminator
-- (private.dataset_protected_profile, keyed on the plan's own schema_version) selects the executor,
-- the audit-ledger topology and the closure / terminal-proof readers at the four lifecycle sites:
-- the preflight and gate rollback simulations, the service-only execute, and the read. The freeze
-- keeps one shape for both profiles by projecting the Length plan's two canonical snapshots into the
-- shared {flowproperty, unitgroup} node (the CLI359-agreed A3 rule). Every other rule, envelope,
-- gate, nonce, window, count and refusal is byte-unchanged from Time.
--
-- Recorded for Database #677: the queued admit callback must carry Content-Profile: api. This
-- migration replaces no callback and no admit code, so it cannot regress that header.

create or replace function api.cmd_dataset_alias_execution_preflight_v2_guarded(
  p_request jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set statement_timeout = '60s'
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_email text := auth.email();
  v_schema_version constant text := 'dataset-alias-execution-preflight.v2';
  v_request_id uuid;
  v_environment text;
  v_project_ref text;
  v_server_context jsonb;
  v_request_actor jsonb;
  v_plan jsonb;
  v_freeze jsonb;
  v_approval jsonb;
  v_expected_freeze jsonb;
  v_expected_approval jsonb;
  v_bindings jsonb;
  v_expected jsonb;
  v_input_targets jsonb;
  v_targets jsonb;
  v_sorted_targets jsonb;
  v_gate_expectations jsonb;
  v_primary_gate_material jsonb;
  v_unused_gate_material jsonb;
  v_quiescence_gate_material jsonb;
  v_plan_sha256 text;
  v_operation_id text;
  v_plan_request_sha256 text;
  v_alias_plan_request_sha256 text;
  v_derivative_target_set_sha256 text;
  v_derivative_baseline_set_sha256 text;
  v_bindings_sha256 text;
  v_expected_sha256 text;
  v_targets_sha256 text;
  v_gate_expectations_sha256 text;
  v_failure_baseline_material jsonb;
  v_failure_baseline_sha256 text;
  v_request_sha256 text;
  v_token text;
  v_token_sha256 text;
  v_proof_material jsonb;
  v_proof_sha256 text;
  v_completed_at timestamp with time zone;
  v_expires_at timestamp with time zone;
  v_target jsonb;
  v_snapshot jsonb;
  v_alias_result jsonb;
  v_batch_result jsonb;
  v_simulation_passed boolean := false;
  v_simulation_error jsonb;
  v_existing_id uuid;
  v_execution_count integer := 0;
  v_alias_audit_count integer := 0;
  v_derivative_child_count integer := 0;
  v_snapshot_drift_count integer := 0;
  v_active_rebuild_count integer := 0;
  v_http_count integer := 0;
  v_extraction_count integer := 0;
  v_embedding_count integer := 0;
  v_pending_count integer := 0;
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if nullif(v_actor_email, '') is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_EMAIL_REQUIRED',
      'status', 401,
      'message', 'Authenticated email claim is required'
    );
  end if;

  if p_request is not null and pg_column_size(p_request) > 67108864 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TOO_LARGE',
      'status', 413,
      'message', 'Protected preflight request exceeds 64 MiB'
    );
  end if;

  if jsonb_typeof(p_request) is distinct from 'object'
    or not (p_request ?& array[
      'schema_version',
      'request_id',
      'environment',
      'project_ref',
      'actor',
      'target_visibility',
      'plan',
      'freeze',
      'approval',
      'bindings',
      'expected',
      'derivative_targets'
    ])
    or exists (
      select 1
      from jsonb_object_keys(p_request) as request_key(key)
      where request_key.key <> all (array[
        'schema_version',
        'request_id',
        'environment',
        'project_ref',
        'actor',
        'target_visibility',
        'plan',
        'freeze',
        'approval',
        'bindings',
        'expected',
        'derivative_targets'
      ])
    )
    or p_request->>'schema_version' is distinct from v_schema_version
    or jsonb_typeof(p_request->'request_id') is distinct from 'string'
    or (p_request->>'request_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or p_request->>'environment' not in ('production', 'preview', 'local')
    or jsonb_typeof(p_request->'project_ref') is distinct from 'string'
    or nullif(btrim(p_request->>'project_ref'), '') is null
    or octet_length(p_request->>'project_ref') > 128
    or p_request->>'target_visibility' is distinct from 'owner_draft'
    or jsonb_typeof(p_request->'actor') is distinct from 'object'
    or jsonb_typeof(p_request->'plan') is distinct from 'object'
    or jsonb_typeof(p_request->'freeze') is distinct from 'object'
    or jsonb_typeof(p_request->'approval') is distinct from 'object'
    or jsonb_typeof(p_request->'bindings') is distinct from 'object'
    or jsonb_typeof(p_request->'expected') is distinct from 'object'
    or jsonb_typeof(p_request->'derivative_targets') is distinct from 'array' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_REQUEST',
      'status', 400,
      'message', 'Preflight request must match dataset-alias-execution-preflight.v1 exactly'
    );
  end if;

  v_request_id := (p_request->>'request_id')::uuid;
  v_environment := p_request->>'environment';
  v_project_ref := btrim(p_request->>'project_ref');
  v_request_actor := p_request->'actor';
  v_plan := p_request->'plan';
  v_freeze := p_request->'freeze';
  v_approval := p_request->'approval';
  v_bindings := p_request->'bindings';
  v_expected := p_request->'expected';
  v_input_targets := p_request->'derivative_targets';

  begin
    v_server_context := util.dataset_alias_execution_v2_server_context();
  exception
    when others then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_SERVER_CONTEXT_UNAVAILABLE',
        'status', 409,
        'message', 'Branch-local project identity could not be derived from trusted server configuration'
      );
  end;

  if v_environment is distinct from v_server_context->>'environment'
    or v_project_ref is distinct from v_server_context->>'project_ref' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_SERVER_CONTEXT_MISMATCH',
      'status', 409,
      'message', 'Requested environment and project_ref do not match the connected database'
    );
  end if;

  if not (v_request_actor ?& array['user_id', 'email'])
    or exists (
      select 1
      from jsonb_object_keys(v_request_actor) as actor_key(key)
      where actor_key.key <> all (array['user_id', 'email'])
    )
    or jsonb_typeof(v_request_actor->'user_id') is distinct from 'string'
    or v_request_actor->>'user_id' is distinct from v_actor::text
    or jsonb_typeof(v_request_actor->'email') is distinct from 'string'
    or lower(btrim(v_request_actor->>'email'))
      is distinct from lower(btrim(v_actor_email))
    or octet_length(v_request_actor->>'email') > 320 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_ACTOR_MISMATCH',
      'status', 403,
      'message', 'Preflight actor must match the authenticated user and email'
    );
  end if;

  if not (v_bindings ?& array[
      'plan_file_sha256',
      'freeze_file_sha256',
      'freeze_sha256',
      'approval_file_sha256',
      'approval_identity_sha256',
      'approval_text_sha256',
      'alias_plan_request_sha256',
      'before_hash_set_sha256',
      'desired_hash_set_sha256',
      'exchange_rewrite_set_sha256',
      'support_snapshot_set_sha256',
      'derivative_baseline_set_sha256',
      'derivative_target_set_sha256',
      'toolchain_evidence_sha256'
    ])
    or exists (
      select 1
      from jsonb_object_keys(v_bindings) as binding_key(key)
      where binding_key.key <> all (array[
        'plan_file_sha256',
        'freeze_file_sha256',
        'freeze_sha256',
        'approval_file_sha256',
        'approval_identity_sha256',
        'approval_text_sha256',
        'alias_plan_request_sha256',
        'before_hash_set_sha256',
        'desired_hash_set_sha256',
        'exchange_rewrite_set_sha256',
        'support_snapshot_set_sha256',
        'derivative_baseline_set_sha256',
        'derivative_target_set_sha256',
        'toolchain_evidence_sha256'
      ])
    )
    or exists (
      select 1
      from jsonb_each(v_bindings) as binding_item(key, value)
      where jsonb_typeof(binding_item.value) is distinct from 'string'
        or (binding_item.value #>> '{}') !~ '^[a-f0-9]{64}$'
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_BINDINGS',
      'status', 400,
      'message', 'All protected artifact bindings must be exact SHA-256 values'
    );
  end if;

  -- The protected expected block is the versioned plan's own claim block: the ten flat v1 counts plus
  -- the versioned text-action count, as JSON numbers on the external wire.
  if not (v_expected ?& array[
      'action_count',
      'batch_count',
      'exchange_count',
      'amount_field_count',
      'unrelated_exchange_count',
      'audit_count',
      'flowproperty_count',
      'flow_count',
      'process_count',
      'derivative_target_count',
      'text_action_count'
    ])
    or exists (
      select 1
      from jsonb_object_keys(v_expected) as expected_key(key)
      where expected_key.key <> all (array[
        'action_count',
        'batch_count',
        'exchange_count',
        'amount_field_count',
        'unrelated_exchange_count',
        'audit_count',
        'flowproperty_count',
        'flow_count',
        'process_count',
        'derivative_target_count',
        'text_action_count'
      ])
    )
    or exists (
      select 1
      from jsonb_each(v_expected) as expected_item(key, value)
      where jsonb_typeof(expected_item.value) is distinct from 'number'
    )
    or v_expected is distinct from (v_plan->'expected') then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_COUNTS',
      'status', 400,
      'message', 'Protected profile requires the plan-derived expected counts, and nothing else'
    );
  end if;

  if jsonb_array_length(v_input_targets) <> (v_plan #>> '{expected,derivative_target_count}')::integer
    or exists (
      select 1
      from jsonb_array_elements(v_input_targets) as target_item(value)
      where jsonb_typeof(target_item.value) is distinct from 'object'
        or not (target_item.value ?& array[
          'table',
          'id',
          'version',
          'user_id',
          'state_code',
          'baseline_snapshot_sha256'
        ])
        or exists (
          select 1
          from jsonb_object_keys(target_item.value) as target_key(key)
          where target_key.key <> all (array[
            'table',
            'id',
            'version',
            'user_id',
            'state_code',
            'baseline_snapshot_sha256'
          ])
        )
        or target_item.value->>'table' not in ('flows', 'processes')
        or jsonb_typeof(target_item.value->'table') is distinct from 'string'
        or jsonb_typeof(target_item.value->'id') is distinct from 'string'
        or (target_item.value->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or jsonb_typeof(target_item.value->'version') is distinct from 'string'
        or (target_item.value->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
        or jsonb_typeof(target_item.value->'user_id') is distinct from 'string'
        or target_item.value->>'user_id' is distinct from v_actor::text
        or jsonb_typeof(target_item.value->'state_code') is distinct from 'number'
        or target_item.value->>'state_code' is distinct from '0'
        or jsonb_typeof(target_item.value->'baseline_snapshot_sha256')
          is distinct from 'string'
        or (target_item.value->>'baseline_snapshot_sha256') !~ '^[a-f0-9]{64}$'
    )
    or (
      select count(*)
      from jsonb_array_elements(v_input_targets) as target_item(value)
      where target_item.value->>'table' = 'flows'
    ) <> (select count(*) from jsonb_array_elements(v_plan->'actions') as action_item(value) where action_item.value->>'table' = 'flows')
    or (
      select count(*)
      from jsonb_array_elements(v_input_targets) as target_item(value)
      where target_item.value->>'table' = 'processes'
    ) <> (select count(*) from jsonb_array_elements(v_plan->'actions') as action_item(value) where action_item.value->>'table' = 'processes')
    or (
      select count(distinct (
        target_item.value->>'table',
        target_item.value->>'id',
        target_item.value->>'version'
      ))
      from jsonb_array_elements(v_input_targets) as target_item(value)
    ) <> (v_plan #>> '{expected,derivative_target_count}')::integer then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_TARGETS',
      'status', 400,
      'message', 'Derivative targets must be the declared unique flows and processes owned by the actor at state_code 0'
    );
  end if;

  select jsonb_agg(target_item.value order by
    target_item.value->>'table',
    target_item.value->>'id',
    target_item.value->>'version'
  )
  into v_sorted_targets
  from jsonb_array_elements(v_input_targets) as target_item(value);

  if v_input_targets is distinct from v_sorted_targets then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TARGET_ORDER',
      'status', 400,
      'message', 'Derivative targets must use stable table/id/version order'
    );
  end if;

  -- The plan schema is the closed discriminator: Time keeps its schema, Length*time has its own,
  -- anything else refuses before any state is touched.
  if private.dataset_protected_profile(v_plan) is null
    or v_plan->>'target_visibility' is distinct from 'owner_draft'
    or (v_plan->>'plan_sha256') !~ '^[a-f0-9]{64}$'
    -- The claimed plan digest is the producer's canonical self-hash of the plan document minus its
    -- own binding; admission verifies it before anything downstream reuses the label.
    or util.dataset_alias_execution_v2_artifact_sha256(v_plan - 'plan_sha256')
      is distinct from (v_plan->>'plan_sha256')
    then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_PLAN',
      'status', 400,
      'message', 'Protected preflight requires one owner-draft dataset-alias-plan.v1 request'
    );
  end if;

  v_plan_sha256 := v_plan->>'plan_sha256';
  v_operation_id := v_plan->>'plan_sha256';

  select jsonb_agg(
    jsonb_build_object(
      'table', target_item.value->>'table',
      'id', target_item.value->>'id',
      'version', target_item.value->>'version',
      'expected_json_ordered_sha256',
        util.dataset_alias_execution_v2_sha256(
          (action_item.value->'desired_json_ordered')::text
        ),
      'baseline_snapshot_sha256',
        target_item.value->>'baseline_snapshot_sha256'
    ) order by
      target_item.value->>'table',
      target_item.value->>'id',
      target_item.value->>'version'
  )
  into v_targets
  from jsonb_array_elements(v_plan->'actions') as action_item(value)
  join jsonb_array_elements(v_input_targets) as target_item(value)
    on target_item.value->>'table' = action_item.value->>'table'
   and target_item.value->>'id' = action_item.value->>'id'
   and target_item.value->>'version' = action_item.value->>'version'
  where action_item.value->>'table' in ('flows', 'processes');

  if jsonb_typeof(v_targets) is distinct from 'array'
    or jsonb_array_length(v_targets) <> (v_plan #>> '{expected,derivative_target_count}')::integer then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TARGET_PLAN_MISMATCH',
      'status', 409,
      'message', 'Derivative target identities must exactly match the declared flow/process plan actions'
    );
  end if;

  -- The reviewed producer defines the plan request hash as the plan document with its own
  -- `plan_sha256` binding removed (the plan's self-digest is exactly that value), the derivative
  -- target set as the sorted `table:id@version` identity strings and the baseline set as the
  -- sorted baseline digests. All three are recomputed here with the same canonical artifact
  -- algorithm the producer uses, so neither side can drift without the other refusing.
  v_alias_plan_request_sha256 :=
    util.dataset_alias_execution_v2_artifact_sha256(v_plan - 'plan_sha256');

  select util.dataset_alias_execution_v2_artifact_sha256(
    jsonb_agg(target_identity order by target_identity collate "C")
  )
  into v_derivative_target_set_sha256
  from (
    select (target_item.value->>'table') || ':' || (target_item.value->>'id') || '@'
      || (target_item.value->>'version') as target_identity
    from jsonb_array_elements(v_input_targets) as target_item(value)
  ) as target_identities;

  select util.dataset_alias_execution_v2_artifact_sha256(
    jsonb_agg(baseline order by baseline collate "C")
  )
  into v_derivative_baseline_set_sha256
  from (
    select target_item.value->>'baseline_snapshot_sha256' as baseline
    from jsonb_array_elements(v_input_targets) as target_item(value)
  ) as target_baselines;

  if v_bindings->>'alias_plan_request_sha256'
      is distinct from v_alias_plan_request_sha256
    or v_bindings->>'derivative_target_set_sha256'
      is distinct from v_derivative_target_set_sha256
    or v_bindings->>'derivative_baseline_set_sha256'
      is distinct from v_derivative_baseline_set_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_ARTIFACT_SET_MISMATCH',
      'status', 409,
      'message', 'The approved alias request or derivative target sets do not match server recomputation'
    );
  end if;

  v_expected_freeze := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-freeze.v2',
    'environment', v_environment,
    'project_ref', v_project_ref,
    'account', v_request_actor,
    'target_visibility', 'owner_draft',
    -- The freeze binds the plan file, the plan digest and the plan's own versioned content. The
    -- internal operation identity is the plan digest and stays server-side: the approved envelope
    -- carries no separate operation id.
    'plan', jsonb_build_object(
      'plan_file_sha256', v_bindings->>'plan_file_sha256',
      'plan_sha256', v_plan_sha256
    ),
    -- A3: one freeze shape for both profiles. The Length*time plan has no target_snapshots node of
    -- its own, so its two canonical snapshots project into the same {flowproperty, unitgroup} shape.
    'target_snapshots', case private.dataset_protected_profile(v_plan)
      when 'length_time_v1' then jsonb_build_object(
        'flowproperty', v_plan->'target_flow_property',
        'unitgroup', v_plan->'target_unit_group')
      else v_plan->'target_snapshots' end,
    'source_evidence', v_plan->'source_evidence',
    'sets', jsonb_build_object(
      'alias_plan_request_sha256',
        v_bindings->>'alias_plan_request_sha256',
      'before_hash_set_sha256',
        v_bindings->>'before_hash_set_sha256',
      'desired_hash_set_sha256',
        v_bindings->>'desired_hash_set_sha256',
      'exchange_rewrite_set_sha256',
        v_bindings->>'exchange_rewrite_set_sha256',
      'support_snapshot_set_sha256',
        v_bindings->>'support_snapshot_set_sha256',
      'derivative_baseline_set_sha256',
        v_bindings->>'derivative_baseline_set_sha256',
      'derivative_target_set_sha256',
        v_bindings->>'derivative_target_set_sha256',
      'toolchain_evidence_sha256',
        v_bindings->>'toolchain_evidence_sha256'
    ),
    'expected', v_expected,
    'derivative_targets', v_input_targets,
    'policy', jsonb_build_object(
      'state_code_changes', 0,
      'save_draft', 0,
      'deletes', 0,
      'rebuild_derivatives', 0,
      'unitgroup_actions', 0,
      'person_distance_actions', 0,
      'max_admit_posts', 1,
      'automatic_retry', false
    ),
    'freeze_sha256', v_bindings->>'freeze_sha256'
  );

  if v_freeze is distinct from v_expected_freeze
    or util.dataset_alias_execution_v2_artifact_sha256(
      v_freeze - 'freeze_sha256'
    ) is distinct from v_bindings->>'freeze_sha256' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_FREEZE_MISMATCH',
      'status', 409,
      'message', 'The production freeze envelope or canonical freeze hash is invalid'
    );
  end if;

  begin
    perform (v_approval->>'approved_at_utc')::timestamp with time zone;
  exception
    when others then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_PREFLIGHT_APPROVAL_MISMATCH',
        'status', 409,
        'message', 'The exact approval timestamp is invalid'
      );
  end;

  v_expected_approval := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-approval.v2',
    'approved_at_utc', v_approval->>'approved_at_utc',
    'environment', v_environment,
    'project_ref', v_project_ref,
    'account', v_request_actor,
    'target_visibility', 'owner_draft',
    'plan_sha256', v_plan_sha256,
    'plan_file_sha256', v_bindings->>'plan_file_sha256',
    'freeze_file_sha256', v_bindings->>'freeze_file_sha256',
    'freeze_sha256', v_bindings->>'freeze_sha256',
    'approval_text_sha256', v_bindings->>'approval_text_sha256',
    'max_admit_posts', 1,
    'automatic_retry', false,
    'approval_identity_sha256', v_bindings->>'approval_identity_sha256'
  );

  if v_approval is distinct from v_expected_approval
    or util.dataset_alias_execution_v2_artifact_sha256(
      v_approval - 'approval_identity_sha256'
    ) is distinct from v_bindings->>'approval_identity_sha256' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_APPROVAL_MISMATCH',
      'status', 409,
      'message', 'The approval identity does not bind this exact production freeze and alias request'
    );
  end if;

  select preflight.id
  into v_existing_id
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = v_request_id
     or (
       preflight.actor_user_id = v_actor
       and preflight.approval_identity_sha256 =
         v_bindings->>'approval_identity_sha256'
     )
  limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_APPROVAL_ALREADY_USED',
      'status', 409,
      'message', 'This request ID or exact approval identity already created a protected preflight; freeze and approve again'
    );
  end if;

  for v_target in
    select target_item.value
    from jsonb_array_elements(v_targets) as target_item(value)
  loop
    begin
      v_snapshot := util.dataset_derivative_rebuild_snapshot(
        v_target->>'table',
        (v_target->>'id')::uuid,
        v_target->>'version'
      );
    exception
      when others then
        v_snapshot := null;
    end;

    if v_snapshot is null
      or v_snapshot->>'user_id' is distinct from v_actor::text
      or v_snapshot->>'state_code' is distinct from '0'
      or v_snapshot->>'json_sha256' is distinct from v_snapshot->>'json_ordered_sha256'
      or v_snapshot->>'snapshot_sha256'
        is distinct from v_target->>'baseline_snapshot_sha256' then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_PREFLIGHT_BASELINE_DRIFT',
        'status', 409,
        'message', 'A derivative target no longer matches its owner-draft baseline snapshot'
      );
    end if;
  end loop;

  v_plan_request_sha256 := util.dataset_alias_execution_v2_sha256(v_plan::text);
  v_bindings_sha256 := util.dataset_alias_execution_v2_sha256(v_bindings::text);
  v_expected_sha256 := util.dataset_alias_execution_v2_sha256(v_expected::text);
  v_targets_sha256 := util.dataset_alias_execution_v2_sha256(v_targets::text);
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', failure.id,
        'queue_name', failure.queue_name,
        'msg_id', failure.msg_id,
        'read_count', failure.read_count,
        'reason', failure.reason,
        'message', failure.message,
        'failed_at', failure.failed_at
      ) order by failure.id
    ),
    '[]'::jsonb
  )
  into v_failure_baseline_material
  from util.embedding_job_failures as failure
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where failure.message->>'table' = target_item.value->>'table'
      and failure.message->>'id' = target_item.value->>'id'
      and btrim(failure.message->>'version') = target_item.value->>'version'
  );
  v_failure_baseline_sha256 :=
    util.dataset_alias_execution_v2_sha256(v_failure_baseline_material::text);
  v_request_sha256 := util.dataset_alias_execution_v2_sha256(p_request::text);

  -- The simulation creates all normal alias writes, audits, webhook work, and
  -- derivative fences inside this exception block.  The controlled P0002
  -- exception always rolls those effects back before a durable token exists.
  begin
    v_alias_result := case private.dataset_protected_profile(v_plan)
      when 'alias_v2' then private.cmd_dataset_alias_plan_v2_guarded(v_plan)
      when 'length_time_v1' then private.cmd_dataset_length_time_v1_guarded(v_plan)
    end;
    if coalesce((v_alias_result->>'ok')::boolean, false) is not true
      or coalesce((v_alias_result->>'idempotent_replay')::boolean, true)
      or (v_alias_result #>> '{counts,action_count}') is distinct from (v_plan #>> '{expected,action_count}')
      or (v_alias_result #>> '{counts,exchange_count}') is distinct from (v_plan #>> '{expected,exchange_count}') then
      v_simulation_error := jsonb_build_object(
        'phase', 'alias',
        'result', coalesce(v_alias_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected alias simulation rejected';
    end if;

    v_batch_result := util.admit_dataset_alias_v2_derivative_chunks(
      v_actor,
      v_request_id,
      v_plan_sha256,
      v_operation_id,
      'PROTECTED_ALIAS_DERIVATIVE_CLOSURE',
      v_targets
    );

    if coalesce((v_batch_result->>'ok')::boolean, false) is not true
      or (v_batch_result->>'target_count')::integer is distinct from (v_plan #>> '{expected,derivative_target_count}')::integer
      or (v_batch_result->>'flow_count')::integer is distinct from (select count(*) from jsonb_array_elements(v_targets) as target where target->>'table' = 'flows')
      or (v_batch_result->>'process_count')::integer is distinct from (select count(*) from jsonb_array_elements(v_targets) as target where target->>'table' = 'processes') then
      v_simulation_error := jsonb_build_object(
        'phase', 'derivative_batch',
        'result', coalesce(v_batch_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected derivative batch simulation rejected';
    end if;

    raise exception using
      errcode = 'P0002',
      message = 'Protected execution preflight simulation rollback';
  exception
    when sqlstate 'P0002' then
      v_simulation_passed := true;
    when others then
      v_simulation_passed := false;
      if v_simulation_error is null then
        v_simulation_error := jsonb_build_object(
          'phase', 'unexpected',
          'sqlstate', sqlstate,
          'message', sqlerrm
        );
      end if;
  end;

  if not v_simulation_passed then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_SIMULATION_FAILED',
      'status', 409,
      'message', 'The exact protected plan failed rollback-only server simulation',
      'evidence', v_simulation_error
    );
  end if;

  select count(*)::integer
  into v_execution_count
  from util.dataset_alias_execution_v2_requests as request
  where request.actor_user_id = v_actor
    and request.approval_identity_sha256 =
      v_bindings->>'approval_identity_sha256';

  select count(*)::integer
  into v_alias_audit_count
  from private.command_audit_log as audit
  where audit.actor_user_id = v_actor
    and (
      (
        audit.command = 'cmd_dataset_alias_batch_v2_guarded'
        and audit.payload->>'plan_sha256' = v_plan_sha256
        and audit.payload->>'operation_id' = v_operation_id
      )
      or (
        audit.command = 'cmd_dataset_alias_plan_v2_guarded'
        and audit.payload->>'plan_request_sha256' = v_plan_request_sha256
      )
        or (
          audit.command = 'cmd_dataset_length_time_v1_guarded'
          and audit.payload->>'plan_sha256' = v_plan_sha256
        )
    );

  select count(*)::integer
  into v_derivative_child_count
  from util.dataset_derivative_rebuild_requests as request
  where request.actor_user_id = v_actor
    and request.batch_id = v_request_id;

  for v_target in
    select target_item.value
    from jsonb_array_elements(v_targets) as target_item(value)
  loop
    begin
      v_snapshot := util.dataset_derivative_rebuild_snapshot(
        v_target->>'table',
        (v_target->>'id')::uuid,
        v_target->>'version'
      );
    exception
      when others then
        v_snapshot := null;
    end;

    if v_snapshot is null
      or v_snapshot->>'user_id' is distinct from v_actor::text
      or v_snapshot->>'state_code' is distinct from '0'
      or v_snapshot->>'snapshot_sha256'
        is distinct from v_target->>'baseline_snapshot_sha256' then
      v_snapshot_drift_count := v_snapshot_drift_count + 1;
    end if;
  end loop;

  select count(*)::integer
  into v_active_rebuild_count
  from util.dataset_derivative_rebuild_requests as request
  where request.status not in ('completed', 'stale', 'failed')
    and exists (
      select 1
      from jsonb_array_elements(v_targets) as target_item(value)
      where request.target_table = target_item.value->>'table'
        and request.target_id = (target_item.value->>'id')::uuid
        and request.target_version = target_item.value->>'version'
    );

  select count(*)::integer
  into v_http_count
  from net.http_request_queue as request
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where util.dataset_derivative_rebuild_http_body_matches(
      request.body,
      target_item.value->>'table',
      (target_item.value->>'id')::uuid,
      target_item.value->>'version'
    )
  );

  select count(*)::integer
  into v_extraction_count
  from pgmq.q_dataset_extraction_jobs as job
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where job.message->>'schema' = 'public'
      and job.message->>'table' = target_item.value->>'table'
      and job.message->>'id' = target_item.value->>'id'
      and btrim(job.message->>'version') = target_item.value->>'version'
  );

  select count(*)::integer
  into v_embedding_count
  from pgmq.q_embedding_jobs as job
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where job.message->>'schema' = 'public'
      and job.message->>'table' = target_item.value->>'table'
      and job.message->>'id' = target_item.value->>'id'
      and btrim(job.message->>'version') = target_item.value->>'version'
      and job.message->>'embeddingColumn' = 'embedding_ft'
  );

  select count(*)::integer
  into v_pending_count
  from util.pending_embedding_jobs as pending
  where pending.schema_name = 'public'
    and pending.embedding_column = 'embedding_ft'
    and pending.status = 'pending'
    and exists (
      select 1
      from jsonb_array_elements(v_targets) as target_item(value)
      where pending.table_name = target_item.value->>'table'
        and pending.record_id = target_item.value->>'id'
        and btrim(pending.record_version) = target_item.value->>'version'
    );

  if v_execution_count <> 0
    or v_alias_audit_count <> 0
    or v_derivative_child_count <> 0
    or v_snapshot_drift_count <> 0
    or v_active_rebuild_count <> 0
    or v_http_count <> 0
    or v_extraction_count <> 0
    or v_embedding_count <> 0
    or v_pending_count <> 0 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_NOT_QUIESCENT',
      'status', 409,
      'message', 'The exact approval identity, targets, or derivative queues are not unused and quiescent'
    );
  end if;

  v_primary_gate_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-material.v2',
    'gate', 'primary_support_plan',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'plan_request_sha256', v_plan_request_sha256,
    'derivative_targets_sha256', v_targets_sha256,
    'plan_rows', jsonb_array_length(v_plan->'actions'),
    'plan_exchanges', (v_plan #>> '{expected,exchange_count}')::integer,
    'alias_audits', (v_plan #>> '{expected,audit_count}')::integer,
    'derivative_targets', jsonb_array_length(v_input_targets),
    'rollback_simulation_passed', true
  );
  v_unused_gate_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-material.v2',
    'gate', 'execution_unused',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'plan_request_sha256', v_plan_request_sha256,
    'sealed_execution_rows', v_execution_count,
    'alias_audit_rows', v_alias_audit_count,
    'derivative_child_rows', v_derivative_child_count
  );
  v_quiescence_gate_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-material.v2',
    'gate', 'derivative_quiescence',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'derivative_targets_sha256', v_targets_sha256,
    'snapshot_drift_count', v_snapshot_drift_count,
    'active_rebuild_count', v_active_rebuild_count,
    'http_request_count', v_http_count,
    'extraction_job_count', v_extraction_count,
    'embedding_job_count', v_embedding_count,
    'pending_embedding_count', v_pending_count,
    'failure_baseline_sha256', v_failure_baseline_sha256
  );
  v_gate_expectations := jsonb_build_object(
    'primary_support_plan_sha256',
      util.dataset_alias_execution_v2_sha256(v_primary_gate_material::text),
    'execution_unused_sha256',
      util.dataset_alias_execution_v2_sha256(v_unused_gate_material::text),
    'derivative_quiescence_sha256',
      util.dataset_alias_execution_v2_sha256(v_quiescence_gate_material::text)
  );
  v_gate_expectations_sha256 :=
    util.dataset_alias_execution_v2_sha256(v_gate_expectations::text);

  select preflight.id
  into v_existing_id
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = v_request_id
     or (
       preflight.actor_user_id = v_actor
       and preflight.preflight_request_sha256 = v_request_sha256
     )
  limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_ALREADY_EXISTS',
      'status', 409,
      'message', 'A preflight request ID or exact request was already used; tokens are never replayed'
    );
  end if;

  v_completed_at := pg_catalog.clock_timestamp();
  v_expires_at := v_completed_at + interval '180 seconds';
  v_token := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
  v_token_sha256 := util.dataset_alias_execution_v2_sha256(v_token);
  v_proof_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-preflight-proof.v2',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'environment', v_environment,
    'project_ref', v_project_ref,
    'server_context_sha256',
      util.dataset_alias_execution_v2_sha256(v_server_context::text),
    'plan_sha256', v_plan_sha256,
    'operation_id', v_operation_id,
    'alias_plan_request_sha256', v_alias_plan_request_sha256,
    'freeze_sha256', v_bindings->>'freeze_sha256',
    'approval_identity_sha256',
      v_bindings->>'approval_identity_sha256',
    'plan_request_sha256', v_plan_request_sha256,
    'bindings_sha256', v_bindings_sha256,
    'expected_sha256', v_expected_sha256,
    'derivative_targets_sha256', v_targets_sha256,
    'gate_expectations', v_gate_expectations,
    'gate_expectations_sha256', v_gate_expectations_sha256,
    'failure_baseline_sha256', v_failure_baseline_sha256,
    'preflight_request_sha256', v_request_sha256,
    'completed_at', v_completed_at,
    'expires_at', v_expires_at
  );
  v_proof_sha256 := util.dataset_alias_execution_v2_sha256(v_proof_material::text);

  insert into util.dataset_alias_execution_v2_preflights (
    id,
    actor_user_id,
    actor_email,
    environment,
    project_ref,
    target_visibility,
    plan,
    freeze_envelope,
    approval_envelope,
    plan_sha256,
    operation_id,
    plan_request_sha256,
    bindings,
    bindings_sha256,
    expected,
    expected_sha256,
    derivative_targets,
    derivative_targets_sha256,
    gate_expectations,
    gate_expectations_sha256,
    failure_baseline_sha256,
    preflight_request_sha256,
    preflight_proof_sha256,
    freeze_sha256,
    approval_identity_sha256,
    token_sha256,
    completed_at,
    expires_at
  ) values (
    v_request_id,
    v_actor,
    lower(btrim(v_actor_email)),
    v_environment,
    v_project_ref,
    'owner_draft',
    v_plan,
    v_freeze,
    v_approval,
    v_plan_sha256,
    v_operation_id,
    v_plan_request_sha256,
    v_bindings,
    v_bindings_sha256,
    v_expected,
    v_expected_sha256,
    v_targets,
    v_targets_sha256,
    v_gate_expectations,
    v_gate_expectations_sha256,
    v_failure_baseline_sha256,
    v_request_sha256,
    v_proof_sha256,
    v_bindings->>'freeze_sha256',
    v_bindings->>'approval_identity_sha256',
    v_token_sha256,
    v_completed_at,
    v_expires_at
  );

  return v_proof_material || jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_preflight_v2_guarded',
    'preflight_token', v_token,
    'preflight_proof_sha256', v_proof_sha256,
    'simulation', jsonb_build_object(
      'plan_rows', jsonb_array_length(v_plan->'actions'),
      'plan_exchanges', (v_plan #>> '{expected,exchange_count}')::integer,
      'alias_audits', (v_plan #>> '{expected,audit_count}')::integer,
      'derivative_targets', jsonb_array_length(v_input_targets),
      'rolled_back', true
    )
  );
exception
  when lock_not_available then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_LOCK_BUSY',
      'status', 409,
      'message', 'Protected preflight could not acquire its bounded locks'
    );
  when unique_violation then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_CONCURRENT_CONFLICT',
      'status', 409,
      'message', 'A concurrent preflight consumed the same request identity'
    );
end;
$$;

create or replace function api.cmd_dataset_alias_execution_gate_v2_guarded(
  p_request_id uuid,
  p_preflight_token text,
  p_gate_name text
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set statement_timeout = '55s'
as $$
declare
  v_actor uuid := auth.uid();
  v_preflight util.dataset_alias_execution_v2_preflights%rowtype;
  v_expected_name text;
  v_expected_sha256 text;
  v_material jsonb;
  v_observed_sha256 text;
  v_receipt_material jsonb;
  v_receipt_sha256 text;
  v_captured_at timestamp with time zone;
  v_alias_result jsonb;
  v_batch_result jsonb;
  v_simulation_passed boolean := false;
  v_execution_count integer := 0;
  v_alias_audit_count integer := 0;
  v_derivative_child_count integer := 0;
  v_snapshot_drift_count integer := 0;
  v_active_rebuild_count integer := 0;
  v_http_count integer := 0;
  v_extraction_count integer := 0;
  v_embedding_count integer := 0;
  v_pending_count integer := 0;
  v_failure_material jsonb;
  v_failure_sha256 text;
  v_target jsonb;
  v_snapshot jsonb;
  v_existing_gate_count integer := 0;
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_request_id is null
    or p_preflight_token is null
    or p_preflight_token !~ '^[a-f0-9]{64}$'
    or p_gate_name not in (
      'primary_support_plan',
      'execution_unused',
      'derivative_quiescence'
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_INVALID_REQUEST',
      'status', 400,
      'message', 'Exact request ID, preflight token, and known gate name are required'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor::text || ':' || p_request_id::text || ':' || p_gate_name,
      0
    )
  );

  select preflight.*
  into v_preflight
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = p_request_id
    and preflight.actor_user_id = v_actor
  for update;

  if v_preflight.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_NOT_FOUND',
      'status', 404,
      'message', 'No actor-owned protected preflight exists for this request ID'
    );
  end if;

  if v_preflight.consumed_at is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ATTEMPT_ALREADY_CONSUMED',
      'status', 409,
      'message', 'Admission already consumed this preflight; gates are read-only history now'
    );
  end if;

  if pg_catalog.clock_timestamp() > v_preflight.expires_at then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_EXPIRED',
      'status', 409,
      'message', 'The 180-second server preflight window expired before all gates completed'
    );
  end if;

  if util.dataset_alias_execution_v2_sha256(p_preflight_token)
      is distinct from v_preflight.token_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TOKEN_MISMATCH',
      'status', 403,
      'message', 'Preflight token does not match the durable server record'
    );
  end if;

  if exists (
    select 1
    from util.dataset_alias_execution_v2_gate_receipts as receipt
    where receipt.preflight_id = p_request_id
      and receipt.gate_name = p_gate_name
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_ALREADY_CAPTURED',
      'status', 409,
      'message', 'Each live gate is captured at most once; freeze again after a lost gate response'
    );
  end if;

  select count(*)::integer
  into v_existing_gate_count
  from util.dataset_alias_execution_v2_gate_receipts as receipt
  where receipt.preflight_id = p_request_id
    and receipt.actor_user_id = v_actor;

  if (
      p_gate_name = 'primary_support_plan'
      and v_existing_gate_count <> 0
    ) or (
      p_gate_name = 'execution_unused'
      and (
        v_existing_gate_count <> 1
        or not exists (
          select 1
          from util.dataset_alias_execution_v2_gate_receipts as receipt
          where receipt.preflight_id = p_request_id
            and receipt.actor_user_id = v_actor
            and receipt.gate_name = 'primary_support_plan'
        )
      )
    ) or (
      p_gate_name = 'derivative_quiescence'
      and (
        v_existing_gate_count <> 2
        or not exists (
          select 1
          from util.dataset_alias_execution_v2_gate_receipts as receipt
          where receipt.preflight_id = p_request_id
            and receipt.actor_user_id = v_actor
            and receipt.gate_name = 'primary_support_plan'
        )
        or not exists (
          select 1
          from util.dataset_alias_execution_v2_gate_receipts as receipt
          where receipt.preflight_id = p_request_id
            and receipt.actor_user_id = v_actor
            and receipt.gate_name = 'execution_unused'
        )
      )
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_ORDER_MISMATCH',
      'status', 409,
      'message', 'Live gates must be captured exactly once in primary/support, execution-unused, derivative-quiescence order'
    );
  end if;

  v_expected_name := case p_gate_name
    when 'primary_support_plan' then 'primary_support_plan_sha256'
    when 'execution_unused' then 'execution_unused_sha256'
    when 'derivative_quiescence' then 'derivative_quiescence_sha256'
  end;
  v_expected_sha256 := v_preflight.gate_expectations->>v_expected_name;

  if p_gate_name = 'primary_support_plan' then
    begin
      v_alias_result := case private.dataset_protected_profile(v_preflight.plan)
        when 'alias_v2' then private.cmd_dataset_alias_plan_v2_guarded(v_preflight.plan)
        when 'length_time_v1' then private.cmd_dataset_length_time_v1_guarded(v_preflight.plan)
    end;
      if coalesce((v_alias_result->>'ok')::boolean, false) is not true
        or coalesce((v_alias_result->>'idempotent_replay')::boolean, true)
        or (v_alias_result #>> '{counts,action_count}') is distinct from (v_preflight.plan #>> '{expected,action_count}')
        or (v_alias_result #>> '{counts,exchange_count}') is distinct from (v_preflight.plan #>> '{expected,exchange_count}') then
        raise exception using
          errcode = 'P0001',
          message = 'Primary/support simulation rejected';
      end if;

      v_batch_result := util.admit_dataset_alias_v2_derivative_chunks(
        v_actor,
        p_request_id,
        v_preflight.plan_sha256,
        v_preflight.operation_id,
        'PROTECTED_ALIAS_DERIVATIVE_CLOSURE',
        v_preflight.derivative_targets
      );

      if coalesce((v_batch_result->>'ok')::boolean, false) is not true
        or (v_batch_result->>'target_count')::integer
          is distinct from (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
        or coalesce((v_batch_result->>'flow_count')::integer, 0)
          is distinct from (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'flows')
        or coalesce((v_batch_result->>'process_count')::integer, 0)
          is distinct from (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'processes') then
        raise exception using
          errcode = 'P0001',
          message = 'Derivative batch simulation rejected';
      end if;

      raise exception using
        errcode = 'P0002',
        message = 'Protected primary/support gate rollback';
    exception
      when sqlstate 'P0002' then
        v_simulation_passed := true;
      when others then
        v_simulation_passed := false;
    end;

    if not v_simulation_passed then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_PRIMARY_SUPPORT_GATE_FAILED',
        'status', 409,
        'message', 'Primary/support plan drifted after preflight'
      );
    end if;

    v_material := jsonb_build_object(
      'schema_version', 'dataset-alias-execution-gate-material.v2',
      'gate', p_gate_name,
      'request_id', p_request_id,
      'actor_user_id', v_actor,
      'plan_request_sha256', v_preflight.plan_request_sha256,
      'derivative_targets_sha256', v_preflight.derivative_targets_sha256,
      'plan_rows', jsonb_array_length(v_preflight.plan->'actions'),
      'plan_exchanges', (v_preflight.plan #>> '{expected,exchange_count}')::integer,
      'alias_audits', (v_preflight.plan #>> '{expected,audit_count}')::integer,
      'derivative_targets', jsonb_array_length(v_preflight.derivative_targets),
      'rollback_simulation_passed', true
    );
  elsif p_gate_name = 'execution_unused' then
    select count(*)::integer
    into v_execution_count
    from util.dataset_alias_execution_v2_requests as request
    where request.actor_user_id = v_actor
      and request.approval_identity_sha256 =
        v_preflight.bindings->>'approval_identity_sha256';

    select count(*)::integer
    into v_alias_audit_count
    from private.command_audit_log as audit
    where audit.actor_user_id = v_actor
      and (
        (
          audit.command = 'cmd_dataset_alias_batch_v2_guarded'
          and audit.payload->>'plan_sha256' = v_preflight.plan_sha256
          and audit.payload->>'operation_id' = v_preflight.operation_id
        )
        or (
          audit.command = 'cmd_dataset_alias_plan_v2_guarded'
          and audit.payload->>'plan_request_sha256' =
            v_preflight.plan_request_sha256
        )
        or (
          audit.command = 'cmd_dataset_length_time_v1_guarded'
          and audit.payload->>'plan_sha256' = v_preflight.plan_sha256
        )
      );

    select count(*)::integer
    into v_derivative_child_count
    from util.dataset_derivative_rebuild_requests as request
    where request.actor_user_id = v_actor
      and request.batch_id = p_request_id;

    if v_execution_count <> 0
      or v_alias_audit_count <> 0
      or v_derivative_child_count <> 0 then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_UNUSED_GATE_FAILED',
        'status', 409,
        'message', 'The sealed execution identity already has durable effects'
      );
    end if;

    v_material := jsonb_build_object(
      'schema_version', 'dataset-alias-execution-gate-material.v2',
      'gate', p_gate_name,
      'request_id', p_request_id,
      'actor_user_id', v_actor,
      'plan_request_sha256', v_preflight.plan_request_sha256,
      'sealed_execution_rows', v_execution_count,
      'alias_audit_rows', v_alias_audit_count,
      'derivative_child_rows', v_derivative_child_count
    );
  else
    for v_target in
      select target_item.value
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
    loop
      begin
        v_snapshot := util.dataset_derivative_rebuild_snapshot(
          v_target->>'table',
          (v_target->>'id')::uuid,
          v_target->>'version'
        );
      exception
        when others then
          v_snapshot := null;
      end;

      if v_snapshot is null
        or v_snapshot->>'user_id' is distinct from v_actor::text
        or v_snapshot->>'state_code' is distinct from '0'
        or v_snapshot->>'snapshot_sha256'
          is distinct from v_target->>'baseline_snapshot_sha256' then
        v_snapshot_drift_count := v_snapshot_drift_count + 1;
      end if;
    end loop;

    select count(*)::integer
    into v_active_rebuild_count
    from util.dataset_derivative_rebuild_requests as request
    where request.status not in ('completed', 'stale', 'failed')
      and exists (
        select 1
        from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
        where request.target_table = target_item.value->>'table'
          and request.target_id = (target_item.value->>'id')::uuid
          and request.target_version = target_item.value->>'version'
      );

    select count(*)::integer
    into v_http_count
    from net.http_request_queue as request
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where util.dataset_derivative_rebuild_http_body_matches(
        request.body,
        target_item.value->>'table',
        (target_item.value->>'id')::uuid,
        target_item.value->>'version'
      )
    );

    select count(*)::integer
    into v_extraction_count
    from pgmq.q_dataset_extraction_jobs as job
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where job.message->>'schema' = 'public'
        and job.message->>'table' = target_item.value->>'table'
        and job.message->>'id' = target_item.value->>'id'
        and btrim(job.message->>'version') = target_item.value->>'version'
    );

    select count(*)::integer
    into v_embedding_count
    from pgmq.q_embedding_jobs as job
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where job.message->>'schema' = 'public'
        and job.message->>'table' = target_item.value->>'table'
        and job.message->>'id' = target_item.value->>'id'
        and btrim(job.message->>'version') = target_item.value->>'version'
        and job.message->>'embeddingColumn' = 'embedding_ft'
    );

    select count(*)::integer
    into v_pending_count
    from util.pending_embedding_jobs as pending
    where pending.schema_name = 'public'
      and pending.embedding_column = 'embedding_ft'
      and pending.status = 'pending'
      and exists (
        select 1
        from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
        where pending.table_name = target_item.value->>'table'
          and pending.record_id = target_item.value->>'id'
          and btrim(pending.record_version) = target_item.value->>'version'
      );

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', failure.id,
          'queue_name', failure.queue_name,
          'msg_id', failure.msg_id,
          'read_count', failure.read_count,
          'reason', failure.reason,
          'message', failure.message,
          'failed_at', failure.failed_at
        ) order by failure.id
      ),
      '[]'::jsonb
    )
    into v_failure_material
    from util.embedding_job_failures as failure
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where failure.message->>'table' = target_item.value->>'table'
        and failure.message->>'id' = target_item.value->>'id'
        and btrim(failure.message->>'version') = target_item.value->>'version'
    );
    v_failure_sha256 :=
      util.dataset_alias_execution_v2_sha256(v_failure_material::text);

    if v_snapshot_drift_count <> 0
      or v_active_rebuild_count <> 0
      or v_http_count <> 0
      or v_extraction_count <> 0
      or v_embedding_count <> 0
      or v_pending_count <> 0
      or v_failure_sha256 is distinct from v_preflight.failure_baseline_sha256 then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_DERIVATIVE_QUIESCENCE_GATE_FAILED',
        'status', 409,
        'message', 'Derivative baselines, queues, fences, or failure ledger drifted after preflight'
      );
    end if;

    v_material := jsonb_build_object(
      'schema_version', 'dataset-alias-execution-gate-material.v2',
      'gate', p_gate_name,
      'request_id', p_request_id,
      'actor_user_id', v_actor,
      'derivative_targets_sha256', v_preflight.derivative_targets_sha256,
      'snapshot_drift_count', v_snapshot_drift_count,
      'active_rebuild_count', v_active_rebuild_count,
      'http_request_count', v_http_count,
      'extraction_job_count', v_extraction_count,
      'embedding_job_count', v_embedding_count,
      'pending_embedding_count', v_pending_count,
      'failure_baseline_sha256', v_failure_sha256
    );
  end if;

  v_captured_at := pg_catalog.clock_timestamp();
  if v_captured_at > v_preflight.expires_at then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_WINDOW_EXPIRED',
      'status', 409,
      'message', 'The live gate completed after the 180-second server window'
    );
  end if;

  v_observed_sha256 := util.dataset_alias_execution_v2_sha256(v_material::text);
  if v_observed_sha256 is distinct from v_expected_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_EVIDENCE_MISMATCH',
      'status', 409,
      'message', 'The live gate evidence does not match the server-owned preflight expectation'
    );
  end if;

  v_receipt_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-receipt.v2',
    'request_id', p_request_id,
    'actor_user_id', v_actor,
    'preflight_proof_sha256', v_preflight.preflight_proof_sha256,
    'gate', p_gate_name,
    'expected_sha256', v_expected_sha256,
    'observed_sha256', v_observed_sha256,
    'status', 'passed',
    'captured_at', v_captured_at
  );
  v_receipt_sha256 :=
    util.dataset_alias_execution_v2_sha256(v_receipt_material::text);

  insert into util.dataset_alias_execution_v2_gate_receipts (
    preflight_id,
    actor_user_id,
    gate_name,
    expected_sha256,
    observed_sha256,
    material,
    status,
    captured_at,
    receipt_sha256
  ) values (
    p_request_id,
    v_actor,
    p_gate_name,
    v_expected_sha256,
    v_observed_sha256,
    v_material,
    'passed',
    v_captured_at,
    v_receipt_sha256
  );

  return v_receipt_material || jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_gate_v2_guarded',
    'receipt_sha256', v_receipt_sha256
  );
exception
  when lock_not_available then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_LOCK_BUSY',
      'status', 409,
      'message', 'Protected live gate could not acquire its bounded locks'
    );
  when unique_violation then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_ALREADY_CAPTURED',
      'status', 409,
      'message', 'A concurrent call already captured this live gate'
    );
end;
$$;

create or replace function api.cmd_dataset_alias_execution_execute_v2(
  p_request_id uuid,
  p_nonce text
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set statement_timeout = '60s'
as $$
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
    v_alias_result := case private.dataset_protected_profile(v_preflight.plan)
      when 'alias_v2' then private.cmd_dataset_alias_plan_v2_guarded(v_preflight.plan)
      when 'length_time_v1' then private.cmd_dataset_length_time_v1_guarded(v_preflight.plan)
    end;

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
        or (
          audit.command = 'cmd_dataset_length_time_v1_guarded'
          and audit.payload->>'record_type' in ('row', 'plan', 'plan_summary')
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

    v_primary_closure := case private.dataset_protected_profile(v_preflight.plan)
      when 'alias_v2' then util.read_dataset_alias_execution_v2_primary_closure(
        v_request.actor_user_id, v_preflight.plan)
      when 'length_time_v1' then util.read_dataset_length_time_v1_primary_closure(
        v_request.actor_user_id, v_preflight.plan)
    end;

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

    v_batch_result := util.admit_dataset_alias_v2_derivative_chunks(
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
      or coalesce((v_batch_result->>'flow_count')::integer, 0) is distinct from
        (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'flows')
      or coalesce((v_batch_result->>'process_count')::integer, 0) is distinct from
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
$$;

create or replace function api.cmd_dataset_alias_execution_read_v2(
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set statement_timeout = '60s'
as $$
declare
  v_actor uuid := auth.uid();
  v_preflight util.dataset_alias_execution_v2_preflights%rowtype;
  v_request util.dataset_alias_execution_v2_requests%rowtype;
  v_gate_receipts jsonb := '[]'::jsonb;
  v_gate_count integer := 0;
  v_alias_audit_count integer := 0;
  v_derivative_child_count integer := 0;
  v_derivative_flow_count integer := 0;
  v_derivative_process_count integer := 0;
  v_primary_closure jsonb;
  v_primary_closure_ok boolean := false;
  v_active_dispatch_grace boolean := false;
  v_initial_request_status text;
  v_initial_request_updated_at timestamp with time zone;
  v_proof_request_status text;
  v_proof_request_updated_at timestamp with time zone;
  v_request_changed_during_read boolean := false;
  v_batch_proof_read boolean := false;
  v_terminal_update_count integer := 0;
  v_terminal_update_status text;
  v_batch_proof jsonb;
  v_terminal_proof jsonb;
  v_category text;
  v_now timestamp with time zone := pg_catalog.clock_timestamp();
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_request_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_READ_INVALID_REQUEST',
      'status', 400,
      'message', 'Exact protected execution request ID is required'
    );
  end if;

  select preflight.*
  into v_preflight
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = p_request_id
    and preflight.actor_user_id = v_actor;

  if v_preflight.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_REQUEST_NOT_FOUND',
      'status', 404,
      'message', 'No actor-owned protected preflight or execution exists'
    );
  end if;

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'gate', receipt.gate_name,
          'expected_sha256', receipt.expected_sha256,
          'observed_sha256', receipt.observed_sha256,
          'status', receipt.status,
          'captured_at', receipt.captured_at,
          'receipt_sha256', receipt.receipt_sha256
        ) order by receipt.captured_at, receipt.gate_name
      ),
      '[]'::jsonb
    ),
    count(*)::integer
  into v_gate_receipts, v_gate_count
  from util.dataset_alias_execution_v2_gate_receipts as receipt
  where receipt.preflight_id = p_request_id
    and receipt.actor_user_id = v_actor;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
    and request.actor_user_id = v_actor;

  if v_request.id is null then
    return jsonb_build_object(
      'ok', true,
      'command', 'cmd_dataset_alias_execution_read_v2',
      'schema_version', 'dataset-alias-execution-status.v2',
      'request_id', p_request_id,
      'status', 'indeterminate',
      'execution_status', 'not_admitted',
      'code', case
        when v_preflight.consumed_at is null
          then 'ALIAS_EXECUTION_NOT_ADMITTED'
        else 'ALIAS_EXECUTION_ADMISSION_LEDGER_MISSING'
      end,
      'retry_allowed', false,
      'actor_user_id', v_actor,
      'environment', v_preflight.environment,
      'project_ref', v_preflight.project_ref,
      'plan_sha256', v_preflight.plan_sha256,
      'operation_id', v_preflight.operation_id,
      'plan_request_sha256', v_preflight.plan_request_sha256,
      'preflight_proof_sha256', v_preflight.preflight_proof_sha256,
      'preflight_completed_at', v_preflight.completed_at,
      'preflight_expires_at', v_preflight.expires_at,
      'preflight_consumed_at', v_preflight.consumed_at,
      'gate_count', v_gate_count,
      'gates', v_gate_receipts
    );
  end if;

  v_initial_request_status := v_request.status;
  v_initial_request_updated_at := v_request.updated_at;

  v_active_dispatch_grace :=
    v_request.status in ('dispatching', 'dispatched', 'running')
    and v_now <= v_request.admitted_at + interval '120 seconds';

  if v_active_dispatch_grace then
    -- Do not run the heavyweight live closure while the one-shot executor may
    -- be committing.  Apart from wasting work, a status lock/readback race
    -- must never delay or misclassify the only authorized mutation attempt.
    v_primary_closure := jsonb_build_object(
      'ok', false,
      'schema_version', 'dataset-alias-primary-closure.v1',
      'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_PENDING',
      'live_closure_proof', false
    );
  else

  select count(*)::integer
  into v_alias_audit_count
  from private.command_audit_log as audit
  where audit.actor_user_id = v_actor
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
        or (
          audit.command = 'cmd_dataset_length_time_v1_guarded'
          and audit.payload->>'record_type' in ('row', 'plan', 'plan_summary')
        )
    );

  select
    count(*)::integer,
    count(*) filter (where target_table = 'flows')::integer,
    count(*) filter (where target_table = 'processes')::integer
  into
    v_derivative_child_count,
    v_derivative_flow_count,
    v_derivative_process_count
  from util.dataset_derivative_rebuild_requests as child
  where child.actor_user_id = v_actor
    and child.batch_id in (
      select (chunk->>'batch_id')::uuid
      from jsonb_array_elements(private.dataset_alias_v2_derivative_chunks(
        p_request_id, v_request.plan_sha256, v_preflight.derivative_targets)) as chunk
    );

  v_primary_closure := case private.dataset_protected_profile(v_preflight.plan)
      when 'alias_v2' then util.read_dataset_alias_execution_v2_primary_closure(
        v_actor, v_preflight.plan)
      when 'length_time_v1' then util.read_dataset_length_time_v1_primary_closure(
        v_actor, v_preflight.plan)
    end;
  v_primary_closure_ok := coalesce(
    (v_primary_closure->>'live_closure_proof')::boolean,
    false
  );

  if v_request.status in ('dispatching', 'dispatched', 'running') then
    if v_alias_audit_count = (v_preflight.plan #>> '{expected,audit_count}')::integer
      and v_derivative_child_count =
        (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
      and v_derivative_flow_count = (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'flows'
      )
      and v_derivative_process_count = (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'processes'
      )
      and v_primary_closure_ok then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'derivatives_pending',
        primary_committed_at = coalesce(primary_committed_at, updated_at),
        updated_at = v_now
      where id = p_request_id
        and status in ('dispatching', 'dispatched', 'running');
    elsif (
        v_alias_audit_count > 0
        or v_derivative_child_count > 0
      ) and not v_primary_closure_ok then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'indeterminate',
        terminal_at = v_now,
        last_error = jsonb_build_object(
          'phase', 'reconcile',
          'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_MISMATCH',
          'primary_closure', v_primary_closure,
          'retry_allowed', false
        ),
        updated_at = v_now
      where id = p_request_id
        and status in ('dispatching', 'dispatched', 'running');
    elsif v_now > v_request.admitted_at + interval '120 seconds' then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'indeterminate',
        terminal_at = v_now,
        last_error = jsonb_build_object(
          'phase', 'reconcile',
          'code', 'ALIAS_EXECUTION_DISPATCH_OUTCOME_INDETERMINATE',
          'alias_audit_count', v_alias_audit_count,
          'derivative_child_count', v_derivative_child_count,
          'retry_allowed', false
        ),
        updated_at = v_now
      where id = p_request_id
        and status in ('dispatching', 'dispatched', 'running');
    end if;
  end if;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
    and request.actor_user_id = v_actor;

  v_request_changed_during_read :=
    v_request.status is distinct from v_initial_request_status
    or v_request.updated_at is distinct from v_initial_request_updated_at;

  if v_request_changed_during_read then
    -- VOLATILE PL/pgSQL statements can observe different READ COMMITTED
    -- snapshots.  If the executor or this reconciliation pass advanced the
    -- ledger after the first read, none of the evidence cached above is safe
    -- to use for another monotonic classification.  Return an explicit
    -- read-only conflict so the caller can poll again from the new state;
    -- execution admission and dispatch remain permanently non-retryable.
    return jsonb_build_object(
      'ok', false,
      'command', 'cmd_dataset_alias_execution_read_v2',
      'schema_version', 'dataset-alias-execution-status.v2',
      'request_id', p_request_id,
      'code', 'ALIAS_EXECUTION_READ_STATE_CHANGED',
      'status', 409,
      'execution_status', v_request.status,
      'retry_allowed', false,
      'read_retry_allowed', true,
      'message', 'Execution state changed during readback; poll status again without redispatching'
    );
  end if;

  v_proof_request_status := v_request.status;
  v_proof_request_updated_at := v_request.updated_at;

  if v_derivative_child_count > 0
    or v_request.status in ('derivatives_pending', 'completed') then
    v_batch_proof_read := true;
    -- The versioned orchestration's own aggregate readback: every chunk through the existing bounded
    -- reader, with exact membership and a terminal proof only when every chunk proves its closure.
    v_batch_proof := util.read_dataset_alias_v2_derivative_chunks(
      v_actor,
      p_request_id,
      v_request.plan_sha256,
      v_preflight.derivative_targets
    );

    select request.*
    into v_request
    from util.dataset_alias_execution_v2_requests as request
    where request.id = p_request_id
      and request.actor_user_id = v_actor;

    if v_request.status is distinct from v_proof_request_status
      or v_request.updated_at is distinct from v_proof_request_updated_at then
      -- The derivative proof can be substantially more expensive than the
      -- parent-ledger read.  A different reader or the executor may classify
      -- the request while that proof is being assembled, so the cached proof
      -- must not be applied to the newly visible parent state.
      return jsonb_build_object(
        'ok', false,
        'command', 'cmd_dataset_alias_execution_read_v2',
        'schema_version', 'dataset-alias-execution-status.v2',
        'request_id', p_request_id,
        'code', 'ALIAS_EXECUTION_READ_STATE_CHANGED',
        'status', 409,
        'execution_status', v_request.status,
        'retry_allowed', false,
        'read_retry_allowed', true,
        'message', 'Execution state changed during readback; poll status again without redispatching'
      );
    end if;
  end if;

  if v_request.status = 'derivatives_pending' then
    if v_alias_audit_count
        is distinct from (v_preflight.plan #>> '{expected,audit_count}')::integer
      or v_derivative_child_count
        is distinct from (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
      or v_derivative_flow_count is distinct from (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'flows'
      )
      or v_derivative_process_count is distinct from (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'processes'
      )
      or not v_primary_closure_ok then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'indeterminate',
        terminal_at = v_now,
        terminal_proof = jsonb_build_object(
          'primary_closure', v_primary_closure,
          'derivative_closure', v_batch_proof
        ),
        last_error = jsonb_build_object(
          'phase', 'readback',
          'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_MISMATCH',
          'alias_audit_count', v_alias_audit_count,
          'derivative_child_count', v_derivative_child_count,
          'primary_closure', v_primary_closure
        ),
        updated_at = v_now
      where id = p_request_id
        and status = 'derivatives_pending';
      get diagnostics v_terminal_update_count = row_count;
      if v_terminal_update_count = 1 then
        v_terminal_update_status := 'indeterminate';
      end if;
    elsif v_batch_proof->>'status' = 'completed'
      and coalesce((v_batch_proof->>'causal_terminal_proof')::boolean, false) then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'completed',
        terminal_at = v_now,
        terminal_proof = jsonb_build_object(
          'primary_closure', v_primary_closure,
          'derivative_closure', v_batch_proof
        ),
        updated_at = v_now
      where id = p_request_id
        and status = 'derivatives_pending';
      get diagnostics v_terminal_update_count = row_count;
      if v_terminal_update_count = 1 then
        v_terminal_update_status := 'completed';
      end if;
    elsif v_batch_proof->>'status' = 'failed' then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'failed',
        terminal_at = v_now,
        terminal_proof = jsonb_build_object(
          'primary_closure', v_primary_closure,
          'derivative_closure', v_batch_proof
        ),
        last_error = jsonb_build_object(
          'phase', 'derivative_readback',
          'code', coalesce(
            v_batch_proof->>'code',
            'ALIAS_EXECUTION_DERIVATIVE_CLOSURE_FAILED'
          )
        ),
        updated_at = v_now
      where id = p_request_id
        and status = 'derivatives_pending';
      get diagnostics v_terminal_update_count = row_count;
      if v_terminal_update_count = 1 then
        v_terminal_update_status := 'failed';
      end if;
    end if;
  end if;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
    and request.actor_user_id = v_actor;

  if v_batch_proof_read
    and (
      v_request.status is distinct from v_proof_request_status
      or v_request.updated_at is distinct from v_proof_request_updated_at
    )
    and not (
      v_terminal_update_count = 1
      and v_request.status is not distinct from v_terminal_update_status
      and v_request.updated_at is not distinct from v_now
    ) then
    -- A conditional terminal update with ROW_COUNT = 1 is this invocation's
    -- own monotonic classification.  Any other parent transition invalidates
    -- the cached derivative proof and must be retried as read-only polling.
    return jsonb_build_object(
      'ok', false,
      'command', 'cmd_dataset_alias_execution_read_v2',
      'schema_version', 'dataset-alias-execution-status.v2',
      'request_id', p_request_id,
      'code', 'ALIAS_EXECUTION_READ_STATE_CHANGED',
      'status', 409,
      'execution_status', v_request.status,
      'retry_allowed', false,
      'read_retry_allowed', true,
      'message', 'Execution state changed during readback; poll status again without redispatching'
    );
  end if;

  end if;

  v_category := case v_request.status
    when 'completed' then 'passed'
    when 'failed' then 'failed'
    when 'indeterminate' then 'indeterminate'
    else 'pending'
  end;

  -- A stored completion is not allowed to hide later live-state drift during
  -- an independent readback.  The immutable ledger remains completed, but the
  -- fresh response fails closed if its current causal proof no longer passes.
  if v_request.status = 'completed'
    and (
      not v_primary_closure_ok
      or v_batch_proof is null
      or v_batch_proof->>'status' is distinct from 'completed'
      or coalesce((v_batch_proof->>'causal_terminal_proof')::boolean, false)
        is not true
    ) then
    v_category := 'failed';
  end if;

  -- The strict terminal proof exists only for a genuinely successful execution whose live primary
  -- closure AND every derivative child causal terminal proof still pass on this read. Everything else —
  -- pending, failed, indeterminate or drifted — reports null, never a fabricated observation.
  if v_category = 'passed'
    and v_request.status = 'completed'
    and v_primary_closure_ok
    and v_batch_proof is not null
    and v_batch_proof->>'status' = 'completed'
    and coalesce((v_batch_proof->>'causal_terminal_proof')::boolean, false) is true
    and coalesce((v_batch_proof->>'membership_exact')::boolean, false) is true then
    v_terminal_proof := case private.dataset_protected_profile(v_preflight.plan)
      when 'alias_v2' then util.read_dataset_alias_execution_v2_terminal_proof(v_actor, v_preflight.plan)
      when 'length_time_v1' then util.read_dataset_length_time_v1_terminal_proof(v_actor, v_preflight.plan)
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_read_v2',
    'schema_version', 'dataset-alias-execution-status.v2',
    'request_id', p_request_id,
    'status', v_category,
    'terminal_proof', v_terminal_proof,
    'execution_status', v_request.status,
    'retry_allowed', false,
    'actor_user_id', v_actor,
    'environment', v_preflight.environment,
    'project_ref', v_preflight.project_ref,
    'target_visibility', v_preflight.target_visibility,
    'plan_sha256', v_request.plan_sha256,
    'operation_id', v_request.operation_id,
    'plan_request_sha256', v_request.plan_request_sha256,
    'freeze_sha256', v_request.freeze_sha256,
    'approval_identity_sha256', v_request.approval_identity_sha256,
    'approval_text_sha256', v_request.approval_text_sha256,
    'derivative_target_set_sha256', v_request.derivative_target_set_sha256,
    'server_derivative_targets_sha256',
      v_preflight.derivative_targets_sha256,
    'preflight_proof_sha256', v_request.preflight_proof_sha256,
    'admission_request_sha256', v_request.admission_request_sha256,
    'gate_results_sha256', v_request.gate_results_sha256,
    'attempt_count', v_request.attempt_count,
    'dispatch_count', v_request.dispatch_count,
    'net_request_id', v_request.net_request_id::text,
    'preflight_completed_at', v_preflight.completed_at,
    'preflight_expires_at', v_preflight.expires_at,
    'preflight_consumed_at', v_preflight.consumed_at,
    'admitted_at', v_request.admitted_at,
    'dispatched_at', v_request.dispatched_at,
    'started_at', v_request.started_at,
    'primary_committed_at', v_request.primary_committed_at,
    'terminal_at', v_request.terminal_at,
    'gate_count', v_gate_count,
    'gates', v_gate_receipts,
    'primary_readback', jsonb_build_object(
      'row_count', case
        when v_alias_audit_count = (select (preflight.plan #>> '{expected,audit_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id) and v_primary_closure_ok then (select (preflight.plan #>> '{expected,action_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id)
        else null
      end,
      'exchange_count', case
        when v_alias_audit_count = (select (preflight.plan #>> '{expected,audit_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id) and v_primary_closure_ok then (select (preflight.plan #>> '{expected,exchange_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id)
        else null
      end,
      'alias_audit_count', v_alias_audit_count,
      'live_closure_proof', v_primary_closure_ok,
      'closure', v_primary_closure
    ),
    'derivative_readback', coalesce(
      v_batch_proof,
      jsonb_build_object(
        'schema_version', 'dataset-derivative-rebuild-batch-status.v1',
        'batch_id', p_request_id,
        'status', 'not_started',
        'code', 'DERIVATIVE_BATCH_NOT_STARTED',
        'proof_level', 'none',
        'proof_deferred', false,
        'target_count', v_derivative_child_count,
        'flow_count', v_derivative_flow_count,
        'process_count', v_derivative_process_count,
        'completed_count', 0,
        'nonterminal_count', 0,
        'failed_count', 0,
        'invalid_proof_count', null,
        'causal_terminal_proof', false,
        'targets', '[]'::jsonb
      )
    ),
    'error', v_request.last_error
  );
exception
  when lock_not_available then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_READ_LOCK_BUSY',
      'status', 'indeterminate',
      'message', 'Protected execution status row is busy; readback did not retry or redispatch'
    );
end;
$$;
alter function api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb) owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb) from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb) to authenticated;
alter function api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text) owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text) to authenticated;
alter function api.cmd_dataset_alias_execution_execute_v2(uuid, text) owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_execute_v2(uuid, text) from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_execute_v2(uuid, text) to service_role;
alter function api.cmd_dataset_alias_execution_read_v2(uuid) owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_read_v2(uuid) from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_read_v2(uuid) to authenticated;
