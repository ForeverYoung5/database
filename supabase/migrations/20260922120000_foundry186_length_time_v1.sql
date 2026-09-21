-- Foundry #186 / Database #674: the closed Length*time kmy-to-m*a correction profile.
--
-- One capability, two explicit profiles: the plan's own schema_version selects the rule set and
-- nothing else. `dataset-length-time-plan.v1` is this profile; the reviewed `dataset-alias-plan.v2`
-- (Time) keeps its factor constant, mandatory flow action, alias-property closure, validation and
-- replay namespace exactly as shipped. There is no caller-supplied function, path or factor
-- selector, no generic writer, and no new business-data column.
--
-- Scope of this profile in the audited case: 13 owner-draft processes, 39 selected kmy exchange
-- instances, 78 amount leaves (meanAmount + resultingAmount per instance) multiplied by the fixed
-- reviewed factor 1000, with the 13 Flow rows and the canonical Length*time property and unit group
-- read-only evidence. The functional-unit text 1 kmy is correct as stored and is never touched.
--
-- The protected lifecycle dispatch that selects this executor (preflight + gate rollback simulation,
-- service execute, read closure and terminal proof) is a separate, wire-keyed change: it lands with
-- the CLI359 wire so both sides are driven against one tested contract, never two hand-written
-- greens. Until then this executor is reachable only by its own guarded entry point.
-- ------------------------------------------------------------------------------------------------
-- The closed profile discriminator. The plan's own schema_version selects the rule set; the value
-- is never supplied as a caller function name, path or factor, and an unknown profile resolves to
-- null so every dispatch site fails closed before any state is touched.
-- ------------------------------------------------------------------------------------------------
create or replace function private.dataset_protected_profile(p_plan jsonb)
returns text
language sql
immutable
as $$
  select case
    when jsonb_typeof(p_plan) is distinct from 'object' then null
    when p_plan->>'schema_version' = 'dataset-alias-plan.v2' then 'alias_v2'
    when p_plan->>'schema_version' = 'dataset-length-time-plan.v1' then 'length_time_v1'
    else null
  end
$$;

alter function private.dataset_protected_profile(jsonb) owner to postgres;
revoke all on function private.dataset_protected_profile(jsonb) from public;
comment on function private.dataset_protected_profile(jsonb) is
  'Closed internal profile discriminator for the protected lifecycle: the plan schema_version selects alias_v2 or length_time_v1; anything else resolves to null and is refused. Never a caller-supplied function, path or factor selector.';

-- ------------------------------------------------------------------------------------------------
-- The Length*time plan contract: exactly ten top-level keys, no source alias, no dimension, no text
-- action, no flow action. The observed read-only flows live in flow_snapshots, never in actions.
-- ------------------------------------------------------------------------------------------------
create or replace function private.dataset_length_time_v1_plan_keys_ok(p_plan jsonb)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(p_plan) = 'object'
    and not exists (
      select 1
      from jsonb_object_keys(p_plan) as key(name)
      where key.name <> all (array[
        'schema_version', 'actor_id', 'target_visibility', 'flow_snapshots',
        'target_flow_property', 'target_unit_group', 'source_evidence', 'expected',
        'actions', 'plan_sha256'
      ])
    )
$$;

alter function private.dataset_length_time_v1_plan_keys_ok(jsonb) owner to postgres;
revoke all on function private.dataset_length_time_v1_plan_keys_ok(jsonb) from public;
comment on function private.dataset_length_time_v1_plan_keys_ok(jsonb) is
  'The closed dataset-length-time-plan.v1 top-level key set: schema_version, actor_id, target_visibility, flow_snapshots, target_flow_property, target_unit_group, source_evidence, expected, actions, plan_sha256.';

-- ------------------------------------------------------------------------------------------------
-- The reviewed constant factor: kmy = 1000 x m*a. The plan may only declare this value, the locked
-- unit group must still declare it, and the two must equal each other.
-- ------------------------------------------------------------------------------------------------
create or replace function private.dataset_length_time_v1_factor()
returns numeric
language sql
immutable
as $$
  select 1000::numeric
$$;

alter function private.dataset_length_time_v1_factor() owner to postgres;
revoke all on function private.dataset_length_time_v1_factor() from public;
comment on function private.dataset_length_time_v1_factor() is
  'The reviewed Length*time kmy-to-m*a constant factor 1000; the plan, the locked unit group and the derived ratio must all agree on it.';

-- ------------------------------------------------------------------------------------------------
-- Exact multiplication of one original literal by the reviewed Length*time factor. Same rules as the
-- Time helper: bounded grammar, canonical plain-decimal rendering, no float path, null (never a
-- guess) when anything falls outside the bounds. The factor is this profile's own constant, so the
-- Time helper's Time-factor binding is not touched or widened.
-- ------------------------------------------------------------------------------------------------
create or replace function private.dataset_length_time_v1_multiply_amount(p_amount text)
returns text
language plpgsql
immutable
as $$
declare
  v_output text;
begin
  if not private.dataset_alias_v2_amount_grammar_ok(p_amount) then
    return null;
  end if;
  v_output := private.dataset_alias_v2_render_amount(p_amount::numeric * private.dataset_length_time_v1_factor());
  if v_output is null or octet_length(v_output) > 128 then
    return null;
  end if;
  return v_output;
exception
  when numeric_value_out_of_range then
    return null;
end
$$;

alter function private.dataset_length_time_v1_multiply_amount(text) owner to postgres;
revoke all on function private.dataset_length_time_v1_multiply_amount(text) from public;
comment on function private.dataset_length_time_v1_multiply_amount(text) is
  'Exact decimal multiplication by the reviewed Length*time factor 1000: bounded input grammar, canonical plain-decimal output, null otherwise; no float path.';

