-- Foundry #186 / Database #674: the Length*time fresh read closure re-validates the whole claim.
--
-- Root reproduced a proof gap (rollback-only probe): the closure labelled only the thirteen claimed
-- Process payload matches as live_closure_proof, so after a valid apply an extra live consumer of a
-- claimed Flow (39 -> 42 occurrences) or a rescaled canonical unit group (kmy 1000 -> 999) still
-- reported the fresh closure true. A live_closure_proof must not be a claimed-row-count tautology:
-- the profile's scientific meaning rests on the bound referents, so the read re-validates them.
--
-- The hardened closure re-checks, on the same read snapshot and without taking any lock:
--   1. every claimed read-only Flow: its live payload digest equals the plan's declared digest and the
--      row is still visible to the actor (published state 100, or a state-0 row owned by the actor);
--   2. the canonical FlowProperty and UnitGroup digests, and the unit group's own factor premise
--      (reference m*a at 1, kmy at the reviewed constant) at the canonical path;
--   3. the exact global occurrence closure: every live occurrence of the claimed flows, any owner and
--      any state, is exactly the plan's claimed instance set and every live occurrence is a state-0
--      row of the actor.
-- A false closure is reported as counts and booleans only; no foreign payload is ever returned.
-- Time's closure is untouched (its own evidence has not shown this defect).

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
  v_flow_drift bigint := 0;
  v_flow_checked bigint := 0;
  v_support_ok boolean := true;
  v_closure_ok boolean := true;
  v_claimed_occurrences bigint := 0;
  v_live_occurrences bigint := 0;
  v_closure_mismatch bigint := 0;
  v_fp jsonb;
  v_ug jsonb;
  v_units jsonb;
  v_reference_unit_id text;
  v_expected_text text;
