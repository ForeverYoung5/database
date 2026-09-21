-- Foundry #60 / Database #673 — v2 guarded batch executor for the current source-hour Time repair.
--
-- Scope: one `time` dimension, 0 flow-property actions, 387 actual Flow/Process actions, server-derived
-- desired payloads (claims are verified, never trusted), full-before JSON CAS on the locked row, global
-- incoming closure with the unit groups inside the same lock boundary, ordinary audit rows with an
-- idempotent replay proof. v1 functions, constants and audit identities are untouched.
--
-- Derivation rules (agreement §A6b, CLI B1):
--   * flows  — only `flowDataSet.flowProperties.flowProperty[<@dataSetInternalID="1">]
--              .referenceToFlowPropertyDataSet` (refObjectId/version/uri/shortDescription) moves to the
--              target snapshot; `flowInformation.quantitativeReference.referenceToReferenceFlowProperty`
--              is an internal pointer and stays byte-identical.
--   * processes — only the exchange amount leaves named in `mutation.exchanges[]` (meanAmount,
--              resultingAmount, both from the original stored literal by exact numeric multiplication)
--              and, for the 87 affected reference processes, the functional-unit `#text` unit token.

-- ---------------------------------------------------------------------------------------------------
-- Flow property reference replacement (object or single-entry array shape both supported).
create or replace function private.dataset_alias_v2_replace_flow_reference(
  p_before jsonb,
  p_reference jsonb
) returns jsonb
language plpgsql
immutable
as $$
declare
  v_entry jsonb;
  v_replaced jsonb;
begin
  v_entry := p_before #> '{flowDataSet,flowProperties,flowProperty}';
  if v_entry is null or p_reference is null then
    return null;
  end if;
  if jsonb_typeof(v_entry) = 'array' then
    if jsonb_array_length(v_entry) <> 1
      or coalesce(v_entry->0->>'@dataSetInternalID', '') <> '1' then
      return null;
    end if;
    return jsonb_set(
      p_before,
      '{flowDataSet,flowProperties,flowProperty,0,referenceToFlowPropertyDataSet}',
      p_reference,
      false
    );
  end if;
  if jsonb_typeof(v_entry) <> 'object' or coalesce(v_entry->>'@dataSetInternalID', '') <> '1' then
    return null;
  end if;
  v_replaced := jsonb_set(
    p_before,
    '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet}',
    p_reference,
    false
  );
  return v_replaced;
end
$$;