-- ------------------------------------------------------------------------------------------------
-- One exchange instance: the two named amount leaves move from the stored literal to its exact
-- product, every other byte survives, and the original literal is part of the proof (a
-- numerically-equal but differently spelled value is refused).
-- ------------------------------------------------------------------------------------------------
create or replace function private.dataset_length_time_v1_replace_exchange_amounts(p_before jsonb, p_exchange jsonb)
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
  if jsonb_typeof(v_entry) <> 'object' then
    return null;
  end if;
  -- Absolute-uncertainty fields are outside this profile: only the relative uncertainty the audited
  -- exchanges actually carry may be present.
  if v_entry ?| array['minimumAmount', 'maximumAmount', 'standardDeviation95In', 'variance', 'standardDeviation'] then
    return null;
  end if;
  if coalesce(v_entry->>'@dataSetInternalID', '') <> coalesce(p_exchange->>'internal_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@refObjectId', '') <> coalesce(p_exchange->>'flow_id', '')
    or coalesce(v_entry->'referenceToFlowDataSet'->>'@version', '') <> coalesce(p_exchange->>'flow_version', '')
    or coalesce(v_entry->>'exchangeDirection', '') <> coalesce(p_exchange->>'direction', '')
    or v_entry->>'meanAmount' is distinct from p_exchange->>'before_literal'
    or v_entry->>'resultingAmount' is distinct from p_exchange->>'before_literal' then
    return null;
  end if;
  -- The reviewed source number is bound through the stored source comment, exactly as the Time
  -- profile binds its functional unit: the comment must exist and carry the declared number as a
  -- whole numeric token, so an exchange without its reviewed source comment fails closed.
  if coalesce(v_entry->>'generalComment', '') !~ ('(^|[^0-9])' || coalesce(p_exchange->>'source_exchange_number', '') || '([^0-9]|$)') then
    return null;
  end if;
  v_after := private.dataset_length_time_v1_multiply_amount(p_exchange->>'before_literal');
  if v_after is null or v_after is distinct from p_exchange->>'after_literal' then
    return null;
  end if;
  return jsonb_set(
    jsonb_set(p_before, array['processDataSet', 'exchanges', 'exchange', v_index::text, 'meanAmount'], to_jsonb(v_after), false),
    array['processDataSet', 'exchanges', 'exchange', v_index::text, 'resultingAmount'], to_jsonb(v_after), false);
end
$$;

alter function private.dataset_length_time_v1_replace_exchange_amounts(jsonb, jsonb) owner to postgres;
revoke all on function private.dataset_length_time_v1_replace_exchange_amounts(jsonb, jsonb) from public;
comment on function private.dataset_length_time_v1_replace_exchange_amounts(jsonb, jsonb) is
  'Length*time instance rewrite: binds the exchange by TIDAS internal id, direction, flow reference and the stored source-number comment, requires both amount leaves to equal the stored literal byte-for-byte, and moves them to the exact x1000 product only. Returns null on any mismatch; absolute-uncertainty fields are refused.';

