-- Foundry #60 / Database #673 — v2 guarded batch executor for the current source-hour Time repair.
--
-- Rewritten per root's line review of addabc6 (`/tmp/database673-batch-root-review.md`). The executor is
-- all-or-none by construction: a read-only validation and derivation pass runs over every action first, and
-- the write pass raises on any post-write refusal, with one enclosing exception block that turns the raise
-- into the stable envelope. A `return` never leaves a partial write behind.
--
-- Closure is a real reference closure, not a payload membership test: the alias flow property is identified
-- from the frozen before payloads, every live referrer (Flow, any owner, any state) and every Process
-- exchange occurrence of those exact flow id/version pairs is discovered under the locks, and the exact
-- sets — not counts — must equal what the batch carries. `unrelated_exchange_count` is the complement
-- inside the selected Processes.
--
-- Derivation (agreement §A6b, CLI B1): flows move only the internal-ID-1 property entry's
-- `referenceToFlowPropertyDataSet`, recomputed from the locked target Flow property row; processes move only
-- the reviewed amount leaves of the named exchange instances (original stored literal, exact numeric) and,
-- for the affected reference processes, the exact functional-unit text leaf. The internal pointer
-- `flowInformation.quantitativeReference.referenceToReferenceFlowProperty` never moves, and no arbitrary
-- dotted path may target other text.

create or replace function private.dataset_alias_v2_error(p_code text, p_status integer, p_message text, p_details jsonb default '{}'::jsonb)
returns text
language sql
immutable
as $$
  select jsonb_build_object('code', p_code, 'status', p_status, 'message', p_message,
    'details', coalesce(p_details, '{}'::jsonb))::text
$$;

