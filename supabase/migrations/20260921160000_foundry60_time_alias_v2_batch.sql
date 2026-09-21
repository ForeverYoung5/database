-- Foundry #60 / Database #673 — v2 guarded batch executor for the current source-hour Time repair.
--
-- Rewritten per root's line review of addabc6 (`/tmp/database673-batch-root-review.md`) and the independent
-- batch review (`/tmp/database673-independent-batch-review.md`). The executor is all-or-none by
-- construction: a read-only validation and derivation pass runs over every action first, and the write pass
-- raises on any post-write refusal, with one enclosing exception block that turns the raise into the stable
-- envelope. A `return` never leaves a partial write behind, and a resubmitted (already applied) plan
-- returns its stored proof without writing.
--
-- The batch envelope is closed: counts, target snapshots and source evidence carry exactly the reviewed
-- keys with checked shapes, the factor is the one approved constant, and the source evidence digest and
-- exchange count are read and verified against the recomputed exchange count (then durably bound into the
-- plan audit row, which an exact replay must match).
--
-- Scope eligibility (root decision): every flow action must start from a `Product flow`
-- (`flowDataSet.modellingAndValidation.LCIMethod.typeOfDataSet`); missing, Elementary or Waste flows are
-- refused before any write so the maintenance path cannot widen.
--
-- Closure is a real reference closure, not a payload membership test: the alias flow property is identified
-- from the frozen before payloads, every live referrer (Flow, any owner, any state) and every Process
-- exchange occurrence of those exact flow id/version pairs is discovered under the locks, and the exact
-- sets — not counts — must equal what the batch carries. `unrelated_exchange_count` is the complement
-- inside the selected Processes. A batch is either entirely fresh or an exact replay; a mixture is refused.
--
-- Derivation (agreement §A6b, CLI B1): flows move only the internal-ID-1 property entry's
-- `referenceToFlowPropertyDataSet`, recomputed from the locked target Flow property row — the deployed
-- five-key reference whose `common:shortDescription` is the target's own language-tagged
-- `flowPropertiesInformation.dataSetInformation["common:name"]` object (root-verified shape; never a
-- Process-shaped name path, never invented) and whose `@type`/`@uri` convention comes from the frozen
-- before reference with the target id/version substituted. The claimed canonical reference must equal it.
-- Processes move only the reviewed amount leaves of the named exchange instances (original stored literal,
-- exact numeric) and, for the affected reference processes, the exact functional-unit text leaf. Source
-- numbers are their own namespace: `mutation.exchanges[].source_exchange_number` and the functional unit's
-- `source_exchange_number` are the original EcoSpold numbers (for example 730045), while
-- `@dataSetInternalID` and `quantitativeReference.referenceToReferenceFlow` are TIDAS internal ids ("1").
-- The reference exchange is therefore bound by the TIDAS internal id first; the original source number then
-- binds the functional unit to that exchange's reviewed source tuple, whose stored `generalComment` must
-- name the same number when it exists; and the reviewed leading quantity must equal that exchange's own
-- stored source quantity, so a functional unit can never move over a physically different amount. The
-- internal pointers `flowInformation.quantitativeReference.referenceToReferenceFlowProperty` and
-- `quantitativeReference.referenceToReferenceFlow` never move, and no arbitrary dotted path may target other
-- text. The stored exchange key set is closed, so an absolute uncertainty bound fails closed instead of
-- being scaled.

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
  v_selected_exchanges integer := 0;
  v_unrelated integer;
  v_fu_count integer := 0;
  v_fresh_count integer := 0;
  v_replayed_count integer := 0;
  v_prior_summary jsonb;
  v_hint text;
  v_detail text;
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

    -- Counts, snapshot and evidence blocks carry exactly the reviewed keys with checked shapes; nothing is
    -- echoed unread and nothing defaults when a value is missing or malformed.
    if exists (
      select 1 from jsonb_object_keys(p_batch->'counts') as key(name)
      where key.name <> all (array['action_count', 'flow_count', 'process_count', 'exchange_count',
        'unrelated_exchange_count', 'flowproperty_count'])
    ) or (select count(*) from jsonb_object_keys(p_batch->'counts')) <> 6
      or (p_batch #>> '{counts,action_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,flow_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,process_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,exchange_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,unrelated_exchange_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,flowproperty_count}') !~ '^[0-9]+$' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'The counts block must carry exactly the six reviewed numeric keys');
    end if;
    if exists (
      select 1 from jsonb_object_keys(p_batch->'target_snapshots') as key(name)
      where key.name <> all (array['flowproperty', 'unitgroup', 'reference'])
    )
      or jsonb_typeof(p_batch->'target_snapshots'->'flowproperty') is distinct from 'object'
      or jsonb_typeof(p_batch->'target_snapshots'->'unitgroup') is distinct from 'object'
      or jsonb_typeof(p_batch->'target_snapshots'->'reference') is distinct from 'object'
      or (p_batch #>> '{target_snapshots,flowproperty,id}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or (p_batch #>> '{target_snapshots,unitgroup,id}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or (p_batch #>> '{target_snapshots,flowproperty,version}') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or (p_batch #>> '{target_snapshots,unitgroup,version}') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'The target snapshot block must carry exactly the target flow property, unit group and canonical reference');
    end if;
    if exists (
      select 1 from jsonb_object_keys(p_batch->'source_evidence') as key(name)
      where key.name <> all (array['sha256', 'exchange_count'])
    ) or (p_batch #>> '{source_evidence,sha256}') !~ '^[a-f0-9]{64}$'
      or (p_batch #>> '{source_evidence,exchange_count}') !~ '^[0-9]+$' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'The source evidence block must carry exactly the reviewed 64-hex digest and the bound exchange count');
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

    -- The claimed flow and occurrence sets are aggregated before the structural scan, so every exchange
    -- instance and functional-unit source can be bound to a claimed alias flow inside the same pass. The
    -- shapes are pre-guarded so a malformed action cannot raise here; the scan below refuses it properly.
    select coalesce(jsonb_agg(jsonb_build_object('id', (a->>'id')::uuid, 'version', a->>'version') order by (a->>'id')::uuid, a->>'version'), '[]'::jsonb)
      into v_batch_flows
    from jsonb_array_elements(v_actions) as a
    where a->>'table' = 'flows'
      and (a->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    select coalesce(jsonb_agg(jsonb_build_object('process_id', (a->>'id')::uuid, 'process_version', a->>'version', 'index', (e->>'index')::integer, 'internal_id', e->>'internal_id', 'direction', e->>'direction') order by (a->>'id')::uuid, a->>'version', (e->>'index')::integer), '[]'::jsonb)
      into v_batch_occurrences
    from jsonb_array_elements(v_actions) as a
    cross join lateral jsonb_array_elements(coalesce(a->'mutation'->'exchanges', '[]'::jsonb)) as e
    where a->>'table' = 'processes'
      and (a->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and (e->>'index') ~ '^[0-9]+$';

    -- Structural scan: identity, closed keys and the alias property identified from the frozen before
    -- payloads; every action must agree. The functional-unit mutation is bound here to this process's own
    -- reference-flow exchange and to the claimed alias exchanges — a free-floating text edit is refused.
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
        -- Scope eligibility (root decision, Product flow only): every repaired flow must start from a
        -- Product flow. Missing, Elementary flow and Waste flow are refused before any write, so the
        -- maintenance path cannot silently widen to elementary or waste datasets.
        if v_action->'expected_json_ordered' #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' is distinct from 'Product flow' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
            'Every flow action must start from a Product flow; a missing or non-product typeOfDataSet is refused',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        if exists (
          select 1 from jsonb_object_keys(v_action->'mutation') as key(name)
          where key.name <> all (array['reference_id', 'reference_version'])
        ) or coalesce(v_action->'mutation'->>'reference_id', '') = ''
          or coalesce(v_action->'mutation'->>'reference_version', '') = '' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
            'A flow action names exactly the derived target reference id and version',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        v_alias_fp_id := coalesce(v_alias_fp_id, v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}');
        v_alias_fp_version := coalesce(v_alias_fp_version, v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@version}');
        if v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}' is distinct from v_alias_fp_id
          or v_action->'expected_json_ordered' #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@version}' is distinct from v_alias_fp_version then
          perform private.dataset_alias_v2_deny('ALIAS_V2_CLOSURE_MISMATCH', 409, 'Every flow action must start from the same alias flow property');
        end if;
      else
        if exists (
          select 1 from jsonb_object_keys(v_action->'mutation') as key(name)
          where key.name <> all (array['exchanges', 'functional_unit'])
        ) or jsonb_typeof(v_action->'mutation'->'exchanges') is distinct from 'array'
          or jsonb_array_length(v_action->'mutation'->'exchanges') < 1 then
          perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
            'A process action carries its bound exchange instances and nothing else',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        for v_entry in select * from jsonb_array_elements(v_action->'mutation'->'exchanges') loop
          if jsonb_typeof(v_entry) <> 'object'
            or exists (
              select 1 from jsonb_object_keys(v_entry) as key(name)
              where key.name <> all (array['index', 'internal_id', 'source_exchange_number', 'flow_id',
                'flow_version', 'direction', 'before_amount', 'after_amount'])
            )
            or coalesce(v_entry->>'index', '') !~ '^[0-9]+$'
            or coalesce(v_entry->>'internal_id', '') = ''
            or coalesce(v_entry->>'source_exchange_number', '') !~ '^[0-9]{1,18}$'
            or coalesce(v_entry->>'flow_id', '') = ''
            or coalesce(v_entry->>'flow_version', '') = ''
            or coalesce(v_entry->>'direction', '') = ''
            or v_entry->>'before_amount' is null
            or v_entry->>'after_amount' is null
            or not exists (
              select 1 from jsonb_array_elements(v_batch_flows) as claimed
              where claimed->>'id' = v_entry->>'flow_id' and claimed->>'version' = v_entry->>'flow_version'
            ) then
            perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
              'Every exchange instance must carry exactly the reviewed keys — including the original EcoSpold source exchange number, which is a different namespace from the TIDAS internal id — and name a claimed alias flow',
              jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
        end loop;
        if v_action->'mutation' ? 'functional_unit' then
          declare
            v_fu jsonb := v_action->'mutation'->'functional_unit';
            v_fu_source text := v_fu->>'source_exchange_number';
            v_fu_quantity text;
            v_reference_internal text := v_action->'expected_json_ordered' #>> '{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}';
            v_reference_entry jsonb;
            v_stored_comment text;
          begin
            if jsonb_typeof(v_fu) <> 'object'
              or exists (
                select 1 from jsonb_object_keys(v_fu) as key(name)
                where key.name <> all (array['path', 'before_text', 'after_text', 'source_exchange_number'])
              )
              or coalesce(v_fu_source, '') !~ '^[0-9]{1,18}$'
              or coalesce(v_reference_internal, '') = '' then
              perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
                'The functional-unit block carries exactly the reviewed keys: path, before and after text and the original source exchange number',
                jsonb_build_object('action_id', v_action->>'action_id'));
            end if;
            -- Step 1: the process reference exchange is bound by its TIDAS internal id — the frozen internal
            -- pointer — never by the original EcoSpold number, which is a different namespace.
            select entry into v_reference_entry
            from jsonb_array_elements(v_action->'mutation'->'exchanges') as entry
            where entry->>'internal_id' = v_reference_internal;
            if v_reference_entry is null then
              perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
                'The functional-unit process reference exchange (TIDAS internal id) is not among the bound alias exchanges',
                jsonb_build_object('action_id', v_action->>'action_id'));
            end if;
            -- Step 2: the original source number binds the functional unit to that exchange's reviewed
            -- source tuple.
            if (v_reference_entry->>'source_exchange_number') is distinct from v_fu_source then
              perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
                'The functional-unit source exchange number is not the reference exchange''s reviewed source number',
                jsonb_build_object('action_id', v_action->>'action_id'));
            end if;
            -- Step 3: the reviewed leading quantity must be that exchange's own source quantity, so a
            -- functional unit can never be moved over a physically different amount.
            v_fu_quantity := substring(v_fu->>'before_text' from '^[0-9.]+');
            if v_fu_quantity is null
              or not private.dataset_alias_v2_amount_grammar_ok(v_fu_quantity)
              or not private.dataset_alias_v2_amount_grammar_ok(v_reference_entry->>'before_amount')
              or (v_fu_quantity)::numeric is distinct from (v_reference_entry->>'before_amount')::numeric then
              perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
                'The functional-unit quantity is not the reference exchange''s reviewed source quantity',
                jsonb_build_object('action_id', v_action->>'action_id'));
            end if;
            -- Step 4: when the stored reference exchange carries the reviewed source comment, it must name
            -- the same source tuple; a claim contradicting the stored source row fails closed.
            select stored_exchange.value->>'generalComment' into v_stored_comment
            from jsonb_array_elements(coalesce(v_action->'expected_json_ordered' #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) as stored_exchange
            where stored_exchange.value->>'@dataSetInternalID' = v_reference_internal;
            if v_stored_comment is not null
              and v_stored_comment !~ ('(^|[^0-9])' || v_fu_source || '([^0-9]|$)') then
              perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
                'The reviewed source comment of the reference exchange does not carry the declared source exchange number',
                jsonb_build_object('action_id', v_action->>'action_id'));
            end if;
          end;
        end if;
      end if;
    end loop;
    if (select count(*) from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows')
        <> (select count(distinct (a->>'id') || '|' || (a->>'version')) from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows')
      or (select count(*) from jsonb_array_elements(v_actions) as a where a->>'table' = 'processes')
        <> (select count(distinct (a->>'id') || '|' || (a->>'version')) from jsonb_array_elements(v_actions) as a where a->>'table' = 'processes') then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Duplicate action identities are refused');
    end if;
    if v_alias_fp_id is null then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'A v2 batch needs at least one flow action to identify the alias property');
    end if;

    -- The derived reference is the deployed five-key shape (root-verified against the live BAFU Time flow
    -- property snapshot): @refObjectId/@type/@uri/@version plus one language-tagged common:shortDescription
    -- object projected from the locked target row's own
    -- flowPropertyDataSet.flowPropertiesInformation.dataSetInformation["common:name"] — never from a
    -- Process-shaped name path and never invented. @type and the @uri convention come from the frozen
    -- before reference with the target id/version substituted; the claimed reference must equal them.
    declare
      v_before_reference jsonb := (
        select a->'expected_json_ordered' #> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet}'
        from jsonb_array_elements(v_actions) as a
        where a->>'table' = 'flows'
        limit 1
      );
      v_before_uri text := coalesce(v_before_reference->>'@uri', '');
      v_target_description jsonb := v_target_fp #> '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name}';
      v_target_id text := p_batch #>> '{target_snapshots,flowproperty,id}';
      v_target_version text := p_batch #>> '{target_snapshots,flowproperty,version}';
      v_derived_uri text;
    begin
      if jsonb_typeof(v_before_reference) <> 'object'
        or jsonb_typeof(v_target_description) <> 'object'
        or coalesce(v_target_description->>'#text', '') = '' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The target flow property must carry its language-tagged common:name object and the before reference must be an object');
      end if;
      if position(v_alias_fp_id in v_before_uri) = 0 then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The frozen before reference does not carry the alias flow-property id in its @uri');
      end if;
      v_derived_uri := replace(replace(v_before_uri, v_alias_fp_id, v_target_id), v_alias_fp_version, v_target_version);
      v_reference := jsonb_build_object(
        '@refObjectId', v_target_id,
        '@type', v_before_reference->>'@type',
        '@uri', v_derived_uri,
        '@version', v_target_version,
        'common:shortDescription', v_target_description
      );
      if v_reference->>'@type' is null
        or position(v_target_id in v_derived_uri) = 0
        or v_derived_uri !~ '\.json$' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The derived reference needs the reviewed type and the .json uri convention from the frozen before reference');
      end if;
      if p_batch->'target_snapshots'->'reference' is distinct from v_reference then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The declared target reference is not the canonical reference derived from the locked target row',
          jsonb_build_object('derived_reference', v_reference));
      end if;
    end;

    -- Validation and derivation pass: no writes yet. Every action is classified from the locked row and
    -- every fresh claim must equal the server derivation. A batch is either entirely fresh or an exact
    -- resubmission of an applied plan; a mixture is refused because an all-or-none plan cannot be half
    -- applied.
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
          if v_table = 'flows' then
            if (v_action #>> '{mutation,reference_id}') is distinct from v_reference->>'@refObjectId'
              or (v_action #>> '{mutation,reference_version}') is distinct from v_reference->>'@version' then
              perform private.dataset_alias_v2_deny('ALIAS_V2_DERIVE_MISMATCH', 409,
                'A flow mutation does not name the derived target reference',
                jsonb_build_object('action_id', v_action->>'action_id'));
            end if;
            v_derived := private.dataset_alias_v2_replace_flow_reference(v_before, v_reference);
          else
            v_derived := v_before;
            for v_entry in select * from jsonb_array_elements(coalesce(v_action->'mutation'->'exchanges', '[]'::jsonb)) loop
              v_derived := private.dataset_alias_v2_replace_exchange_amounts(v_derived, v_entry);
              if v_derived is null then
                perform private.dataset_alias_v2_deny('ALIAS_V2_DERIVE_MISMATCH', 409,
                  'An exchange instance does not bind the stored row', jsonb_build_object('action_id', v_action->>'action_id'));
              end if;
            end loop;
            if v_action->'mutation' ? 'functional_unit' then
              v_derived := private.dataset_alias_v2_replace_fu_text(v_derived, v_action->'mutation'->'functional_unit');
              if v_derived is null then
                perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
                  'The functional-unit text is not the reviewed leaf under the anchored rule',
                  jsonb_build_object('action_id', v_action->>'action_id'));
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
          v_fresh_count := v_fresh_count + 1;
          v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
            'action_id', v_action->>'action_id', 'table', v_table, 'id', v_action->>'id', 'version', v_action->>'version',
            'expected_modified_at', v_action->>'expected_modified_at',
            'before', v_before, 'desired', v_derived));
        elsif v_row_state is not distinct from 0 and v_row_payload = v_claim then
          v_replayed_count := v_replayed_count + 1;
          v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
            'action_id', v_action->>'action_id', 'table', v_table, 'id', v_action->>'id', 'version', v_action->>'version',
            'before', v_before, 'desired', v_claim, 'replayed', true));
        else
          perform private.dataset_alias_v2_deny('ALIAS_V2_ACTION_DRIFT', 409, 'An action no longer matches its frozen before content, owner, state or version', jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
      end;
    end loop;
    if v_fresh_count > 0 and v_replayed_count > 0 then
      perform private.dataset_alias_v2_deny('ALIAS_V2_REPLAY_CONFLICT', 409,
        'A batch cannot mix fresh and already-applied actions; submit the frozen plan once or resubmit it exactly',
        jsonb_build_object('fresh', v_fresh_count, 'replayed', v_replayed_count));
    end if;

    -- Claim-internal counts, the complement inside the selected processes and the source evidence count.
    for v_action in select * from jsonb_array_elements(v_actions) where value->>'table' = 'processes' loop
      select v_selected_exchanges + coalesce(jsonb_array_length(v_action->'expected_json_ordered' #> '{processDataSet,exchanges,exchange}'), 0) into v_selected_exchanges;
    end loop;
    v_occurrence_count := jsonb_array_length(v_batch_occurrences);
    v_unrelated := v_selected_exchanges - v_occurrence_count;
    if (p_batch #>> '{counts,action_count}')::integer is distinct from v_action_count
      or (p_batch #>> '{counts,flow_count}')::integer is distinct from jsonb_array_length(v_batch_flows)
      or (p_batch #>> '{counts,process_count}')::integer is distinct from v_action_count - jsonb_array_length(v_batch_flows)
      or (p_batch #>> '{counts,exchange_count}')::integer is distinct from v_occurrence_count
      or (p_batch #>> '{counts,unrelated_exchange_count}')::integer is distinct from v_unrelated
      or (p_batch #>> '{counts,flowproperty_count}')::integer is distinct from 0 then
      perform private.dataset_alias_v2_deny('ALIAS_V2_COUNT_MISMATCH', 409, 'Derived live counts differ from the submitted plan counts',
        jsonb_build_object('actions', v_action_count, 'flows', jsonb_array_length(v_batch_flows),
          'occurrences', v_occurrence_count, 'unrelated', v_unrelated));
    end if;
    if (p_batch #>> '{source_evidence,exchange_count}')::integer is distinct from v_occurrence_count then
      perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
        'The source evidence exchange count is not the batch exchange count',
        jsonb_build_object('recomputed_exchange_count', v_occurrence_count));
    end if;

    if v_replayed_count = 0 then
      -- Exact reference closure: every live consumer of the alias property, any owner, any state.
      select coalesce(jsonb_agg(jsonb_build_object('table', 'flows', 'id', f.id, 'version', f.version, 'state_code', f.state_code, 'user_id', f.user_id) order by f.id, f.version), '[]'::jsonb)
        into v_live_flows
      from public.flows f
      where f.json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}' = v_alias_fp_id
        and f.json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@version}' = v_alias_fp_version;
      -- One common keyed projection on both sides: the live consumer set must be exactly the claimed set,
      -- and no live consumer may be foreign or outside the owner-draft state.
      if (select coalesce(jsonb_agg(jsonb_build_object('id', live->>'id', 'version', live->>'version') order by live->>'id', live->>'version'), '[]'::jsonb)
            from jsonb_array_elements(v_live_flows) as live)
          is distinct from
         (select coalesce(jsonb_agg(jsonb_build_object('id', claimed->>'id', 'version', claimed->>'version') order by claimed->>'id', claimed->>'version'), '[]'::jsonb)
            from jsonb_array_elements(v_batch_flows) as claimed)
        or exists (
          select 1 from jsonb_array_elements(v_live_flows) as live
          where (live->>'state_code')::integer <> 0 or (live->>'user_id')::uuid <> v_actor
        ) then
        perform private.dataset_alias_v2_deny('ALIAS_V2_CLOSURE_MISMATCH', 409,
          'The live reference closure of the alias property differs from the claimed flow set, or holds a foreign or non-draft consumer',
          jsonb_build_object('live_flows', v_live_flows, 'claimed_flows', v_batch_flows));
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
          'The live exchange occurrences of the alias flows differ from the claimed instances, or hold a foreign or non-draft consumer',
          jsonb_build_object('live_occurrences', v_live_occurrences, 'claimed_occurrences', v_batch_occurrences));
      end if;

      -- Write pass: only after every action validated. Any raise here unwinds the whole subtransaction.
      declare
        v_committed_modified_at timestamptz;
        v_committed_payload jsonb;
        v_summary_id bigint;
        v_audit_rows jsonb := '[]'::jsonb;
        v_row_audit_id bigint;
      begin
        for v_action in select * from jsonb_array_elements(v_prepared) loop
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
          insert into private.command_audit_log (command, actor_user_id, target_table, target_id, target_version, payload)
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
          returning id into v_row_audit_id;
          v_audit_rows := v_audit_rows || jsonb_build_array(jsonb_build_object('action_id', v_action->>'action_id', 'audit_id', v_row_audit_id::text, 'after_sha256', private.dataset_alias_v2_payload_sha256(v_action->'desired')));
        end loop;

        insert into private.command_audit_log (command, actor_user_id, target_table, payload)
        values (v_command, v_actor, 'flows', jsonb_build_object(
          'record_type', 'plan', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
          'operation_id', v_operation_id, 'batch_id', v_batch_id, 'dimension', 'time', 'factor', v_factor,
          'action_count', v_action_count, 'fresh_actions', v_action_count, 'replayed_actions', 0,
          'fu_text_actions', v_fu_count,
          'source_evidence', p_batch->'source_evidence',
          'target_snapshots', p_batch->'target_snapshots',
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
    else
      -- Exact resubmission of an applied plan: every action already holds its claimed desired state. The
      -- durable proof is the committed audit chain plus the stored plan summary; nothing is written and the
      -- original closure is not re-asserted (it was proven when the plan applied).
      declare
        v_proof_id bigint;
        v_summary_payload jsonb;
      begin
        for v_action in select * from jsonb_array_elements(v_prepared) loop
          select audit_log.id into v_proof_id
          from private.command_audit_log as audit_log
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
          if v_proof_id is null then
            perform private.dataset_alias_v2_deny('ALIAS_V2_REPLAY_UNPROVEN', 409,
              'A desired-state row has no committed audit proof', jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
        end loop;
        select audit_log.id, audit_log.payload into v_proof_id, v_summary_payload
        from private.command_audit_log as audit_log
        where audit_log.command = v_command
          and audit_log.actor_user_id = v_actor
          and audit_log.payload->>'record_type' = 'plan'
          and audit_log.payload->>'plan_sha256' = v_plan_sha256
        order by audit_log.id desc limit 1;
        if v_summary_payload is null
          or v_summary_payload->'source_evidence' is distinct from p_batch->'source_evidence'
          or v_summary_payload->'target_snapshots' is distinct from p_batch->'target_snapshots' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_REPLAY_CONFLICT', 409,
            'The resubmission diverges from the stored plan summary');
        end if;
        return jsonb_build_object('ok', true, 'code', 'ALIAS_V2_BATCH_REPLAYED', 'status', 200,
          'idempotent_replay', true, 'plan_sha256', v_plan_sha256, 'batch_id', v_batch_id,
          'counts', v_summary_payload->'counts',
          'audit', jsonb_build_object('plan_summary_id', v_proof_id, 'replayed_actions', v_action_count));
      end;
    end if;
  exception
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'ALIAS_V2_LOCK_TIMEOUT', 'status', 409,
        'message', 'The v2 lock window could not be acquired; nothing was written');
    when others then
      -- All-or-none: the subtransaction's writes are already gone when this handler runs.
      get stacked diagnostics v_hint = pg_exception_hint, v_detail = pg_exception_detail;
      if sqlstate = 'P0001' then
        return jsonb_build_object('ok', false, 'code', sqlerrm, 'status',
          coalesce((nullif(v_hint, '')::jsonb->>'status')::integer, 409),
          'message', v_detail,
          'details', coalesce(nullif(v_hint, '')::jsonb->'details', '{}'::jsonb));
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