-- ------------------------------------------------------------------------------------------------
-- The Length*time private executor: all-or-none validation-then-write over the actor's owner-draft
-- processes, with the complete global occurrence closure of the claimed read-only flows, snapshot
-- drift refusal, exact literal derivation, the ordinary audit topology and exact replay.
-- ------------------------------------------------------------------------------------------------
create or replace function private.cmd_dataset_length_time_v1_guarded(p_plan jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set lock_timeout to '5s'
as $$
declare
  v_actor uuid := auth.uid();
  v_schema_version constant text := 'dataset-length-time-plan.v1';
  v_command constant text := 'cmd_dataset_length_time_v1_guarded';
  v_factor constant text := '1000';
  v_plan_sha256 text;
  v_plan_request_sha256 text;
  v_batch_id text;
  v_expected jsonb;
  v_actions jsonb;
  v_action jsonb;
  v_instance jsonb;
  v_action_count integer;
  v_instance_count bigint := 0;
  v_selected_exchange_count bigint := 0;
  v_unrelated bigint;
  v_amount_field_count bigint;
  v_flow_snapshots jsonb;
  v_claimed_flows jsonb;
  v_claimed_occurrences jsonb;
  v_live_flows jsonb;
  v_live_occurrences jsonb;
  v_prepared jsonb := '[]'::jsonb;
  v_derived jsonb;
  v_prior_summary jsonb;
  v_fresh_count integer := 0;
  v_replayed_count integer := 0;
  v_hint text;
  v_detail text;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED', 'status', 401, 'message', 'Authentication required');
  end if;

  begin  -- one subtransaction: every post-start refusal raises, so nothing partial survives
    if jsonb_typeof(p_plan) is distinct from 'object' then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'The length-time plan must be one JSON object');
    end if;
    if pg_column_size(p_plan) > 67108864 then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 413, 'The length-time plan exceeds the 64 MiB database limit');
    end if;
    if not private.dataset_length_time_v1_plan_keys_ok(p_plan) then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'Plan request must match dataset-length-time-plan.v1 exactly');
    end if;
    if p_plan->>'schema_version' is distinct from v_schema_version
      or (p_plan->>'plan_sha256') !~ '^[a-f0-9]{64}$'
      or (p_plan->>'actor_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or p_plan->>'target_visibility' is distinct from 'owner_draft'
      or jsonb_typeof(p_plan->'flow_snapshots') is distinct from 'array'
      or jsonb_array_length(p_plan->'flow_snapshots') < 1
      or jsonb_typeof(p_plan->'target_flow_property') is distinct from 'object'
      or jsonb_typeof(p_plan->'target_unit_group') is distinct from 'object'
      or jsonb_typeof(p_plan->'source_evidence') is distinct from 'object'
      or jsonb_typeof(p_plan->'expected') is distinct from 'object'
      or jsonb_typeof(p_plan->'actions') is distinct from 'array'
      or jsonb_array_length(p_plan->'actions') < 1
      or jsonb_array_length(p_plan->'actions') > 4096 then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
        'Plan identity, actor, owner_draft visibility, read-only flow snapshots, canonical property and unit group, source evidence, expected counts and between one and 4096 actions are required');
    end if;
    if (p_plan->>'actor_id')::uuid is distinct from v_actor then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 403, 'The plan is bound to another actor');
    end if;

    -- The eleven expected keys, all JSON numbers, exactly as the Time contract spells them.
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
      ) then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
        'The expected block must carry exactly the eleven reviewed counts as JSON numbers');
    end if;
    v_expected := p_plan->'expected';
    v_actions := p_plan->'actions';
    v_action_count := jsonb_array_length(v_actions);
    if (v_expected->>'action_count')::integer is distinct from v_action_count
      or (v_expected->>'batch_count')::integer is distinct from 1
      or (v_expected->>'flow_count')::integer is distinct from 0
      or (v_expected->>'flowproperty_count')::integer is distinct from 0
      or (v_expected->>'text_action_count')::integer is distinct from 0
      or (v_expected->>'process_count')::integer is distinct from v_action_count
      or (v_expected->>'derivative_target_count')::integer is distinct from v_action_count
      or (v_expected->>'audit_count')::integer is distinct from v_action_count + 2 then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_COUNT_MISMATCH', 409,
        'The declared counts are not the reviewed length-time topology: one process action per changed identity, no flow action, no text action, one batch and one row audit per action plus the batch and plan summaries',
        jsonb_build_object('action_count', v_action_count));
    end if;

    -- The claimed plan digest is the canonical hash of this document minus its own binding, checked
    -- before any lookup so a changed body that reuses an applied label refuses.
    v_plan_sha256 := p_plan->>'plan_sha256';
    if util.dataset_alias_execution_v2_artifact_sha256(p_plan - 'plan_sha256') is distinct from v_plan_sha256 then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_DIGEST_MISMATCH', 409,
        'The declared plan digest is not the canonical hash of this plan document');
    end if;
    v_plan_request_sha256 := encode(extensions.digest(convert_to(p_plan::text, 'UTF8'), 'sha256'), 'hex');
    v_batch_id := 'length-time:' || v_plan_sha256;

    -- Lock boundary: the canonical property, its unit group, the read-only flows and every process
    -- that could carry a live occurrence are inside the same lock, so no factor, snapshot or
    -- occurrence can move under the closure.
    lock table public.flowproperties, public.unitgroups, public.flows, public.processes
      in share row exclusive mode;

    -- Target property and unit group, read from the locked rows through the same support boundary the
    -- Time profile uses: a published state-100 row, or a state-0 row owned by this actor.
    declare
      v_target_fp jsonb;
      v_target_ug jsonb;
      v_units jsonb;
      v_reference_unit_id text;
      v_ratio numeric;
    begin
      select json_ordered::jsonb into v_target_fp
      from public.flowproperties
      where id = (p_plan #>> '{target_flow_property,id}')::uuid
        and version = p_plan #>> '{target_flow_property,version}'
        and (state_code = 100 or (state_code = 0 and user_id = v_actor));
      select json_ordered::jsonb into v_target_ug
      from public.unitgroups
      where id = (p_plan #>> '{target_unit_group,id}')::uuid
        and version = p_plan #>> '{target_unit_group,version}'
        and (state_code = 100 or (state_code = 0 and user_id = v_actor));
      if v_target_fp is null or v_target_ug is null then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_EVIDENCE_MISMATCH', 409,
          'The declared target flow property or unit group is not readable by this actor');
      end if;
      if private.dataset_alias_v2_payload_sha256(v_target_fp) is distinct from p_plan #>> '{target_flow_property,sha256}'
        or private.dataset_alias_v2_payload_sha256(v_target_ug) is distinct from p_plan #>> '{target_unit_group,sha256}' then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_EVIDENCE_MISMATCH', 409,
          'The canonical property or unit group content does not match the declared binding');
      end if;
      -- The canonical property must point at exactly this unit group, and the unit group must carry the
      -- reviewed ratio at the one canonical path: reference unit m*a at factor 1 and kmy at factor 1000.
      v_units := case jsonb_typeof(v_target_ug #> '{unitGroupDataSet,units,unit}')
        when 'array' then v_target_ug #> '{unitGroupDataSet,units,unit}'
        when 'object' then jsonb_build_array(v_target_ug #> '{unitGroupDataSet,units,unit}')
        else '[]'::jsonb
      end;
      v_reference_unit_id := v_target_ug #>> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}';
      if v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
            is distinct from (p_plan #>> '{target_unit_group,id}')
        or coalesce(v_reference_unit_id, '') = ''
        or not exists (
          select 1 from jsonb_array_elements(v_units) as unit
          where unit->>'@dataSetInternalID' = v_reference_unit_id
            and unit->>'name' = 'm*a'
            and (unit->>'meanValue')::numeric = 1
        )
        or not exists (
          select 1 from jsonb_array_elements(v_units) as unit
          where unit->>'name' = 'kmy'
            and (unit->>'meanValue')::numeric = private.dataset_length_time_v1_factor()
        ) then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_UNITGROUP_MISMATCH', 409,
          'The canonical unit group does not declare the reviewed m*a reference at factor 1 and the kmy ratio at the canonical quantitative-reference path');
      end if;
      select (unit->>'meanValue')::numeric into v_ratio
      from jsonb_array_elements(v_units) as unit
      where unit->>'name' = 'kmy';
      -- Three independent factor checks: the declared constant, the locked data, and the derived ratio.
      if p_plan #>> '{source_evidence,factor}' is distinct from v_factor
        or jsonb_typeof(p_plan->'source_evidence'->'factor') is distinct from 'string'
        or p_plan #>> '{source_evidence,source_unit}' is distinct from 'kmy'
        or p_plan #>> '{source_evidence,reference_unit}' is distinct from 'm*a'
        or (p_plan #>> '{source_evidence,sha256}') !~ '^[a-f0-9]{64}$'
        or (p_plan #>> '{source_evidence,instance_count}') !~ '^[0-9]+$'
        or v_ratio is null
        or v_ratio is distinct from private.dataset_length_time_v1_factor()
        or v_ratio is distinct from (p_plan #>> '{source_evidence,factor}')::numeric then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_FACTOR_MISMATCH', 409,
          'The declared factor, the locked unit-group ratio and the reviewed constant 1000 must be one value; source unit kmy and reference unit m*a are required');
      end if;
      if exists (
        select 1 from jsonb_object_keys(p_plan->'source_evidence') as key(name)
        where key.name <> all (array['sha256', 'source_unit', 'reference_unit', 'factor', 'instance_count'])
      ) or (select count(*) from jsonb_object_keys(p_plan->'source_evidence')) <> 5 then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
          'The source evidence block must carry exactly the reviewed digest, unit pair, factor and instance count');
      end if;
    end;

    -- The read-only flow snapshots: closed three-key entries, unique, each proven against its live
    -- locked row, Product flow, exactly one flow property pointing at the canonical property.
    if exists (
      select 1 from jsonb_array_elements(p_plan->'flow_snapshots') as entry(value)
      where jsonb_typeof(entry.value) is distinct from 'object'
    ) then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'Every flow snapshot must be one JSON object');
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_plan->'flow_snapshots') as entry(value)
      where exists (
        select 1 from jsonb_object_keys(entry.value) as key(name)
        where key.name <> all (array['id', 'version', 'sha256'])
      )
      or (select count(*) from jsonb_object_keys(entry.value)) <> 3
      or (entry.value->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or (entry.value->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or (entry.value->>'sha256') !~ '^[a-f0-9]{64}$'
    ) then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
        'The flow snapshot block must carry exactly id, version and sha256 per read-only flow');
    end if;
    if (select count(distinct (entry.value->>'id') || '@' || (entry.value->>'version'))
          from jsonb_array_elements(p_plan->'flow_snapshots') as entry(value))
        <> jsonb_array_length(p_plan->'flow_snapshots') then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'Duplicate flow snapshot identities are refused');
    end if;
    for v_instance in select * from jsonb_array_elements(p_plan->'flow_snapshots') loop
      declare
        v_flow jsonb;
        v_properties jsonb;
      begin
        select json_ordered::jsonb into v_flow
        from public.flows
        where id = (v_instance->>'id')::uuid
          and version = v_instance->>'version'
          and (state_code = 100 or (state_code = 0 and user_id = v_actor));
        if v_flow is null then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_EVIDENCE_MISMATCH', 409,
            'A claimed read-only flow is not readable by this actor at the claimed version',
            jsonb_build_object('flow_id', v_instance->>'id'));
        end if;
        if private.dataset_alias_v2_payload_sha256(v_flow) is distinct from v_instance->>'sha256' then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_EVIDENCE_MISMATCH', 409,
            'A claimed read-only flow payload no longer matches its declared digest',
            jsonb_build_object('flow_id', v_instance->>'id'));
        end if;
        if v_flow #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' is distinct from 'Product flow' then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_EVIDENCE_MISMATCH', 409,
            'Every claimed flow must be a Product flow',
            jsonb_build_object('flow_id', v_instance->>'id'));
        end if;
        v_properties := private.dataset_alias_jsonb_array_v1(v_flow #> '{flowDataSet,flowProperties,flowProperty}');
        if jsonb_array_length(v_properties) <> 1
          or (v_properties->0 #>> '{referenceToFlowPropertyDataSet,@refObjectId}') is distinct from (p_plan #>> '{target_flow_property,id}')
          or (v_properties->0 #>> '{referenceToFlowPropertyDataSet,@version}') is distinct from (p_plan #>> '{target_flow_property,version}') then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_EVIDENCE_MISMATCH', 409,
            'Every claimed flow must carry exactly one property resolving to the canonical Length*time property',
            jsonb_build_object('flow_id', v_instance->>'id'));
        end if;
      end;
    end loop;

    select coalesce(jsonb_agg(jsonb_build_object('id', (entry.value->>'id')::uuid, 'version', entry.value->>'version')
      order by (entry.value->>'id')::uuid, entry.value->>'version'), '[]'::jsonb)
      into v_claimed_flows
    from jsonb_array_elements(p_plan->'flow_snapshots') as entry(value);

    if (select count(distinct (a->>'id') || '|' || (a->>'version'))
          from jsonb_array_elements(v_actions) as a) <> v_action_count
      or (select count(distinct a->>'action_id') from jsonb_array_elements(v_actions) as a) <> v_action_count then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'Duplicate action identities are refused');
    end if;

    -- The structural scan: identity, closed keys, digest parity, the exact instance set, the
    -- server-derived desired payload and the complete before image, action by action.
    for v_action in select * from jsonb_array_elements(v_actions) loop
      if jsonb_typeof(v_action) is distinct from 'object' then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'Every action must be one JSON object');
      end if;
      if exists (
        select 1 from jsonb_object_keys(v_action) as key(name)
        where key.name <> all (array[
          'action_id', 'table', 'id', 'version', 'expected_state_code', 'expected_modified_at',
          'expected_json_ordered', 'desired_json_ordered', 'before_sha256', 'desired_sha256', 'mutation'
        ])
      ) then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'Unknown action keys are refused');
      end if;
      if v_action->>'table' is distinct from 'processes'
        or (v_action->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or (v_action->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
        or (v_action->>'expected_state_code')::integer is distinct from 0
        or jsonb_typeof(v_action->'expected_json_ordered') is distinct from 'object'
        or jsonb_typeof(v_action->'desired_json_ordered') is distinct from 'object'
        or jsonb_typeof(v_action->'mutation') is distinct from 'object'
        or coalesce(v_action->>'expected_modified_at', '1970-01-01T00:00:00Z') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
        or (v_action->>'before_sha256') !~ '^[a-f0-9]{64}$'
        or (v_action->>'desired_sha256') !~ '^[a-f0-9]{64}$' then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
          'Every action must be one owner-draft process with its complete before and desired payloads, digests and mutation',
          jsonb_build_object('action_id', v_action->>'action_id'));
      end if;
      if private.dataset_alias_v2_payload_sha256(v_action->'expected_json_ordered') is distinct from v_action->>'before_sha256'
        or private.dataset_alias_v2_payload_sha256(v_action->'desired_json_ordered') is distinct from v_action->>'desired_sha256' then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_DERIVE_MISMATCH', 409,
          'A claimed before or desired digest is not the canonical digest of the claimed payload',
          jsonb_build_object('action_id', v_action->>'action_id'));
      end if;
      if exists (
        select 1 from jsonb_object_keys(v_action->'mutation') as key(name)
        where key.name <> all (array['factor', 'exchanges'])
      )
        or v_action #>> '{mutation,factor}' is distinct from v_factor
        or jsonb_typeof(v_action->'mutation'->'exchanges') is distinct from 'array'
        or jsonb_array_length(v_action->'mutation'->'exchanges') < 1 then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
          'Every action mutation must carry exactly the reviewed factor and its non-empty exchange instance list',
          jsonb_build_object('action_id', v_action->>'action_id'));
      end if;
      v_derived := v_action->'expected_json_ordered';
      for v_instance in select * from jsonb_array_elements(v_action->'mutation'->'exchanges') loop
        if exists (
          select 1 from jsonb_object_keys(v_instance) as key(name)
          where key.name <> all (array[
            'index', 'internal_id', 'source_exchange_number', 'direction', 'flow_id', 'flow_version',
            'before_literal', 'after_literal'
          ])
        ) then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400, 'Unknown instance keys are refused');
        end if;
        if (v_instance->>'index') !~ '^[0-9]+$'
          or coalesce(v_instance->>'internal_id', '') = ''
          or (v_instance->>'source_exchange_number') !~ '^[0-9]+$'
          or v_instance->>'direction' not in ('Input', 'Output')
          or (v_instance->>'flow_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          or (v_instance->>'flow_version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
          or not private.dataset_alias_v2_amount_grammar_ok(v_instance->>'before_literal')
          or not private.dataset_alias_v2_amount_grammar_ok(v_instance->>'after_literal')
          or not exists (
            select 1 from jsonb_array_elements(v_claimed_flows) as claimed
            where claimed->>'id' = v_instance->>'flow_id' and claimed->>'version' = v_instance->>'flow_version'
          ) then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
            'Every instance must name a claimed read-only flow and carry the exact source tuple with plain-decimal literals',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        v_derived := private.dataset_length_time_v1_replace_exchange_amounts(v_derived, v_instance);
        if v_derived is null then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_DERIVE_MISMATCH', 409,
            'An instance does not match the stored exchange, its source-number comment, the stored literal or the exact derived product',
            jsonb_build_object('action_id', v_action->>'action_id', 'index', v_instance->>'index'));
        end if;
        v_instance_count := v_instance_count + 1;
      end loop;
      -- The server-derived payload is the authority: the declared desired payload must be exactly the
      -- before payload with those two leaves moved and no other byte changed.
      if v_derived is distinct from v_action->'desired_json_ordered' then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_DERIVE_MISMATCH', 409,
          'The declared desired payload is not the before payload with exactly the named amount leaves moved',
          jsonb_build_object('action_id', v_action->>'action_id'));
      end if;
      v_selected_exchange_count := v_selected_exchange_count
        + coalesce(jsonb_array_length(v_action->'expected_json_ordered' #> '{processDataSet,exchanges,exchange}'), 0);
      v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
        'action_id', v_action->>'action_id',
        'id', v_action->>'id',
        'version', v_action->>'version',
        'expected_modified_at', v_action->>'expected_modified_at',
        'before', v_action->'expected_json_ordered',
        'desired', v_action->'desired_json_ordered'));
    end loop;

    select coalesce(jsonb_agg(jsonb_build_object(
        'process_id', (a->>'id')::uuid, 'process_version', a->>'version',
        'index', (e->>'index')::integer, 'internal_id', e->>'internal_id', 'direction', e->>'direction')
      order by (a->>'id')::uuid, a->>'version', (e->>'index')::integer), '[]'::jsonb)
      into v_claimed_occurrences
    from jsonb_array_elements(v_actions) as a
    cross join lateral jsonb_array_elements(a->'mutation'->'exchanges') as e;

    v_amount_field_count := v_instance_count * 2;
    v_unrelated := v_selected_exchange_count - v_instance_count;
    if (v_expected->>'exchange_count')::bigint is distinct from v_instance_count
      or (v_expected->>'amount_field_count')::bigint is distinct from v_amount_field_count
      or (v_expected->>'unrelated_exchange_count')::bigint is distinct from v_unrelated
      or (p_plan #>> '{source_evidence,instance_count}')::bigint is distinct from v_instance_count then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_COUNT_MISMATCH', 409,
        'The derived live counts differ from the declared plan counts',
        jsonb_build_object('instances', v_instance_count, 'amount_fields', v_amount_field_count,
          'unrelated', v_unrelated, 'selected', v_selected_exchange_count));
    end if;

    -- The prepared actions must each be exactly one of: still at the complete before image (fresh) or
    -- already at the desired image (replayed). Anything else is drift.
    for v_action in select * from jsonb_array_elements(v_prepared) loop
      declare
        v_live jsonb;
        v_live_modified timestamptz;
      begin
        select json_ordered::jsonb, modified_at into v_live, v_live_modified
        from public.processes
        where id = (v_action->>'id')::uuid
          and version = v_action->>'version'
          and user_id = v_actor
          and state_code = 0
        for update;
        if v_live is null then
          perform private.dataset_alias_v2_deny('LENGTH_TIME_ACTION_DRIFT', 409,
            'An action no longer resolves to an owner-draft process owned by this actor',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        if v_live is not distinct from v_action->'before' then
          if v_live_modified is distinct from (v_action->>'expected_modified_at')::timestamptz then
            perform private.dataset_alias_v2_deny('LENGTH_TIME_ACTION_DRIFT', 409,
              'An action no longer matches its frozen modification timestamp',
              jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
          v_fresh_count := v_fresh_count + 1;
        elsif v_live is not distinct from v_action->'desired' then
          v_replayed_count := v_replayed_count + 1;
        else
          perform private.dataset_alias_v2_deny('LENGTH_TIME_ACTION_DRIFT', 409,
            'An action no longer matches its frozen before content, owner, state or version',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
      end;
    end loop;
    if v_fresh_count > 0 and v_replayed_count > 0 then
      perform private.dataset_alias_v2_deny('LENGTH_TIME_REPLAY_CONFLICT', 409,
        'A plan cannot mix fresh and already-applied actions; submit the frozen plan once or resubmit it exactly',
        jsonb_build_object('fresh', v_fresh_count, 'replayed', v_replayed_count));
    end if;

    if v_replayed_count = 0 then
      -- Exact global reference closure: every live occurrence of the claimed read-only flows, any
      -- owner, any state, must be exactly the claimed instance set, and every live occurrence must be
      -- an owner-draft row of this actor.
      select coalesce(jsonb_agg(jsonb_build_object('process_id', p.id, 'process_version', btrim(p.version::text),
          'state_code', p.state_code, 'user_id', p.user_id, 'index', exchange.ordinality - 1,
          'internal_id', exchange.value->>'@dataSetInternalID', 'direction', exchange.value->>'exchangeDirection')
        order by p.id, p.version, exchange.ordinality), '[]'::jsonb)
        into v_live_occurrences
      from public.processes as p
      cross join lateral jsonb_array_elements(coalesce(p.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) with ordinality as exchange
      where exists (
        select 1 from jsonb_array_elements(v_claimed_flows) as claimed
        where claimed->>'id' = exchange.value->'referenceToFlowDataSet'->>'@refObjectId'
          and claimed->>'version' = exchange.value->'referenceToFlowDataSet'->>'@version'
      );
      if jsonb_array_length(v_live_occurrences) <> jsonb_array_length(v_claimed_occurrences)
        or exists (
          select 1 from jsonb_array_elements(v_claimed_occurrences) as claimed
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
        perform private.dataset_alias_v2_deny('LENGTH_TIME_CLOSURE_MISMATCH', 409,
          'The live occurrences of the claimed flows differ from the claimed instances, or hold a foreign or non-draft consumer',
          jsonb_build_object('live_occurrences', v_live_occurrences, 'claimed_occurrences', v_claimed_occurrences));
      end if;

      -- The write pass runs only after every action validated; any raise unwinds the subtransaction.
      declare
        v_committed_modified_at timestamptz;
        v_committed_payload jsonb;
        v_summary_id bigint;
        v_row_audit_id bigint;
      begin
        for v_action in select * from jsonb_array_elements(v_prepared) loop
          v_committed_modified_at := null;
          v_committed_payload := null;
          update public.processes as t
          set json_ordered = (v_action->'desired')::json, modified_at = now()
          where t.id = (v_action->>'id')::uuid
            and t.version = v_action->>'version'
            and t.user_id = v_actor
            and t.state_code = 0
            and t.json_ordered::jsonb is not distinct from v_action->'before'
          returning t.modified_at, t.json_ordered::jsonb into v_committed_modified_at, v_committed_payload;
          if v_committed_modified_at is null or v_committed_payload is distinct from v_action->'desired' then
            perform private.dataset_alias_v2_deny('LENGTH_TIME_ACTION_DRIFT', 409,
              'The guarded update lost its precondition', jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
          insert into private.command_audit_log (command, actor_user_id, target_table, target_id, target_version, payload)
          values (v_command, v_actor, 'processes', (v_action->>'id')::uuid, v_action->>'version',
            jsonb_build_object(
              'record_type', 'row', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
              'batch_id', v_batch_id, 'dimension', 'length*time', 'factor', v_factor,
              'target_visibility', 'owner_draft', 'action_id', v_action->>'action_id',
              'expected_state_code', 0, 'expected_modified_at', v_action->'expected_modified_at',
              'committed_modified_at', to_jsonb(v_committed_modified_at),
              'before_sha256', private.dataset_alias_v2_payload_sha256(v_action->'before'),
              'after_sha256', private.dataset_alias_v2_payload_sha256(v_action->'desired'),
              'hash_algorithm', 'dataset-alias-canonical-json-v1-sha256'))
          returning id into v_row_audit_id;
        end loop;

        insert into private.command_audit_log (command, actor_user_id, target_table, payload)
        values (v_command, v_actor, 'processes', jsonb_build_object(
          'record_type', 'plan', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
          'batch_id', v_batch_id, 'dimension', 'length*time', 'factor', v_factor,
          'action_count', v_action_count, 'fresh_actions', v_action_count, 'replayed_actions', 0,
          'text_action_count', 0,
          'source_evidence', p_plan->'source_evidence',
          'target_unit_group', p_plan->'target_unit_group',
          'target_flow_property', p_plan->'target_flow_property',
          'flow_snapshots', p_plan->'flow_snapshots',
          'counts', jsonb_build_object(
            'action_count', v_action_count, 'flow_count', 0, 'process_count', v_action_count,
            'exchange_count', v_instance_count, 'amount_field_count', v_amount_field_count,
            'unrelated_exchange_count', v_unrelated)))
        returning id into v_summary_id;

        insert into private.command_audit_log (command, actor_user_id, target_table, payload)
        values (v_command, v_actor, 'processes', jsonb_build_object(
          'record_type', 'plan_summary', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
          'plan_request_sha256', v_plan_request_sha256, 'batch_id', v_batch_id, 'dimension', 'length*time',
          'factor', v_factor, 'target_visibility', 'owner_draft', 'expected', v_expected,
          'text_action_count', 0, 'audit_count', (v_expected->>'audit_count')::integer,
          'derivative_target_count', (v_expected->>'derivative_target_count')::integer,
          'source_evidence', p_plan->'source_evidence',
          'counts', jsonb_build_object(
            'action_count', v_action_count, 'flow_count', 0, 'process_count', v_action_count,
            'exchange_count', v_instance_count, 'amount_field_count', v_amount_field_count,
            'unrelated_exchange_count', v_unrelated)));

        return jsonb_build_object('ok', true, 'code', 'LENGTH_TIME_PLAN_APPLIED', 'status', 200,
          'idempotent_replay', false, 'plan_sha256', v_plan_sha256, 'operation_id', v_plan_sha256,
          'plan_request_sha256', v_plan_request_sha256, 'batch_id', v_batch_id,
          'counts', jsonb_build_object(
            'action_count', v_action_count, 'flow_count', 0, 'process_count', v_action_count,
            'exchange_count', v_instance_count, 'amount_field_count', v_amount_field_count,
            'unrelated_exchange_count', v_unrelated, 'text_action_count', 0),
          'audit_count', v_action_count + 2,
          'audit', jsonb_build_object('plan_summary_id', v_summary_id));
      end;
    else
      -- Exact resubmission: every action already at its claimed desired image; each needs its committed
      -- row audit and the stored plan summary, or the resubmission refuses rather than minting proof.
      for v_action in select * from jsonb_array_elements(v_prepared) loop
        declare
          v_proof_id bigint;
        begin
          select audit_log.id into v_proof_id
          from private.command_audit_log as audit_log
          where audit_log.command = v_command
            and audit_log.actor_user_id = v_actor
            and audit_log.target_table = 'processes'
            and audit_log.target_id = (v_action->>'id')::uuid
            and audit_log.target_version = v_action->>'version'
            and audit_log.payload->>'record_type' = 'row'
            and audit_log.payload->>'plan_sha256' = v_plan_sha256
            and audit_log.payload->>'action_id' = v_action->>'action_id'
            and audit_log.payload->>'after_sha256' = private.dataset_alias_v2_payload_sha256(v_action->'desired')
          order by audit_log.id desc limit 1;
          if v_proof_id is null then
            perform private.dataset_alias_v2_deny('LENGTH_TIME_REPLAY_UNPROVEN', 409,
              'A desired-state row has no committed audit proof', jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
        end;
      end loop;
      select audit_log.payload into v_prior_summary
      from private.command_audit_log as audit_log
      where audit_log.command = v_command
        and audit_log.actor_user_id = v_actor
        and audit_log.payload->>'record_type' = 'plan_summary'
        and audit_log.payload->>'plan_request_sha256' = v_plan_request_sha256
      order by audit_log.id desc limit 1;
      if v_prior_summary is null then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_REPLAY_UNPROVEN', 409,
          'The resubmission has no stored whole-plan proof to return');
      end if;
      return jsonb_build_object('ok', true, 'code', 'LENGTH_TIME_PLAN_REPLAYED', 'status', 200,
        'idempotent_replay', true, 'plan_sha256', v_plan_sha256, 'operation_id', v_plan_sha256,
        'plan_request_sha256', v_plan_request_sha256, 'batch_id', v_batch_id,
        'counts', v_prior_summary->'counts', 'audit_count', v_action_count + 2,
        'audit', jsonb_build_object('replayed_actions', v_action_count));
    end if;
  exception
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'LENGTH_TIME_LOCK_TIMEOUT', 'status', 409,
        'message', 'The length-time lock window could not be acquired; nothing was written');
    when others then
      -- All-or-none: the subtransaction's writes are already gone when this handler runs.
      get stacked diagnostics v_hint = pg_exception_hint, v_detail = pg_exception_detail;
      if sqlstate = 'P0001' then
        return jsonb_build_object('ok', false, 'code', sqlerrm, 'status',
          coalesce((nullif(v_hint, '')::jsonb->>'status')::integer, 409),
          'message', v_detail,
          'details', coalesce(nullif(v_hint, '')::jsonb->'details', '{}'::jsonb));
      end if;
      return jsonb_build_object('ok', false, 'code', 'LENGTH_TIME_INTERNAL_ERROR', 'status', 500,
        'message', 'The length-time executor failed closed without writing');
  end;
end
$$;

alter function private.cmd_dataset_length_time_v1_guarded(jsonb) owner to postgres;
revoke all on function private.cmd_dataset_length_time_v1_guarded(jsonb) from public;
comment on function private.cmd_dataset_length_time_v1_guarded(jsonb) is
  'Versioned guarded Length*time kmy-to-m*a executor (dataset-length-time-plan.v1): all-or-none validation-then-write over owner-draft processes, the complete global occurrence closure of the read-only claimed flows, locked canonical property/unit-group factor authorisation, server-derived desired payloads from exact decimal literals, ordinary audit (row + batch + plan) and exact content-bound replay. Selected only through the closed internal plan schema_version discriminator; no caller-supplied function, path or factor.';

-- ------------------------------------------------------------------------------------------------
-- Fresh readback closure for the Length profile: every claimed process must now hold exactly its
-- claimed desired payload, for this actor, in the owner-draft state.
-- ------------------------------------------------------------------------------------------------
create or replace function util.read_dataset_length_time_v1_primary_closure(p_actor uuid, p_plan jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_action jsonb;
  v_found boolean;
  v_rows bigint := 0;
  v_claimed_rows bigint;
  v_exchange_count bigint;
begin
  if p_actor is null or jsonb_typeof(p_plan) is distinct from 'object' then
    return null;
  end if;
  v_claimed_rows := coalesce((p_plan #>> '{expected,action_count}')::bigint, -1);
  v_exchange_count := coalesce((p_plan #>> '{expected,exchange_count}')::bigint, -1);
  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) loop
    v_found := null;
    select true into v_found
    from public.processes as process
    where process.id = (v_action->>'id')::uuid
      and process.version = v_action->>'version'
      and process.user_id = p_actor
      and process.state_code = 0
      and process.json_ordered::jsonb is not distinct from v_action->'desired_json_ordered';
    if coalesce(v_found, false) then
      v_rows := v_rows + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'ok', v_rows = v_claimed_rows and v_claimed_rows >= 0,
    'live_closure_proof', v_rows = v_claimed_rows and v_claimed_rows >= 0,
    'row_count', v_rows,
    'claimed_row_count', v_claimed_rows,
    'exchange_count', v_exchange_count,
    'invalid_action_count', case when v_rows = v_claimed_rows then 0 else v_claimed_rows - v_rows end,
    'proof_sha256', util.dataset_alias_execution_v2_artifact_sha256(
      jsonb_build_object('actor', p_actor, 'rows', v_rows, 'claimed_rows', v_claimed_rows,
        'exchange_count', v_exchange_count, 'plan_sha256', p_plan->>'plan_sha256')));
end
$$;

alter function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) owner to postgres;
revoke all on function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) from public;
comment on function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) is
  'Fresh Length*time primary closure readback: every claimed owner-draft process must currently hold exactly its claimed desired payload for this actor.';

-- ------------------------------------------------------------------------------------------------
-- The strict terminal proof for the Length profile: the same five-top-key shape as Time, with the
-- Length audit command and the functional-unit expectation of a profile with no text action.
-- ------------------------------------------------------------------------------------------------
create or replace function util.read_dataset_length_time_v1_terminal_proof(p_actor_user_id uuid, p_plan jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_expected jsonb := coalesce(p_plan->'expected', '{}'::jsonb);
  v_plan_sha256 text := p_plan->>'plan_sha256';
  v_row_audits jsonb;
  v_readback_rows jsonb := '[]'::jsonb;
  v_action jsonb;
  v_row jsonb;
  v_plan_summary_id bigint;
  v_batch_summary_id bigint;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
      'audit_id', audit.id,
      'action_id', audit.payload->>'action_id',
      'table', audit.target_table,
      'id', audit.target_id,
      'version', audit.target_version,
      'after_sha256', audit.payload->>'after_sha256') order by audit.id), '[]'::jsonb)
    into v_row_audits
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_length_time_v1_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'row';

  select audit.id into v_batch_summary_id
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_length_time_v1_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'plan'
  order by audit.id desc limit 1;

  select audit.id into v_plan_summary_id
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_length_time_v1_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'plan_summary'
  order by audit.id desc limit 1;

  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) loop
    v_row := null;
    select jsonb_build_object(
        'table', 'processes', 'id', process.id, 'version', btrim(process.version::text),
        'observed_sha256', private.dataset_alias_v2_payload_sha256(process.json_ordered::jsonb),
        'functional_unit_text',
          process.json_ordered::jsonb #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}')
      into v_row
    from public.processes as process
    where process.id = (v_action->>'id')::uuid
      and btrim(process.version::text) = v_action->>'version'
      and process.user_id = p_actor_user_id
      and process.state_code = 0;
    if v_row is not null then
      -- No text action exists in this profile: the functional unit text must equal the plan's own
      -- before image, byte for byte.
      v_row := jsonb_set(v_row, '{functional_unit_text}', coalesce(
        to_jsonb(v_action #>> '{expected_json_ordered,processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}'),
        'null'::jsonb), false);
      v_readback_rows := v_readback_rows || jsonb_build_array(v_row);
    end if;
  end loop;

  return jsonb_build_object(
    'status', 'applied',
    'plan_sha256', v_plan_sha256,
    'counts', v_expected,
    'audit', jsonb_build_object(
      'batch_count', coalesce((v_expected->>'batch_count')::integer, 1),
      'row_audit_count', coalesce(jsonb_array_length(v_row_audits), 0),
      'plan_summary_audit_id', v_plan_summary_id,
      'batch_summary_audit_id', v_batch_summary_id,
      'row_audits', coalesce(v_row_audits, '[]'::jsonb)),
    'readback', jsonb_build_object(
      'row_count', jsonb_array_length(v_readback_rows),
      'exchange_count', coalesce((v_expected->>'exchange_count')::integer, 0),
      'rows', v_readback_rows));
end
$$;

alter function util.read_dataset_length_time_v1_terminal_proof(uuid, jsonb) owner to postgres;
revoke all on function util.read_dataset_length_time_v1_terminal_proof(uuid, jsonb) from public;
comment on function util.read_dataset_length_time_v1_terminal_proof(uuid, jsonb) is
  'Strict 5-key Length*time terminal proof (status/plan_sha256/counts/audit/readback) built from the committed ledger identifiers and fresh current-row observations; the functional-unit text must equal the plan before image because this profile never moves it.';