begin
  if p_actor is null or jsonb_typeof(p_plan) is distinct from 'object' then
    return null;
  end if;
  v_claimed_rows := coalesce((p_plan #>> '{expected,action_count}')::bigint, -1);
  v_exchange_count := coalesce((p_plan #>> '{expected,exchange_count}')::bigint, -1);

  -- 1. The claimed Process rows must currently hold exactly their claimed desired payload.
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

  -- 2. The read-only Flow snapshots: payload digest and visibility, re-checked now.
  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'flow_snapshots', '[]'::jsonb)) loop
    v_flow_checked := v_flow_checked + 1;
    v_found := null;
    select true into v_found
    from public.flows as flow
    where flow.id = (v_action->>'id')::uuid
      and btrim(flow.version::text) = v_action->>'version'
      and (flow.state_code = 100 or (flow.state_code = 0 and flow.user_id = p_actor))
      and private.dataset_alias_v2_payload_sha256(flow.json_ordered::jsonb) = v_action->>'sha256';
    if not coalesce(v_found, false) then
      v_flow_drift := v_flow_drift + 1;
    end if;
  end loop;

  -- 3. The canonical support: both digests must still bind, and the unit group must still assert the
  --    reviewed ratio at its canonical quantitative-reference path.
  select flowproperty.json_ordered::jsonb into v_fp
  from public.flowproperties as flowproperty
  where flowproperty.id = (p_plan #>> '{target_flow_property,id}')::uuid
    and btrim(flowproperty.version::text) = (p_plan #>> '{target_flow_property,version}')
    and (flowproperty.state_code = 100 or (flowproperty.state_code = 0 and flowproperty.user_id = p_actor));
  select unitgroup.json_ordered::jsonb into v_ug
  from public.unitgroups as unitgroup
  where unitgroup.id = (p_plan #>> '{target_unit_group,id}')::uuid
    and btrim(unitgroup.version::text) = (p_plan #>> '{target_unit_group,version}')
    and (unitgroup.state_code = 100 or (unitgroup.state_code = 0 and unitgroup.user_id = p_actor));
  if v_fp is null or v_ug is null
    or private.dataset_alias_v2_payload_sha256(v_fp) is distinct from (p_plan #>> '{target_flow_property,sha256}')
    or private.dataset_alias_v2_payload_sha256(v_ug) is distinct from (p_plan #>> '{target_unit_group,sha256}') then
    v_support_ok := false;
  else
    v_units := case jsonb_typeof(v_ug #> '{unitGroupDataSet,units,unit}')
      when 'array' then v_ug #> '{unitGroupDataSet,units,unit}'
      when 'object' then jsonb_build_array(v_ug #> '{unitGroupDataSet,units,unit}')
      else '[]'::jsonb end;
    v_reference_unit_id := v_ug #>> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}';
    if v_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
          is distinct from (p_plan #>> '{target_unit_group,id}')
      or v_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}'
          is distinct from (p_plan #>> '{target_unit_group,version}')
      or coalesce(v_reference_unit_id, '') = ''
      or not exists (
        select 1 from jsonb_array_elements(v_units) as unit
        where unit->>'@dataSetInternalID' = v_reference_unit_id and unit->>'name' = 'm*a'
          and case when private.dataset_alias_v2_amount_grammar_ok(unit->>'meanValue')
            then (unit->>'meanValue')::numeric = 1 else false end)
      or not exists (
        select 1 from jsonb_array_elements(v_units) as unit
        where unit->>'name' = 'kmy'
          and case when private.dataset_alias_v2_amount_grammar_ok(unit->>'meanValue')
            then (unit->>'meanValue')::numeric = private.dataset_length_time_v1_factor() else false end) then
      v_support_ok := false;
    end if;
  end if;

  -- 4. The exact global occurrence closure, recomputed now: every live occurrence of every claimed
  --    Flow, any owner and any state, must be exactly the claimed instances, and each must be a
  --    state-0 row of this actor. A new consumer, a vanished one, a foreign one or a published one
  --    all fail this proof.
  select count(*) into v_claimed_occurrences
  from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) as action
  cross join lateral jsonb_array_elements(coalesce(action->'mutation'->'exchanges', '[]'::jsonb)) as instance;

  select count(*) into v_live_occurrences
  from public.processes as process
  cross join lateral jsonb_array_elements(
    coalesce(process.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) as exchange
  where exists (
    select 1 from jsonb_array_elements(coalesce(p_plan->'flow_snapshots', '[]'::jsonb)) as claimed
    where claimed->>'id' = exchange.value->'referenceToFlowDataSet'->>'@refObjectId'
      and claimed->>'version' = exchange.value->'referenceToFlowDataSet'->>'@version');

  select count(*) into v_closure_mismatch
  from public.processes as process
  cross join lateral jsonb_array_elements(
    coalesce(process.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) with ordinality as exchange
  where exists (
    select 1 from jsonb_array_elements(coalesce(p_plan->'flow_snapshots', '[]'::jsonb)) as claimed
    where claimed->>'id' = exchange.value->'referenceToFlowDataSet'->>'@refObjectId'
      and claimed->>'version' = exchange.value->'referenceToFlowDataSet'->>'@version')
    and (
      process.state_code <> 0
      or process.user_id <> p_actor
      or not exists (
        select 1 from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) as action
        cross join lateral jsonb_array_elements(coalesce(action->'mutation'->'exchanges', '[]'::jsonb)) as instance
        where action->>'id' = process.id::text
          and action->>'version' = btrim(process.version::text)
          and (instance->>'index')::integer = exchange.ordinality - 1
          and instance->>'internal_id' = exchange.value->>'@dataSetInternalID'
          and instance->>'direction' = exchange.value->>'exchangeDirection'));

  v_closure_ok := v_live_occurrences = v_claimed_occurrences and v_closure_mismatch = 0;

  return jsonb_build_object(
    'ok', v_rows = v_claimed_rows and v_claimed_rows >= 0 and v_flow_drift = 0 and v_support_ok and v_closure_ok,
    'live_closure_proof', v_rows = v_claimed_rows and v_claimed_rows >= 0 and v_flow_drift = 0 and v_support_ok and v_closure_ok,
    'row_count', v_rows,
    'claimed_row_count', v_claimed_rows,
    'exchange_count', v_exchange_count,
    'invalid_action_count', case when v_rows = v_claimed_rows then 0 else v_claimed_rows - v_rows end,
    'flow_snapshot_checked', v_flow_checked,
    'flow_snapshot_drift_count', v_flow_drift,
    'support_binding_ok', v_support_ok,
    'occurrence_closure_ok', v_closure_ok,
    'live_occurrence_count', v_live_occurrences,
    'claimed_occurrence_count', v_claimed_occurrences,
    'closure_mismatch_count', v_closure_mismatch,
    'proof_sha256', util.dataset_alias_execution_v2_artifact_sha256(
      jsonb_build_object('actor', p_actor, 'rows', v_rows, 'claimed_rows', v_claimed_rows,
        'exchange_count', v_exchange_count, 'plan_sha256', p_plan->>'plan_sha256',
        'flow_drift', v_flow_drift, 'support_ok', v_support_ok, 'closure_ok', v_closure_ok,
        'live_occurrences', v_live_occurrences, 'claimed_occurrences', v_claimed_occurrences)));
end
$$;

alter function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) owner to postgres;
revoke all on function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) from public;
comment on function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) is
  'Fresh Length*time primary closure readback: every claimed owner-draft process must hold its claimed desired payload, every claimed read-only flow must still match its declared digest and remain visible, the canonical property and unit group must still bind with the reviewed ratio, and the exact global occurrence closure of the claimed flows must still hold. Reported as counts and booleans only; no foreign payload is returned.';
