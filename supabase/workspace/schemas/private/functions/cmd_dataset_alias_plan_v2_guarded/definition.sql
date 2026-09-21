CREATE OR REPLACE FUNCTION "private"."cmd_dataset_alias_plan_v2_guarded"("p_plan" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "lock_timeout" TO '5s'
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_schema_version constant text := 'dataset-alias-plan.v2';
  v_batch_schema_version constant text := 'dataset-alias-batch.v2';
  v_command constant text := 'cmd_dataset_alias_plan_v2_guarded';
  v_plan_sha256 text;
  v_plan_request_sha256 text;
  v_batch_id text;
  v_expected jsonb;
  v_dimension jsonb;
  v_batch jsonb;
  v_batch_result jsonb;
  v_existing_summary jsonb;
  v_summary_id bigint;
  v_replay boolean;
  v_audit_rows bigint;
  v_batch_summary_rows bigint;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED', 'status', 401, 'message', 'Authentication required');
  end if;

  if p_plan is not null and pg_column_size(p_plan) > 67108864 then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 413,
      'message', 'The v2 plan exceeds the 64 MiB database limit');
  end if;

  if not private.dataset_alias_v2_plan_keys_ok(p_plan) then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 400,
      'message', 'Plan request must match dataset-alias-plan.v2 exactly');
  end if;

  if p_plan->>'schema_version' is distinct from v_schema_version
    or (p_plan->>'plan_sha256') !~ '^[a-f0-9]{64}$'
    or (p_plan->>'actor_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or p_plan->>'target_visibility' is distinct from 'owner_draft'
    or jsonb_typeof(p_plan->'source_evidence') is distinct from 'object'
    or jsonb_typeof(p_plan->'target_snapshots') is distinct from 'object'
    or jsonb_typeof(p_plan->'expected') is distinct from 'object'
    or jsonb_typeof(p_plan->'dimensions') is distinct from 'array'
    or jsonb_typeof(p_plan->'text_actions') is distinct from 'array'
    or jsonb_typeof(p_plan->'actions') is distinct from 'array'
    or jsonb_array_length(p_plan->'actions') < 1 then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 400,
      'message', 'Plan identity, actor, owner_draft visibility, source alias, evidence, expected counts, dimension, text actions and action list are required');
  end if;

  if (p_plan->>'actor_id')::uuid is distinct from v_actor then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 403,
      'message', 'The plan is bound to another actor');
  end if;

  -- The ten flat expected keys of the real v1 contract plus the versioned text_action_count; all numeric.
  -- The external producer emits JSON numbers (never quoted decimal strings), so the literal number type
  -- is required here: a quoted count is a different wire shape and is refused rather than coerced.
  if exists (
    select 1 from jsonb_object_keys(p_plan->'expected') as key(name)
    where key.name <> all (array[
      'action_count', 'batch_count', 'exchange_count', 'amount_field_count', 'unrelated_exchange_count',
      'audit_count', 'flowproperty_count', 'flow_count', 'process_count', 'derivative_target_count',
      'text_action_count'
    ])
  ) or (select count(*) from jsonb_object_keys(p_plan->'expected')) <> 11
    or exists (
      select 1 from jsonb_each(p_plan->'expected') as entry(key, value)
      where jsonb_typeof(entry.value) is distinct from 'number'
    )
    or (p_plan #>> '{expected,action_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,batch_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,exchange_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,amount_field_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,unrelated_exchange_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,audit_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,flowproperty_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,flow_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,process_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,derivative_target_count}') !~ '^[0-9]+$'
    or (p_plan #>> '{expected,text_action_count}') !~ '^[0-9]+$' then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 400,
      'message', 'The expected block must carry exactly the ten flat v1 keys, and the versioned text_action_count, all numeric');
  end if;
  v_expected := p_plan->'expected';

  -- Counts the plan declares about itself must hold before anything else runs.
  if (v_expected->>'action_count')::integer is distinct from jsonb_array_length(p_plan->'actions')
    or (v_expected->>'batch_count')::integer is distinct from jsonb_array_length(p_plan->'dimensions') then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 400,
      'message', 'Declared action, batch or text-action counts do not match the plan itself');
  end if;
  if (v_expected->>'text_action_count')::integer is distinct from jsonb_array_length(p_plan->'text_actions') then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 400,
      'message', 'The declared text-action count does not match the text-action block');
  end if;

  -- The external plan's source alias identity and source-evidence semantics.
  if jsonb_typeof(p_plan->'source_alias') is distinct from 'object'
    or coalesce(p_plan #>> '{source_alias,id}', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or coalesce(p_plan #>> '{source_alias,version}', '') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
    or coalesce(p_plan #>> '{source_alias,sha256}', '') !~ '^[a-f0-9]{64}$'
    or jsonb_typeof(p_plan->'source_evidence') is distinct from 'object'
    or coalesce(p_plan #>> '{source_evidence,cohort_sha256}', '') !~ '^[a-f0-9]{64}$'
    or (p_plan #>> '{source_evidence,cohort_sha256}') is distinct from (p_plan #>> '{source_evidence,expected_cohort_sha256}')
    or coalesce(p_plan #>> '{source_evidence,original_source_unit}', '') = ''
    or jsonb_typeof(p_plan #> '{source_evidence,exchange_count}') is distinct from 'number'
    or jsonb_typeof(p_plan->'source_evidence'->'declared_source_unitgroup') is distinct from 'object'
    -- The frozen source flow property snapshot: the complete payload of the alias the plan runs
    -- against, bound by its own canonical digest and named by the same identity the alias digest
    -- binds. The executor compares that digest against the locked row payload.
    or jsonb_typeof(p_plan->'source_evidence'->'source_flowproperty') is distinct from 'object'
    or exists (
      select 1 from jsonb_object_keys(p_plan->'source_evidence'->'source_flowproperty') as key(name)
      where key.name <> all (array['id', 'version', 'sha256'])
    )
    or (select count(*) from jsonb_object_keys(p_plan->'source_evidence'->'source_flowproperty')) <> 3
    or coalesce(p_plan #>> '{source_evidence,source_flowproperty,id}', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or coalesce(p_plan #>> '{source_evidence,source_flowproperty,version}', '') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
    or coalesce(p_plan #>> '{source_evidence,source_flowproperty,sha256}', '') !~ '^[a-f0-9]{64}$'
    or (p_plan #>> '{source_evidence,source_flowproperty,id}') is distinct from (p_plan #>> '{source_alias,id}')
    or (p_plan #>> '{source_evidence,source_flowproperty,version}') is distinct from (p_plan #>> '{source_alias,version}') then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_INVALID', 'status', 400,
      'message', 'The plan must carry its source alias identity, equal declared cohort digests and the declared/original source unit semantics');
  end if;

  -- Exactly one `time` dimension; the factor is the approved constant and both unit-group pointers must be
  -- the ones the evidence blocks bind. Zero flow-property actions are admissible here by construction.
  if jsonb_array_length(p_plan->'dimensions') <> 1 then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_DIMENSION_UNSUPPORTED', 'status', 400,
      'message', 'The v2 plan carries exactly one dimension');
  end if;
  v_dimension := p_plan->'dimensions'->0;
  if v_dimension->>'dimension' is distinct from 'time'
    or v_dimension->>'factor' is distinct from private.dataset_alias_v2_factor()::text
    or (v_dimension #>> '{declared_source_unitgroup,id}') is distinct from (p_plan #>> '{source_evidence,declared_source_unitgroup,id}')
    or (v_dimension #>> '{declared_source_unitgroup,version}') is distinct from (p_plan #>> '{source_evidence,declared_source_unitgroup,version}')
    or (v_dimension #>> '{target_unitgroup,id}') is distinct from (p_plan #>> '{target_snapshots,unitgroup,id}')
    or (v_dimension #>> '{target_unitgroup,version}') is distinct from (p_plan #>> '{target_snapshots,unitgroup,version}') then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_DIMENSION_UNSUPPORTED', 'status', 400,
      'message', 'The single dimension must be time with the approved factor and the evidence unit groups');
  end if;

  -- The external plan carries no derivative-target list: the protected request/freeze owns it, and the
  -- protected adapter separately checks that list against these identities. Here the plan must declare the
  -- exact unique changed Flow/Process identity count, and its action identities must be unique.
  if (select count(distinct (a->>'table') || '|' || (a->>'id') || '|' || (a->>'version'))
        from jsonb_array_elements(p_plan->'actions') as a)
      is distinct from jsonb_array_length(p_plan->'actions')
    or (v_expected->>'derivative_target_count')::integer
      is distinct from jsonb_array_length(p_plan->'actions') then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_COUNT_MISMATCH', 'status', 409,
      'message', 'The declared derivative-target count must be exactly the unique changed action identities');
  end if;

  -- The audit topology the run must actually write: one row audit per action, one batch summary per batch
  -- and one plan summary. The declaration is only accepted when it equals that topology.
  if (v_expected->>'audit_count')::integer
      is distinct from (v_expected->>'action_count')::integer
        + (v_expected->>'batch_count')::integer + 1 then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_COUNT_MISMATCH', 'status', 409,
      'message', 'The declared audit count is not one row audit per action plus one summary per batch plus the plan summary');
  end if;

  v_plan_sha256 := p_plan->>'plan_sha256';
  v_plan_request_sha256 := encode(extensions.digest(convert_to(p_plan::text, 'UTF8'), 'sha256'), 'hex');
  v_batch_id := 'time:' || v_plan_sha256;

  -- The claimed plan digest must be the canonical hash of the submitted plan document minus its own
  -- `plan_sha256` binding, exactly as the producer computes it. This is checked before the replay lookup
  -- below, so a changed request body that reuses an applied plan label refuses instead of returning a
  -- stored proof for a plan it is not.
  if util.dataset_alias_execution_v2_artifact_sha256(p_plan - 'plan_sha256')
      is distinct from v_plan_sha256 then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_DIGEST_MISMATCH', 'status', 409,
      'message', 'The declared plan digest is not the canonical hash of this plan document');
  end if;

  -- The batch the plan executes is assembled here from the plan's own blocks; it is never accepted from a
  -- caller, so a plan and its batch cannot disagree about identity, evidence or counts.
  v_batch := jsonb_build_object(
    'schema_version', v_batch_schema_version,
    'batch_id', v_batch_id,
    'plan_sha256', v_plan_sha256,
    'dimension', 'time',
    'factor', v_dimension->>'factor',
    'target_visibility', 'owner_draft',
    'target_snapshots', p_plan->'target_snapshots',
    'source_evidence', jsonb_build_object(
      'sha256', p_plan #>> '{source_evidence,sha256}',
      'exchange_count', p_plan #> '{source_evidence,exchange_count}',
      'source_unitgroup', p_plan#>'{source_evidence,declared_source_unitgroup}',
      'source_flowproperty', p_plan#>'{source_evidence,source_flowproperty}'),
    'source_alias', p_plan->'source_alias',
    'counts', jsonb_build_object(
      'action_count', v_expected->>'action_count',
      'flow_count', v_expected->>'flow_count',
      'process_count', v_expected->>'process_count',
      'exchange_count', v_expected->>'exchange_count',
      'amount_field_count', v_expected->>'amount_field_count',
      'unrelated_exchange_count', v_expected->>'unrelated_exchange_count',
      'flowproperty_count', v_expected->>'flowproperty_count'),
    'text_actions', p_plan->'text_actions',
    'actions', p_plan->'actions');

  v_batch_result := private.cmd_dataset_alias_batch_v2_guarded(v_batch);
  if coalesce((v_batch_result->>'ok')::boolean, false) is not true then
    -- The batch refusal is the plan refusal: its stable code, status and details pass through unchanged.
    return v_batch_result;
  end if;

  v_replay := coalesce((v_batch_result->>'idempotent_replay')::boolean, false);
  if v_batch_result->>'plan_sha256' is distinct from v_plan_sha256
    or v_batch_result->>'batch_id' is distinct from v_batch_id
    or (v_batch_result #>> '{counts,action_count}')::integer is distinct from (v_expected->>'action_count')::integer
    or (v_batch_result #>> '{counts,flow_count}')::integer is distinct from (v_expected->>'flow_count')::integer
    or (v_batch_result #>> '{counts,process_count}')::integer is distinct from (v_expected->>'process_count')::integer
    or (v_batch_result #>> '{counts,exchange_count}')::integer is distinct from (v_expected->>'exchange_count')::integer
    or (v_batch_result #>> '{counts,amount_field_count}')::integer is distinct from (v_expected->>'amount_field_count')::integer
    or (v_batch_result #>> '{counts,unrelated_exchange_count}')::integer is distinct from (v_expected->>'unrelated_exchange_count')::integer
    or (v_batch_result #>> '{counts,text_action_count}')::integer is distinct from (v_expected->>'text_action_count')::integer then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_PROOF_MISMATCH', 'status', 409,
      'message', 'The batch result does not prove the exact plan identity and counts',
      'details', jsonb_build_object('batch_result', v_batch_result));
  end if;

  -- The declared audit count must be the topology the rows actually have: the batch's per-action row
  -- audits and batch summary are counted from the ledger, not trusted from the response.
  select count(*) into v_audit_rows
  from private.command_audit_log as audit_log
  where audit_log.command = 'cmd_dataset_alias_batch_v2_guarded'
    and audit_log.actor_user_id = v_actor
    and audit_log.payload->>'plan_sha256' = v_plan_sha256
    and audit_log.payload->>'record_type' = 'row';
  select count(*) into v_batch_summary_rows
  from private.command_audit_log as audit_log
  where audit_log.command = 'cmd_dataset_alias_batch_v2_guarded'
    and audit_log.actor_user_id = v_actor
    and audit_log.payload->>'plan_sha256' = v_plan_sha256
    and audit_log.payload->>'record_type' = 'plan';
  if v_audit_rows is distinct from (v_expected->>'action_count')::bigint
    or v_batch_summary_rows is distinct from (v_expected->>'batch_count')::bigint then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_PROOF_MISMATCH', 'status', 409,
      'message', 'The alias audit topology in the ledger is not one row audit per action plus one batch summary',
      'details', jsonb_build_object('row_audits', v_audit_rows, 'batch_summaries', v_batch_summary_rows));
  end if;

  select audit_log.payload into v_existing_summary
  from private.command_audit_log as audit_log
  where audit_log.command = v_command
    and audit_log.actor_user_id = v_actor
    and audit_log.payload->>'record_type' = 'plan_summary'
    and audit_log.payload->>'plan_request_sha256' = v_plan_request_sha256
  order by audit_log.id desc limit 1;

  if v_existing_summary is not null then
    if not v_replay then
      -- The batch was fresh but the whole-plan proof already exists: the two ledgers disagree.
      return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_REPLAY_CONFLICT', 'status', 409,
        'message', 'A fresh batch result cannot follow an existing plan summary');
    end if;
    if v_existing_summary->'expected' is distinct from v_expected then
      return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_REPLAY_CONFLICT', 'status', 409,
        'message', 'The resubmission diverges from the stored plan summary');
    end if;
    return jsonb_build_object('ok', true, 'code', 'ALIAS_V2_PLAN_REPLAYED', 'status', 200,
      'idempotent_replay', true, 'plan_sha256', v_plan_sha256, 'operation_id', v_plan_sha256,
      'plan_request_sha256', v_plan_request_sha256,
      'batch_id', v_batch_id, 'counts', v_existing_summary->'counts', 'audit_count', v_audit_rows + v_batch_summary_rows + 1,
      'audit', jsonb_build_object('batch_result', v_batch_result));
  end if;

  if v_replay then
    -- The rows are already applied but the whole-plan proof is missing: refuse rather than mint it.
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_PLAN_PROOF_MISMATCH', 'status', 409,
      'message', 'An applied batch without its plan summary cannot be re-attested by a resubmission');
  end if;

  insert into private.command_audit_log (command, actor_user_id, target_table, payload)
  values (v_command, v_actor, 'flows', jsonb_build_object(
    'record_type', 'plan_summary', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
    'plan_request_sha256', v_plan_request_sha256, 'batch_id', v_batch_id, 'dimension', 'time',
    'factor', v_dimension->>'factor', 'target_visibility', 'owner_draft',
    'expected', v_expected, 'text_action_count', (v_expected->>'text_action_count')::integer,
    'audit_count', (v_expected->>'audit_count')::integer,
    'derivative_target_count', (v_expected->>'derivative_target_count')::integer,
    'source_evidence', jsonb_build_object(
      'sha256', p_plan #>> '{source_evidence,sha256}',
      'exchange_count', p_plan #> '{source_evidence,exchange_count}',
      'source_unitgroup', p_plan#>'{source_evidence,declared_source_unitgroup}',
      'source_flowproperty', p_plan#>'{source_evidence,source_flowproperty}'),
    'source_alias', p_plan->'source_alias', 'target_snapshots', p_plan->'target_snapshots',
    'counts', jsonb_build_object(
      'action_count', v_expected->>'action_count', 'flow_count', v_expected->>'flow_count',
      'process_count', v_expected->>'process_count', 'exchange_count', v_expected->>'exchange_count',
      'amount_field_count', v_expected->>'amount_field_count',
      'unrelated_exchange_count', v_expected->>'unrelated_exchange_count',
      'text_action_count', (v_expected->>'text_action_count')::integer)))
  returning id into v_summary_id;

  return jsonb_build_object('ok', true, 'code', 'ALIAS_V2_PLAN_APPLIED', 'status', 200,
    'idempotent_replay', false, 'plan_sha256', v_plan_sha256, 'operation_id', v_plan_sha256,
    'plan_request_sha256', v_plan_request_sha256,
    'batch_id', v_batch_id,
    'counts', jsonb_build_object(
      'action_count', v_expected->>'action_count', 'flow_count', v_expected->>'flow_count',
      'process_count', v_expected->>'process_count', 'exchange_count', v_expected->>'exchange_count',
      'amount_field_count', v_expected->>'amount_field_count',
      'unrelated_exchange_count', v_expected->>'unrelated_exchange_count',
      'text_action_count', (v_expected->>'text_action_count')::integer),
    'audit_count', v_audit_rows + v_batch_summary_rows + 1,
    'audit', jsonb_build_object('plan_summary_id', v_summary_id, 'batch_result', v_batch_result));
end
$_$;

ALTER FUNCTION "private"."cmd_dataset_alias_plan_v2_guarded"("p_plan" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."cmd_dataset_alias_plan_v2_guarded"("p_plan" "jsonb") FROM PUBLIC;