create or replace function private.dataset_alias_v2_deny(p_code text, p_status integer, p_message text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = p_code,
    detail = p_message,
    hint = jsonb_build_object('status', p_status, 'details', coalesce(p_details, '{}'::jsonb))::text;
end
$$;

alter function private.dataset_alias_v2_error(text, integer, text, jsonb) owner to postgres;
alter function private.dataset_alias_v2_deny(text, integer, text, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_error(text, integer, text, jsonb) from public;
revoke all on function private.dataset_alias_v2_deny(text, integer, text, jsonb) from public;

-- The reviewed absolute amount leaves and the closed exchange key set of the current cohort.
create or replace function private.dataset_alias_v2_exchange_keys_ok(p_exchange jsonb)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(p_exchange) = 'object'
    and not exists (
      select 1
      from jsonb_object_keys(p_exchange) as key(name)
      where key.name <> all (array[
        '@dataSetInternalID', 'meanAmount', 'resultingAmount', 'referenceToFlowDataSet',
        'exchangeDirection', 'dataDerivationTypeStatus', 'uncertaintyDistributionType',
        'relativeStandardDeviation95In', 'generalComment', 'common:other', 'name', 'unit'
      ])
    )
$$;

alter function private.dataset_alias_v2_exchange_keys_ok(jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_exchange_keys_ok(jsonb) from public;
comment on function private.dataset_alias_v2_exchange_keys_ok(jsonb) is
  'Closed key whitelist for one v2 exchange: any unknown or absolute-uncertainty key fails closed.';

-- Flow property reference replacement (object or single-entry array shape both supported).
create or replace function private.dataset_alias_v2_replace_flow_reference(p_before jsonb, p_reference jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_entry jsonb := p_before #> '{flowDataSet,flowProperties,flowProperty}';
begin
  if v_entry is null or p_reference is null then
    return null;
  end if;
  if jsonb_typeof(v_entry) = 'array' then
    if jsonb_array_length(v_entry) <> 1 or coalesce(v_entry->0->>'@dataSetInternalID', '') <> '1' then
      return null;
    end if;
    return jsonb_set(p_before, '{flowDataSet,flowProperties,flowProperty,0,referenceToFlowPropertyDataSet}', p_reference, false);
  end if;
  if jsonb_typeof(v_entry) <> 'object' or coalesce(v_entry->>'@dataSetInternalID', '') <> '1' then
    return null;
  end if;
  return jsonb_set(p_before, '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet}', p_reference, false);
end
$$;

alter function private.dataset_alias_v2_replace_flow_reference(jsonb, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_replace_flow_reference(jsonb, jsonb) from public;

-- Exchange amount replacement: both reviewed absolute leaves move by the fixed factor, from the stored
-- literal, and every other byte survives. The original literal is part of the proof: no numeric-equivalent
-- fallback is accepted.
create or replace function private.dataset_alias_v2_replace_exchange_amounts(p_before jsonb, p_exchange jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_index integer := coalesce((p_exchange->>'index')::integer, -1);
  v_exchanges jsonb := p_before #> '{processDataSet,exchanges,exchange}';
  v_entry jsonb;
  v_after text;
begin
  if v_index < 0 or jsonb_typeof(v_exchanges) <> 'array' or v_index >= jsonb_array_length(v_exchanges) then
    return null;
  end if;
  v_entry := v_exchanges->v_index;
  if not private.dataset_alias_v2_exchange_keys_ok(v_entry) then
    return null;
  end if;
  if coalesce(v_entry->>'@dataSetInternalID', '') <> coalesce(p_exchange->>'internal_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@refObjectId', '') <> coalesce(p_exchange->>'flow_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@version', '') <> coalesce(p_exchange->>'flow_version', '')
    or coalesce(v_entry->>'exchangeDirection', '') <> coalesce(p_exchange->>'direction', '')
    or v_entry->>'meanAmount' is distinct from p_exchange->>'before_amount'
    or v_entry->>'resultingAmount' is distinct from p_exchange->>'before_amount' then
    return null;
  end if;
  v_after := private.dataset_alias_v2_multiply_amount(p_exchange->>'before_amount', private.dataset_alias_v2_factor()::text);
  if v_after is null or v_after is distinct from p_exchange->>'after_amount' then
    return null;
  end if;
  return jsonb_set(
    jsonb_set(p_before, array['processDataSet', 'exchanges', 'exchange', v_index::text, 'meanAmount'], to_jsonb(v_after), false),
    array['processDataSet', 'exchanges', 'exchange', v_index::text, 'resultingAmount'], to_jsonb(v_after), false);
end
$$;

alter function private.dataset_alias_v2_replace_exchange_amounts(jsonb, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_replace_exchange_amounts(jsonb, jsonb) from public;

-- Functional-unit text: only the exact reviewed leaf may move, and only under the anchored token rule.
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

create or replace function private.dataset_alias_v2_fu_path_ok(p_path text)
returns boolean
language sql
immutable
as $$
  select p_path = 'processDataSet.processInformation.quantitativeReference.functionalUnitOrOther.#text'
$$;

alter function private.dataset_alias_v2_fu_path_ok(text) owner to postgres;
revoke all on function private.dataset_alias_v2_fu_path_ok(text) from public;
comment on function private.dataset_alias_v2_fu_path_ok(text) is
  'Only the reviewed functional-unit text leaf may carry a v2 text mutation; every other path is refused.';

create or replace function private.dataset_alias_v2_replace_fu_text(p_before jsonb, p_functional_unit jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_path text := coalesce(p_functional_unit->>'path', '');
  v_before_text text := p_functional_unit->>'before_text';
  v_after_text text := p_functional_unit->>'after_text';
  v_stored text := p_before #>> string_to_array(v_path, '.');
  v_derived text;
begin
  if not private.dataset_alias_v2_fu_path_ok(v_path) or v_before_text is null or v_after_text is null then
    return null;
  end if;
  if v_stored is distinct from v_before_text then
    return null;
  end if;
  v_derived := private.dataset_alias_v2_fu_apply_rule(v_before_text);
  if v_derived is null or v_derived is distinct from v_after_text then
    return null;
  end if;
  return jsonb_set(p_before, string_to_array(v_path, '.'), to_jsonb(v_derived), false);
end
$$;

alter function private.dataset_alias_v2_replace_fu_text(jsonb, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_replace_fu_text(jsonb, jsonb) from public;

-- Canonical hash of one payload, reusing the repository's existing routine.
create or replace function private.dataset_alias_v2_payload_sha256(p_payload jsonb)
returns text
language sql
immutable
as $$
  select encode(extensions.digest(convert_to(private.dataset_alias_canonical_jsonb_v1(p_payload)::text, 'UTF8'), 'sha256'), 'hex')
$$;

alter function private.dataset_alias_v2_payload_sha256(jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_payload_sha256(jsonb) from public;

-- The guarded executor.
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
  v_command constant text := 'cmd_dataset_alias_batch_v2_guarded';
  v_batch_id text;
  v_operation_id text;
  v_plan_sha256 text;
  v_factor text;
  v_actions jsonb;
  v_action_count integer;
  v_action jsonb;
  v_reference jsonb;
  v_alias_fp_id text;
  v_alias_fp_version text;
  v_target_fp jsonb;
  v_target_ug jsonb;
  v_prepared jsonb := '[]'::jsonb;
  v_derived jsonb;
  v_entry jsonb;
  v_live_flows jsonb;
  v_batch_flows jsonb;
  v_live_occurrences jsonb;
  v_batch_occurrences jsonb;
  v_occurrence_count integer;
  v_selected_processes jsonb;
  v_selected_exchanges integer := 0;
  v_unrelated integer;
  v_fu_count integer;
  v_prior_summary jsonb;
  v_replay boolean := false;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED', 'status', 401, 'message', 'Authentication required');
  end if;

  begin  -- one subtransaction: every post-start refusal raises, so nothing partial survives
    if jsonb_typeof(p_batch) is distinct from 'object' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'The v2 batch must be one JSON object');
    end if;
    if exists (
      select 1 from jsonb_object_keys(p_batch) as key(name)
      where key.name <> all (array[
        'schema_version', 'batch_id', 'operation_id', 'plan_sha256', 'dimension', 'factor',
        'target_visibility', 'target_snapshots', 'source_evidence', 'counts', 'actions'
      ])
    ) then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Unknown batch keys are refused');
    end if;
    if p_batch->>'schema_version' is distinct from v_schema_version
      or p_batch->>'dimension' is distinct from 'time'
      or p_batch->>'target_visibility' is distinct from 'owner_draft'
      or p_batch->>'factor' is distinct from private.dataset_alias_v2_factor()::text
      or (p_batch->>'plan_sha256') !~ '^[a-f0-9]{64}$'
      or nullif(btrim(p_batch->>'batch_id'), '') is null
      or nullif(btrim(p_batch->>'operation_id'), '') is null
      or jsonb_typeof(p_batch->'actions') is distinct from 'array'
      or jsonb_typeof(p_batch->'counts') is distinct from 'object'
      or jsonb_typeof(p_batch->'target_snapshots') is distinct from 'object'
      or jsonb_typeof(p_batch->'source_evidence') is distinct from 'object' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'Batch envelope, dimension, factor, plan identity, counts, snapshots or action list is invalid');
    end if;
    v_batch_id := btrim(p_batch->>'batch_id');
    v_operation_id := btrim(p_batch->>'operation_id');
    v_plan_sha256 := p_batch->>'plan_sha256';
    v_factor := p_batch->>'factor';
    v_actions := p_batch->'actions';
    v_action_count := jsonb_array_length(v_actions);
    if v_action_count < 1 or v_action_count > 4096 then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'A v2 batch carries between one and 4096 actions');
    end if;

    -- Locks: unit groups inside the boundary so no concurrent factor or snapshot change can race.
    lock table public.flowproperties, public.unitgroups, public.flows, public.processes
      in share row exclusive mode;

    -- Target and source evidence are read from the locked rows, never trusted from the envelope.
    select json_ordered::jsonb into v_target_fp
    from public.flowproperties
    where id = (p_batch #>> '{target_snapshots,flowproperty,id}')::uuid
      and version = p_batch #>> '{target_snapshots,flowproperty,version}';
    select json_ordered::jsonb into v_target_ug
    from public.unitgroups
    where id = (p_batch #>> '{target_snapshots,unitgroup,id}')::uuid
      and version = p_batch #>> '{target_snapshots,unitgroup,version}';
    if v_target_fp is null or v_target_ug is null then
      perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409, 'The declared target flow property or unit group does not exist');
    end if;
    if private.dataset_alias_v2_payload_sha256(v_target_fp) is distinct from p_batch #>> '{target_snapshots,flowproperty,sha256}'
      or private.dataset_alias_v2_payload_sha256(v_target_ug) is distinct from p_batch #>> '{target_snapshots,unitgroup,sha256}' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409, 'Target snapshot content does not match the declared binding');
    end if;
    -- The target flow property must reference exactly this unit group, and the unit group must carry the
    -- reviewed factor for its hour unit plus an unmodified year base.
    if v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
        is distinct from p_batch #>> '{target_snapshots,unitgroup,id}'
      or not exists (
        select 1
        from jsonb_array_elements(coalesce(v_target_ug #> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}', '[]'::jsonb)) as unit
        where unit->>'@unitName' = 'hr' and (unit->>'meanValue')::numeric = private.dataset_alias_v2_factor()
      )
      or not exists (
        select 1
        from jsonb_array_elements(coalesce(v_target_ug #> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}', '[]'::jsonb)) as unit
        where unit->>'@unitName' = 'a' and (unit->>'meanValue')::numeric = 1
      ) then
      perform private.dataset_alias_v2_deny('ALIAS_V2_FACTOR_UNSUPPORTED', 409,
        'The target unit group does not carry the reviewed year base and exact hour factor');
    end if;
    -- The derived reference is recomputed from the locked target row, never taken from the envelope.
    v_reference := jsonb_build_object(
      '@refObjectId', p_batch #>> '{target_snapshots,flowproperty,id}',
      '@version', p_batch #>> '{target_snapshots,flowproperty,version}',
      '@uri', coalesce(v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:other}', ''),
      'common:shortDescription', coalesce(v_target_fp #> '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,name,baseName}', '[]'::jsonb)
    );

    -- The alias flow property is identified from the frozen before payloads; all actions must agree.
    for v_action in select * from jsonb_array_elements(v_actions) loop
      if jsonb_typeof(v_action) <> 'object' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Every action must be one JSON object');
      end if;
      if exists (
        select 1 from jsonb_object_keys(v_action) as key(name)
        where key.name <> all (array[
          'action_id', 'table', 'id', 'version', 'expected_state_code', 'expected_modified_at',
          'expected_json_ordered', 'desired_json_ordered', 'mutation'
        ])
      ) or v_action->'desired_json_ordered' is null then
        perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Unknown action keys, or a missing desired claim');
      end if;
      if v_action->>'table' not in ('flows', 'processes')
        or (v_action->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or (v_action->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
        or (v_action->>'expected_state_code')::integer is distinct from 0
        or jsonb_typeof(v_action->'expected_json_ordered') is distinct from 'object'
        or jsonb_typeof(v_action->'mutation') is distinct from 'object'
        or (v_action->>'expected_modified_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
          'Action identity, table, state, before payload, mutation or timestamp is invalid',
          jsonb_build_object('action_id', v_action->>'action_id'));
      end if;
      if v_action->>'table' = 'flows' then
        v_alias_fp_id := coalesce(v_alias_fp_id, v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}');
        v_alias_fp_version := coalesce(v_alias_fp_version, v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@version}');
        if v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}' is distinct from v_alias_fp_id
          or v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@version}' is distinct from v_alias_fp_version then
          perform private.dataset_alias_v2_deny('ALIAS_V2_CLOSURE_MISMATCH', 409, 'Every flow action must start from the same alias flow property');
        end if;
      end if;
    end loop;
    if v_alias_fp_id is null then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'A v2 batch needs at least one flow action to identify the alias property');
    end if;

    -- Exact reference closure: every live consumer of the alias property, any owner, any state.
    select coalesce(jsonb_agg(jsonb_build_object('table', 'flows', 'id', f.id, 'version', f.version, 'state_code', f.state_code, 'user_id', f.user_id) order by f.id, f.version), '[]'::jsonb)
      into v_live_flows
    from public.flows f
    where f.json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}' = v_alias_fp_id
      and f.json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@version}' = v_alias_fp_version;
    select coalesce(jsonb_agg(jsonb_build_object('id', (a->>'id')::uuid, 'version', a->>'version') order by (a->>'id')::uuid, a->>'version'), '[]'::jsonb)
      into v_batch_flows
    from jsonb_array_elements(v_actions) as a
    where a->>'table' = 'flows';
    if v_live_flows is distinct from (
      select coalesce(jsonb_agg(jsonb_build_object('table', 'flows', 'id', b->>'id', 'version', b->>'version') order by b->>'id', b->>'version'), '[]'::jsonb)
      from jsonb_array_elements(v_live_flows) as b
    ) or jsonb_array_length(v_live_flows) <> jsonb_array_length(v_batch_flows)
      or exists (
        select 1 from jsonb_array_elements(v_live_flows) as live
        where not exists (
          select 1 from jsonb_array_elements(v_batch_flows) as claimed
          where claimed->>'id' = live->>'id' and claimed->>'version' = live->>'version'
        )
      )
      or exists (
        select 1 from jsonb_array_elements(v_live_flows) as live
        where (live->>'state_code')::integer <> 0 or (live->>'user_id')::uuid <> v_actor
      ) then
      perform private.dataset_alias_v2_deny('ALIAS_V2_CLOSURE_MISMATCH', 409,
        'The live reference closure of the alias property differs from the claimed flow set, or holds a foreign or non-draft consumer');
    end if;

    -- Exact Process/exchange occurrences of those flows, any owner and any state.
    select coalesce(jsonb_agg(jsonb_build_object('process_id', p.id, 'process_version', p.version, 'state_code', p.state_code, 'user_id', p.user_id, 'index', exchange.ordinality - 1, 'internal_id', exchange.value->>'@dataSetInternalID', 'direction', exchange.value->>'exchangeDirection') order by p.id, p.version, exchange.ordinality), '[]'::jsonb)
      into v_live_occurrences
    from public.processes p
    cross join lateral jsonb_array_elements(coalesce(p.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) with ordinality as exchange
    where exists (
      select 1 from jsonb_array_elements(v_batch_flows) as claimed
      where claimed->>'id' = exchange.value->'referenceToFlowDataSet'->>'@refObjectId'
        and claimed->>'version' = exchange.value->'referenceToFlowDataSet'->>'@version'
    );
    select coalesce(jsonb_agg(jsonb_build_object('process_id', (a->>'id')::uuid, 'process_version', a->>'version', 'index', (e->>'index')::integer, 'internal_id', e->>'internal_id', 'direction', e->>'direction') order by (a->>'id')::uuid, a->>'version', (e->>'index')::integer), '[]'::jsonb)
      into v_batch_occurrences
    from jsonb_array_elements(v_actions) as a
    cross join lateral jsonb_array_elements(coalesce(a->'mutation'->'exchanges', '[]'::jsonb)) as e
    where a->>'table' = 'processes';
    if jsonb_array_length(v_live_occurrences) <> jsonb_array_length(v_batch_occurrences)
      or exists (
        select 1 from jsonb_array_elements(v_batch_occurrences) as claimed
        where not exists (
          select 1 from jsonb_array_elements(v_live_occurrences) as live
          where live->>'process_id' = claimed->>'process_id' and live->>'process_version' = claimed->>'process_version'
            and live->>'index' = claimed->>'index' and live->>'internal_id' = claimed->>'internal_id'
            and live->>'direction' = claimed->>'direction'
        )
      )
      or exists (
        select 1 from jsonb_array_elements(v_live_occurrences) as live
        where (live->>'state_code')::integer <> 0 or (live->>'user_id')::uuid <> v_actor
      ) then
      perform private.dataset_alias_v2_deny('ALIAS_V2_CLOSURE_MISMATCH', 409,
        'The live exchange occurrences of the alias flows differ from the claimed instances, or hold a foreign or non-draft consumer');
    end if;

    -- Unrelated complement inside the selected processes, and the live process set.
    for v_action in select * from jsonb_array_elements(v_actions) where value->>'table' = 'processes' loop
      select v_selected_exchanges + coalesce(jsonb_array_length(v_action->'expected_json_ordered' #> '{processDataSet,exchanges,exchange}'), 0) into v_selected_exchanges;
    end loop;
    v_occurrence_count := jsonb_array_length(v_batch_occurrences);
    v_unrelated := v_selected_exchanges - v_occurrence_count;
    if (p_batch #>> '{counts,action_count}')::integer is distinct from v_action_count
      or (p_batch #>> '{counts,flow_count}')::integer is distinct from jsonb_array_length(v_batch_flows)
      or (p_batch #>> '{counts,exchange_count}')::integer is distinct from v_occurrence_count
      or (p_batch #>> '{counts,unrelated_exchange_count}')::integer is distinct from v_unrelated then
      perform private.dataset_alias_v2_deny('ALIAS_V2_COUNT_MISMATCH', 409, 'Derived live counts differ from the submitted plan counts',
        jsonb_build_object('actions', v_action_count, 'flows', jsonb_array_length(v_batch_flows),
          'occurrences', v_occurrence_count, 'unrelated', v_unrelated));
    end if;

    -- Validation and derivation pass: no writes yet. Every claim must equal the server derivation.
    v_fu_count := 0;
    for v_action in select * from jsonb_array_elements(v_actions) loop
      declare
        v_before jsonb := v_action->'expected_json_ordered';
        v_claim jsonb := v_action->'desired_json_ordered';
        v_table text := v_action->>'table';
        v_row_state integer;
        v_row_modified timestamptz;
        v_row_payload jsonb;
      begin
        execute format('select state_code, modified_at, json_ordered::jsonb from public.%I where id = $1 and version = $2', v_table)
          into v_row_state, v_row_modified, v_row_payload using (v_action->>'id')::uuid, v_action->>'version';
        if v_row_state is not distinct from 0 and v_row_modified is not distinct from (v_action->>'expected_modified_at')::timestamptz
          and v_row_payload is not distinct from v_before then
          -- fresh action: derive server-side
          if v_table = 'flows' then
            v_derived := private.dataset_alias_v2_replace_flow_reference(v_before, v_reference);
          else
            v_derived := v_before;
            for v_entry in select * from jsonb_array_elements(coalesce(v_action->'mutation'->'exchanges', '[]'::jsonb)) loop
              v_derived := private.dataset_alias_v2_replace_exchange_amounts(v_derived, v_entry);
              if v_derived is null then
                perform private.dataset_alias_v2_deny('ALIAS_V2_DERIVE_MISMATCH', 409, 'An exchange instance does not bind the stored row', jsonb_build_object('action_id', v_action->>'action_id'));
              end if;
            end loop;
            if v_action->'mutation' ? 'functional_unit' then
              v_derived := private.dataset_alias_v2_replace_fu_text(v_derived, v_action->'mutation'->'functional_unit');
              if v_derived is null then
                perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400, 'The functional-unit text is not the reviewed leaf under the anchored rule', jsonb_build_object('action_id', v_action->>'action_id'));
              end if;
              v_fu_count := v_fu_count + 1;
            end if;
          end if;
          if v_derived is null or v_derived is not distinct from v_before then
            perform private.dataset_alias_v2_deny('ALIAS_V2_DERIVE_MISMATCH', 409, 'The derivation produced no real change', jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
          if v_claim is distinct from v_derived then
            perform private.dataset_alias_v2_deny('ALIAS_V2_DERIVE_MISMATCH', 409, 'The claimed desired payload differs from the server derivation', jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
          v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
            'action_id', v_action->>'action_id', 'table', v_table, 'id', v_action->>'id', 'version', v_action->>'version',
            'before', v_before, 'desired', v_derived));
        elsif v_row_state is not distinct from 0 and v_row_payload = v_claim then
          -- already at the desired state: replay candidate, resolved after the write pass
          v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
            'action_id', v_action->>'action_id', 'table', v_table, 'id', v_action->>'id', 'version', v_action->>'version',
            'before', v_before, 'desired', v_claim, 'replayed', true));
        else
          perform private.dataset_alias_v2_deny('ALIAS_V2_ACTION_DRIFT', 409, 'An action no longer matches its frozen before content, owner, state or version', jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
      end;
    end loop;

    -- Write pass: only after every action validated. Any raise here unwinds the whole subtransaction.
    declare
      v_committed_modified_at timestamptz;
      v_committed_payload jsonb;
      v_fresh integer := 0;
      v_replayed integer := 0;
      v_summary_id bigint;
      v_audit_rows jsonb := '[]'::jsonb;
      v_prior_id bigint;
    begin
      for v_action in select * from jsonb_array_elements(v_prepared) loop
        if coalesce((v_action->>'replayed')::boolean, false) then
          select audit_log.id into v_prior_id
          from public.command_audit_log as audit_log
          where audit_log.command = v_command
            and audit_log.actor_user_id = v_actor
            and audit_log.target_table = v_action->>'table'
            and audit_log.target_id = (v_action->>'id')::uuid
            and audit_log.target_version = v_action->>'version'
            and audit_log.payload->>'record_type' = 'row'
            and audit_log.payload->>'plan_sha256' = v_plan_sha256
            and audit_log.payload->>'action_id' = v_action->>'action_id'
            and audit_log.payload->>'after_sha256' = private.dataset_alias_v2_payload_sha256(v_action->'desired')
          order by audit_log.id desc limit 1;
          if v_prior_id is null then
            perform private.dataset_alias_v2_deny('ALIAS_V2_REPLAY_UNPROVEN', 409, 'A desired-state row has no committed audit proof', jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
          v_replayed := v_replayed + 1;
          v_audit_rows := v_audit_rows || jsonb_build_array(jsonb_build_object('action_id', v_action->>'action_id', 'audit_id', v_prior_id::text, 'replayed', true));
          continue;
        end if;
        v_committed_modified_at := null;
        v_committed_payload := null;
        execute format(
          'update public.%I as t set json_ordered = $1::json, modified_at = now()
            where t.id = $2 and t.version = $3 and t.user_id = $4 and t.state_code = $5
              and t.modified_at is not distinct from $6 and t.json_ordered::jsonb is not distinct from $7
          returning t.modified_at, t.json_ordered::jsonb', v_action->>'table')
          into v_committed_modified_at, v_committed_payload
          using v_action->'desired', (v_action->>'id')::uuid, v_action->>'version', v_actor, 0,
            (v_action->>'expected_modified_at')::timestamptz, v_action->'before';
        if v_committed_modified_at is null or v_committed_payload is distinct from v_action->'desired' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_ACTION_DRIFT', 409, 'The guarded update lost its precondition', jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        insert into public.command_audit_log (command, actor_user_id, target_table, target_id, target_version, payload)
        values (v_command, v_actor, v_action->>'table', (v_action->>'id')::uuid, v_action->>'version',
          jsonb_build_object(
            'record_type', 'row', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
            'operation_id', v_operation_id, 'batch_id', v_batch_id, 'dimension', 'time', 'factor', v_factor,
            'target_visibility', 'owner_draft', 'action_id', v_action->>'action_id',
            'expected_state_code', 0, 'expected_modified_at', v_action->>'expected_modified_at',
            'committed_modified_at', to_jsonb(v_committed_modified_at),
            'before_sha256', private.dataset_alias_v2_payload_sha256(v_action->'before'),
            'after_sha256', private.dataset_alias_v2_payload_sha256(v_action->'desired'),
            'hash_algorithm', 'dataset-alias-canonical-json-v1-sha256'))
        returning id into v_prior_id;
        v_fresh := v_fresh + 1;
        v_audit_rows := v_audit_rows || jsonb_build_array(jsonb_build_object('action_id', v_action->>'action_id', 'audit_id', v_prior_id::text, 'after_sha256', private.dataset_alias_v2_payload_sha256(v_action->'desired')));
      end loop;

      -- Exact replay writes no new successful audit: the durable plan summary is the proof.
      if v_replayed = v_action_count then
        select audit_log.payload into v_prior_summary
        from public.command_audit_log as audit_log
        where audit_log.command = v_command
          and audit_log.actor_user_id = v_actor
          and audit_log.payload->>'record_type' = 'plan'
          and audit_log.payload->>'plan_sha256' = v_plan_sha256
        order by audit_log.id desc limit 1;
        if v_prior_summary is null then
          perform private.dataset_alias_v2_deny('ALIAS_V2_REPLAY_UNPROVEN', 409, 'An exact replay requires its durable plan summary');
        end if;
        return jsonb_build_object('ok', true, 'code', 'ALIAS_V2_BATCH_REPLAYED', 'status', 200,
          'idempotent_replay', true, 'plan_sha256', v_plan_sha256, 'batch_id', v_batch_id,
          'counts', v_prior_summary->'counts', 'audit', jsonb_build_object('rows', v_audit_rows));
      end if;

      insert into public.command_audit_log (command, actor_user_id, target_table, payload)
      values (v_command, v_actor, 'flows', jsonb_build_object(
        'record_type', 'plan', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
        'operation_id', v_operation_id, 'batch_id', v_batch_id, 'dimension', 'time', 'factor', v_factor,
        'action_count', v_action_count, 'fresh_actions', v_fresh, 'replayed_actions', v_replayed,
        'fu_text_actions', v_fu_count,
        'counts', jsonb_build_object('action_count', v_action_count, 'flow_count', jsonb_array_length(v_batch_flows),
          'process_count', v_action_count - jsonb_array_length(v_batch_flows),
          'exchange_count', v_occurrence_count, 'unrelated_exchange_count', v_unrelated)))
      returning id into v_summary_id;

      return jsonb_build_object('ok', true, 'code', 'ALIAS_V2_BATCH_APPLIED', 'status', 200,
        'idempotent_replay', false, 'plan_sha256', v_plan_sha256, 'batch_id', v_batch_id,
        'counts', jsonb_build_object('action_count', v_action_count, 'flow_count', jsonb_array_length(v_batch_flows),
          'process_count', v_action_count - jsonb_array_length(v_batch_flows),
          'exchange_count', v_occurrence_count, 'unrelated_exchange_count', v_unrelated, 'fu_text_actions', v_fu_count),
        'audit', jsonb_build_object('plan_summary_id', v_summary_id, 'rows', v_audit_rows));
    end;
  exception
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_LOCK_TIMEOUT', 'status', 409,
        'message', 'The v2 lock window could not be acquired; nothing was written');
    when others then
      -- All-or-none: the subtransaction's writes are already gone when this handler runs.
      if sqlstate = 'P0001' then
        return jsonb_build_object('ok', false, 'code', sqlerrm, 'status',
          coalesce((nullif(pg_exception_hint, '')::jsonb->>'status')::integer, 409),
          'message', pg_exception_detail,
          'details', coalesce(nullif(pg_exception_hint, '')::jsonb->'details', '{}'::jsonb));
      end if;
      return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_INTERNAL_ERROR', 'status', 500,
        'message', 'The v2 batch failed closed without writing');
  end;
end
$$;

alter function private.cmd_dataset_alias_batch_v2_guarded(jsonb) owner to postgres;
revoke all on function private.cmd_dataset_alias_batch_v2_guarded(jsonb) from public;
comment on function private.cmd_dataset_alias_batch_v2_guarded(jsonb) is
  'Versioned guarded v2 batch executor: all-or-none validation-then-write, exact reference closure, recomputed target evidence, server-derived desired payloads, ordinary audit and exact replay. v1 untouched.';