alter function private.dataset_alias_v2_replace_flow_reference(jsonb, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_replace_flow_reference(jsonb, jsonb) from public;
comment on function private.dataset_alias_v2_replace_flow_reference(jsonb, jsonb) is
  'Derives a v2 flow payload: only the internal-ID-1 property entry reference moves; the quantitative-reference pointer never does.';

-- ---------------------------------------------------------------------------------------------------
-- Exchange amount replacement: both reviewed amount leaves move by the fixed factor, from the stored
-- literal, and every other exchange byte survives.
create or replace function private.dataset_alias_v2_replace_exchange_amounts(
  p_before jsonb,
  p_exchange jsonb
) returns jsonb
language plpgsql
immutable
as $$
declare
  v_index integer := coalesce((p_exchange->>'index')::integer, -1);
  v_internal_id text := p_exchange->>'internal_id';
  v_flow_id text := p_exchange->>'flow_id';
  v_flow_version text := p_exchange->>'flow_version';
  v_direction text := p_exchange->>'direction';
  v_before_amount text := p_exchange->>'before_amount';
  v_after_amount text := p_exchange->>'after_amount';
  v_exchanges jsonb := p_before #> '{processDataSet,exchanges,exchange}';
  v_entry jsonb;
  v_after text;
begin
  if v_index < 0
    or jsonb_typeof(v_exchanges) <> 'array'
    or v_index >= jsonb_array_length(v_exchanges) then
    return null;
  end if;
  v_entry := v_exchanges->v_index;
  if jsonb_typeof(v_entry) <> 'object'
    or coalesce(v_entry->>'@dataSetInternalID', '') <> v_internal_id
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@refObjectId', '') <> v_flow_id
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@version', '') <> v_flow_version
    or coalesce(v_entry->>'exchangeDirection', '') <> v_direction then
    return null;
  end if;
  -- The stored literal is the authority; the claim must reproduce it exactly as a number.
  if v_entry->>'meanAmount' is distinct from v_before_amount
    or v_entry->>'resultingAmount' is distinct from v_before_amount then
    if (v_entry->>'meanAmount')::numeric is distinct from v_before_amount::numeric
      or (v_entry->>'resultingAmount')::numeric is distinct from v_before_amount::numeric then
      return null;
    end if;
  end if;
  v_after := private.dataset_alias_v2_multiply_amount(v_before_amount, private.dataset_alias_v2_factor()::text);
  if v_after is null or v_after is distinct from v_after_amount then
    return null;
  end if;
  return jsonb_set(
    jsonb_set(
      p_before,
      array['processDataSet', 'exchanges', 'exchange', v_index::text, 'meanAmount'],
      to_jsonb(v_after),
      false
    ),
    array['processDataSet', 'exchanges', 'exchange', v_index::text, 'resultingAmount'],
    to_jsonb(v_after),
    false
  );
end
$$;

alter function private.dataset_alias_v2_replace_exchange_amounts(jsonb, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_replace_exchange_amounts(jsonb, jsonb) from public;
comment on function private.dataset_alias_v2_replace_exchange_amounts(jsonb, jsonb) is
  'Derives one v2 process exchange: both amount leaves move by the fixed factor, identity and every other byte survive.';

-- ---------------------------------------------------------------------------------------------------
-- Functional-unit text: only the unit token after the leading source-proven quantity may move.
create or replace function private.dataset_alias_v2_fu_apply_rule(p_before_text text)
returns text
language sql
immutable
as $$
  select case
    when p_before_text is null then null
    when p_before_text ~ '^(1|1\.0) a([^A-Za-z].*|)$' then regexp_replace(p_before_text, '^(1|1\.0) a', '\1 hr', '')
    else null
  end
$$;

alter function private.dataset_alias_v2_fu_apply_rule(text) owner to postgres;
revoke all on function private.dataset_alias_v2_fu_apply_rule(text) from public;
comment on function private.dataset_alias_v2_fu_apply_rule(text) is
  'Anchored FU rule: only `1 a`/`1.0 a` become `1 hr`/`1.0 hr` with every other byte preserved.';

create or replace function private.dataset_alias_v2_replace_fu_text(
  p_before jsonb,
  p_functional_unit jsonb
) returns jsonb
language plpgsql
immutable
as $$
declare
  v_path text[] := string_to_array(coalesce(p_functional_unit->>'path', ''), '.');
  v_before_text text := p_functional_unit->>'before_text';
  v_after_text text := p_functional_unit->>'after_text';
  v_stored text := p_before #> v_path;
  v_derived text;
begin
  if array_length(v_path, 1) is null or v_before_text is null or v_after_text is null then
    return null;
  end if;
  if jsonb_typeof(p_before #> v_path) <> 'string' or (p_before #>> v_path) is distinct from v_before_text then
    return null;
  end if;
  v_derived := private.dataset_alias_v2_fu_apply_rule(v_before_text);
  if v_derived is null or v_derived is distinct from v_after_text then
    return null;
  end if;
  return jsonb_set(p_before, v_path, to_jsonb(v_derived), false);
end
$$;

alter function private.dataset_alias_v2_replace_fu_text(jsonb, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_replace_fu_text(jsonb, jsonb) from public;
comment on function private.dataset_alias_v2_replace_fu_text(jsonb, jsonb) is
  'Derives the FU text leaf strictly inside the reviewed anchored rule; any other text is refused.';

-- ---------------------------------------------------------------------------------------------------
-- The guarded executor. Returns the v1-style envelope; every refusal writes nothing.
create or replace function private.cmd_dataset_alias_batch_v2_guarded(p_batch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  v_actor uuid := auth.uid();
  v_schema_version constant text := 'dataset-alias-batch.v2';
  v_plan_schema constant text := 'dataset-alias-plan.v2';
  v_command constant text := 'cmd_dataset_alias_batch_v2_guarded';
  v_batch_id text;
  v_operation_id text;
  v_plan_sha256 text;
  v_factor text;
  v_target_visibility text;
  v_actions jsonb;
  v_action_count integer;
  v_action jsonb;
  v_table text;
  v_action_uuid uuid;
  v_action_version text;
  v_action_id text;
  v_expected_state_code integer;
  v_expected_modified_at timestamptz;
  v_expected_json_ordered jsonb;
  v_desired_claim jsonb;
  v_mutation jsonb;
  v_exchanges jsonb;
  v_derived jsonb;
  v_entry jsonb;
  v_reference jsonb;
  v_actual_state_code integer;
  v_actual_modified_at timestamptz;
  v_actual_json_ordered jsonb;
  v_fresh_count integer := 0;
  v_replay_count integer := 0;
  v_audit_rows jsonb := '[]'::jsonb;
  v_prior_audit_id bigint;
  v_committed_modified_at timestamptz;
  v_committed_json_ordered jsonb;
  v_committed_version text;
  v_flow_count integer;
  v_process_count integer;
  v_exchange_count integer;
  v_unrelated_count integer;
  v_foreign_count integer;
  v_summary_audit_id bigint;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED', 'status', 401,
      'message', 'Authentication required');
  end if;
  if jsonb_typeof(p_batch) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_BATCH_INVALID', 'status', 400,
      'message', 'The v2 batch must be one JSON object');
  end if;
  if p_batch->>'schema_version' is distinct from v_schema_version
    or p_batch->>'dimension' is distinct from 'time'
    or p_batch->>'target_visibility' is distinct from 'owner_draft'
    or p_batch->>'factor' is distinct from private.dataset_alias_v2_factor()::text
    or (p_batch->>'plan_sha256') !~ '^[a-f0-9]{64}$'
    or nullif(btrim(p_batch->>'batch_id'), '') is null
    or nullif(btrim(p_batch->>'operation_id'), '') is null
    or jsonb_typeof(p_batch->'actions') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_BATCH_INVALID', 'status', 400,
      'message', 'Batch envelope, dimension, factor, plan identity or action list is invalid');
  end if;
  v_batch_id := btrim(p_batch->>'batch_id');
  v_operation_id := btrim(p_batch->>'operation_id');
  v_plan_sha256 := p_batch->>'plan_sha256';
  v_factor := p_batch->>'factor';
  v_target_visibility := p_batch->>'target_visibility';
  v_actions := p_batch->'actions';
  v_action_count := jsonb_array_length(v_actions);
  if v_action_count < 1 or v_action_count > 4096 then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_BATCH_INVALID', 'status', 400,
      'message', 'A v2 batch carries between one and 4096 actions');
  end if;
  v_reference := p_batch #> '{target_snapshots,flowproperty,reference}';
  -- Shape and identity of every action before anything is locked or counted.
  declare
    v_seen_ids text[] := array[]::text[];
    v_seen_targets text[] := array[]::text[];
  begin
    for v_action in select * from jsonb_array_elements(v_actions)
    loop
      v_action_id := v_action->>'action_id';
      v_table := v_action->>'table';
      if v_action_id is null or v_table not in ('flows', 'processes')
        or (v_action->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or (v_action->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
        or (v_action->>'expected_state_code')::integer is distinct from 0
        or jsonb_typeof(v_action->'expected_json_ordered') is distinct from 'object'
        or jsonb_typeof(v_action->'mutation') is distinct from 'object' then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_BATCH_INVALID', 'status', 400,
          'message', 'Action identity, table, state, before payload or mutation is invalid',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
      if v_action_id = any (v_seen_ids) or (v_table || ':' || (v_action->>'id') || ':' || (v_action->>'version')) = any (v_seen_targets) then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_BATCH_INVALID', 'status', 400,
          'message', 'Actions and targets must be unique',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
      v_seen_ids := v_seen_ids || v_action_id;
      v_seen_targets := v_seen_targets || (v_table || ':' || (v_action->>'id') || ':' || (v_action->>'version'));
      if v_table = 'flows'
        and (v_reference is null
          or coalesce((v_action->'mutation'->>'reference_id'), '') <> coalesce(v_reference->>'@refObjectId', '')
          or coalesce((v_action->'mutation'->>'reference_version'), '') <> coalesce(v_reference->>'@version', '')) then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_BATCH_INVALID', 'status', 400,
          'message', 'A flow action must claim the exact target flow-property reference',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
      if v_table = 'processes' and jsonb_typeof(v_action->'mutation'->'exchanges') is distinct from 'array' then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_BATCH_INVALID', 'status', 400,
          'message', 'A process action must name its exchange instances',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
    end loop;
  end;

  -- Locks: the unit groups are inside the boundary so no concurrent factor or snapshot change can race.
  lock table public.flowproperties, public.unitgroups, public.flows, public.processes
    in share row exclusive mode;

  -- Global incoming closure, recomputed under the lock from the live rows.
  select count(*) into v_flow_count
  from public.flows
  where state_code = 0 and json_ordered::jsonb in (
    select a->'expected_json_ordered' from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows'
  );
  select count(*) into v_process_count
  from public.processes
  where state_code = 0 and json_ordered::jsonb in (
    select a->'expected_json_ordered' from jsonb_array_elements(v_actions) as a where a->>'table' = 'processes'
  );
  select coalesce(count(*) filter (where jsonb_typeof(exchange.value) = 'object'), 0) into v_exchange_count
  from public.processes p
  cross join lateral jsonb_array_elements(coalesce(p.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) as exchange
  where p.state_code = 0
    and exchange.value->'referenceToFlowDataSet'->>'@refObjectId' in (
      select a->'expected_json_ordered'#>'{flowDataSet,flowInformation,dataSetInformation,common:UUID}'
      from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows'
    );
  select count(*) into v_unrelated_count
  from public.processes p
  cross join lateral jsonb_array_elements(coalesce(p.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) as exchange
  where p.state_code = 0
    and exchange.value->'referenceToFlowDataSet'->>'@refObjectId' in (
      select a->'expected_json_ordered'#>'{flowDataSet,flowInformation,dataSetInformation,common:UUID}'
      from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows'
    )
    and not exists (
      select 1 from jsonb_array_elements(v_actions) as a
      where a->>'table' = 'processes'
        and a->'expected_json_ordered'#>'{processDataSet,processInformation,dataSetInformation,common:UUID}' = to_jsonb(p.id::text)
        and a->'expected_json_ordered'#>'{processDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}' = to_jsonb(p.version::text)
    );
  select count(*) into v_foreign_count
  from public.flows f
  where f.state_code = 0
    and f.user_id <> v_actor
    and f.json_ordered::jsonb in (
      select a->'expected_json_ordered' from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows'
    );
  if v_flow_count <> (select count(*) from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows')
    or v_process_count <> (select count(*) from jsonb_array_elements(v_actions) as a where a->>'table' = 'processes')
    or v_foreign_count <> 0 then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_CLOSURE_MISMATCH', 'status', 409,
      'message', 'The live owner-visible closure does not equal the batch target set',
      'details', jsonb_build_object('live_flows', v_flow_count, 'live_processes', v_process_count,
        'foreign_like', v_foreign_count));
  end if;
  if p_batch->>'counts' is not null then
    declare
      v_counts jsonb := p_batch->'counts';
    begin
      if (v_counts->>'action_count')::integer is distinct from v_action_count
        or (v_counts->>'flow_count')::integer is distinct from v_flow_count
        or (v_counts->>'process_count')::integer is distinct from v_process_count
        or (v_counts->>'exchange_count')::integer is distinct from v_exchange_count
        or (v_counts->>'unrelated_exchange_count')::integer is distinct from v_unrelated_count then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_COUNT_MISMATCH', 'status', 409,
          'message', 'Derived live counts differ from the submitted plan counts',
          'details', jsonb_build_object('actions', v_action_count, 'flows', v_flow_count,
            'processes', v_process_count, 'exchanges', v_exchange_count, 'unrelated', v_unrelated_count));
      end if;
    end;
  end if;

  -- Per action: CAS on the complete before payload, server-side derivation, ordinary guarded update.
  for v_action in select * from jsonb_array_elements(v_actions)
  loop
    v_action_id := v_action->>'action_id';
    v_table := v_action->>'table';
    v_action_uuid := (v_action->>'id')::uuid;
    v_action_version := v_action->>'version';
    v_expected_state_code := (v_action->>'expected_state_code')::integer;
    v_expected_modified_at := (v_action->>'expected_modified_at')::timestamptz;
    v_expected_json_ordered := v_action->'expected_json_ordered';
    v_desired_claim := v_action->'desired_json_ordered';
    v_mutation := v_action->'mutation';
    execute format(
      'select state_code, modified_at, json_ordered::jsonb from public.%I where id = $1 and version = $2',
      v_table
    ) into v_actual_state_code, v_actual_modified_at, v_actual_json_ordered using v_action_uuid, v_action_version;
    select audit_log.id into v_prior_audit_id
    from public.command_audit_log as audit_log
    where audit_log.command = v_command
      and audit_log.actor_user_id = v_actor
      and audit_log.target_table = v_table
      and audit_log.target_id = v_action_uuid
      and audit_log.target_version = v_action_version
      and audit_log.payload->>'record_type' = 'row'
      and audit_log.payload->>'schema_version' = v_schema_version
      and audit_log.payload->>'plan_sha256' = v_plan_sha256
      and audit_log.payload->>'action_id' = v_action_id
    order by audit_log.id desc
    limit 1;

    if v_actual_state_code is not distinct from v_expected_state_code
      and v_actual_modified_at is not distinct from v_expected_modified_at
      and v_actual_json_ordered is not distinct from v_expected_json_ordered then
      if v_prior_audit_id is not null then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_ACTION_DRIFT', 'status', 409,
          'message', 'A committed audit exists while the row is still at its before state',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
      -- Derive the desired payload server-side, then require the claim to match it exactly.
      if v_table = 'flows' then
        v_derived := private.dataset_alias_v2_replace_flow_reference(v_expected_json_ordered, v_reference);
      else
        v_derived := v_expected_json_ordered;
        for v_entry in select * from jsonb_array_elements(coalesce(v_mutation->'exchanges', '[]'::jsonb))
        loop
          v_derived := private.dataset_alias_v2_replace_exchange_amounts(v_derived, v_entry);
          if v_derived is null then
            return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_DERIVE_MISMATCH', 'status', 409,
              'message', 'An exchange instance does not bind the stored row',
              'details', jsonb_build_object('action_id', v_action_id, 'entry', v_entry));
          end if;
        end loop;
        if v_mutation ? 'functional_unit' then
          v_derived := private.dataset_alias_v2_replace_fu_text(v_derived, v_mutation->'functional_unit');
          if v_derived is null then
            return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_TEXT_RULE_VIOLATION', 'status', 400,
              'message', 'The functional-unit text does not follow the reviewed anchored rule',
              'details', jsonb_build_object('action_id', v_action_id));
          end if;
        end if;
      end if;
      if v_derived is null or v_derived is not distinct from v_expected_json_ordered then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_DERIVE_MISMATCH', 'status', 409,
          'message', 'The derivation produced no real change for this action',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
      if v_desired_claim is not null and v_desired_claim is distinct from v_derived then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_DERIVE_MISMATCH', 'status', 409,
          'message', 'The claimed desired payload differs from the server derivation',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
      v_committed_modified_at := null;
      v_committed_json_ordered := null;
      v_committed_version := null;
      execute format(
        'update public.%I as t
            set json_ordered = $1::json,
                modified_at = now()
          where t.id = $2
            and t.version = $3
            and t.user_id = $4
            and t.state_code = $5
            and t.modified_at is not distinct from $6
            and t.json_ordered::jsonb is not distinct from $7
        returning t.modified_at, t.json_ordered::jsonb, t.version::text',
        v_table
      ) into v_committed_modified_at, v_committed_json_ordered, v_committed_version
        using v_derived, v_action_uuid, v_action_version, v_actor, v_expected_state_code,
          v_expected_modified_at, v_expected_json_ordered;
      if v_committed_modified_at is null
        or v_committed_json_ordered is distinct from v_derived
        or v_committed_version is distinct from v_action_version then
        return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_ACTION_DRIFT', 'status', 409,
          'message', 'The guarded update lost its precondition',
          'details', jsonb_build_object('action_id', v_action_id));
      end if;
      insert into public.command_audit_log (
        command, actor_user_id, target_table, target_id, target_version, payload
      ) values (
        v_command, v_actor, v_table, v_action_uuid, v_action_version,
        jsonb_build_object(
          'record_type', 'row',
          'schema_version', v_schema_version,
          'plan_sha256', v_plan_sha256,
          'operation_id', v_operation_id,
          'batch_id', v_batch_id,
          'dimension', 'time',
          'factor', v_factor,
          'target_visibility', v_target_visibility,
          'action_id', v_action_id,
          'expected_state_code', v_expected_state_code,
          'expected_modified_at', to_jsonb(v_expected_modified_at),
          'committed_modified_at', to_jsonb(v_committed_modified_at),
          'before_sha256', encode(extensions.digest(convert_to(v_expected_json_ordered::text, 'UTF8'), 'sha256'), 'hex'),
          'after_sha256', encode(extensions.digest(convert_to(v_derived::text, 'UTF8'), 'sha256'), 'hex'),
          'hash_algorithm', 'postgres-jsonb-text-sha256'
        )
      ) returning id into v_prior_audit_id;
      v_fresh_count := v_fresh_count + 1;
      v_audit_rows := v_audit_rows || jsonb_build_array(jsonb_build_object(
        'action_id', v_action_id, 'table', v_table, 'id', v_action_uuid, 'version', v_action_version,
        'audit_id', v_prior_audit_id::text, 'after_sha256', encode(extensions.digest(convert_to(v_derived::text, 'UTF8'), 'sha256'), 'hex')
      ));
    elsif v_actual_state_code is not distinct from v_expected_state_code
      and v_prior_audit_id is not null
      and v_actual_json_ordered = (v_action->'desired_json_ordered') then
      v_replay_count := v_replay_count + 1;
      v_audit_rows := v_audit_rows || jsonb_build_array(jsonb_build_object(
        'action_id', v_action_id, 'table', v_table, 'id', v_action_uuid, 'version', v_action_version,
        'audit_id', v_prior_audit_id::text, 'replayed', true
      ));
    else
      return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_ACTION_DRIFT', 'status', 409,
        'message', 'An action no longer matches its frozen before content, owner, state or version',
        'details', jsonb_build_object('action_id', v_action_id));
    end if;
  end loop;

  insert into public.command_audit_log (
    command, actor_user_id, target_table, target_id, target_version, payload
  ) values (
    v_command, v_actor, 'flows', null, null,
    jsonb_build_object(
      'record_type', 'batch',
      'schema_version', v_schema_version,
      'plan_sha256', v_plan_sha256,
      'operation_id', v_operation_id,
      'batch_id', v_batch_id,
      'dimension', 'time',
      'factor', v_factor,
      'action_count', v_action_count,
      'fresh_actions', v_fresh_count,
      'replayed_actions', v_replay_count,
      'live_flows', v_flow_count,
      'live_processes', v_process_count,
      'live_exchanges', v_exchange_count,
      'unrelated_exchanges', v_unrelated_count
    )
  ) returning id into v_summary_audit_id;

  return jsonb_build_object(
    'ok', true,
    'code', 'ALIAS_V2_BATCH_APPLIED',
    'status', 200,
    'idempotent_replay', v_replay_count = v_action_count,
    'plan_sha256', v_plan_sha256,
    'batch_id', v_batch_id,
    'counts', jsonb_build_object(
      'action_count', v_action_count,
      'flow_count', v_flow_count,
      'process_count', v_process_count,
      'exchange_count', v_exchange_count,
      'unrelated_exchange_count', v_unrelated_count
    ),
    'audit', jsonb_build_object('batch_summary_id', v_summary_audit_id, 'rows', v_audit_rows)
  );
exception
  when lock_not_available then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_LOCK_TIMEOUT', 'status', 409,
      'message', 'The v2 lock window could not be acquired; nothing was written');
end
$$;

alter function private.cmd_dataset_alias_batch_v2_guarded(jsonb) owner to postgres;
revoke all on function private.cmd_dataset_alias_batch_v2_guarded(jsonb) from public;
comment on function private.cmd_dataset_alias_batch_v2_guarded(jsonb) is
  'Versioned guarded v2 batch executor: single time dimension, server-derived desired payloads, full-before CAS, locked global closure, ordinary audit and idempotent replay. v1 is untouched.';
