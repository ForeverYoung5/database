CREATE OR REPLACE FUNCTION "util"."read_dataset_alias_execution_v2_primary_closure"("p_actor" "uuid", "p_plan" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_action jsonb;
  v_found boolean;
  v_rows bigint := 0;
  v_claimed_rows bigint;
  v_exchange_count bigint;
  v_support_current boolean := false;
  v_consumers_current boolean := false;
begin
  if p_actor is null or jsonb_typeof(p_plan) is distinct from 'object' then
    return null;
  end if;
  v_claimed_rows := coalesce((p_plan #>> '{expected,action_count}')::bigint, -1);
  v_exchange_count := coalesce((p_plan #>> '{expected,exchange_count}')::bigint, -1);
  -- Fresh current readback: every claimed row must hold exactly the claimed desired payload now, for this
  -- actor, in the owner-draft state. The exact exchange set was proven under the lock by the batch
  -- executor; this readback re-verifies the committed rows rather than re-attesting a stored summary.
  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) loop
    v_found := null;
    if v_action->>'table' = 'flows' then
      select true into v_found
      from public.flows as flow
      where flow.id = (v_action->>'id')::uuid
        and flow.version = v_action->>'version'
        and flow.user_id = p_actor
        and flow.state_code = 0
        and flow.json_ordered::jsonb is not distinct from v_action->'desired_json_ordered';
    elsif v_action->>'table' = 'processes' then
      select true into v_found
      from public.processes as process
      where process.id = (v_action->>'id')::uuid
        and process.version = v_action->>'version'
        and process.user_id = p_actor
        and process.state_code = 0
        and process.json_ordered::jsonb is not distinct from v_action->'desired_json_ordered';
    else
      v_found := false;
    end if;
    if coalesce(v_found, false) then
      v_rows := v_rows + 1;
    end if;
  end loop;

  -- Current support and global consumers. Every rule and every reader mirrors the batch executor: the
  -- same support visibility boundary, the same canonical unit-group paths, the same collection reader
  -- and the same occurrence identity tuple. A plan or live shape that cannot be verified leaves the
  -- closure false instead of raising, so the read path never fails open and never errors on drift.
  begin
    declare
      v_alias_id text := coalesce(
        nullif(p_plan #>> '{source_evidence,source_flowproperty,id}', ''),
        nullif(p_plan #>> '{source_alias,id}', ''));
      v_alias_version text := coalesce(
        nullif(p_plan #>> '{source_evidence,source_flowproperty,version}', ''),
        nullif(p_plan #>> '{source_alias,version}', ''));
      v_source_ug_id text := p_plan #>> '{source_evidence,declared_source_unitgroup,id}';
      v_source_ug_version text := p_plan #>> '{source_evidence,declared_source_unitgroup,version}';
      v_target_fp jsonb;
      v_target_ug jsonb;
      v_source_ug jsonb;
      v_alias_fp jsonb;
      v_target_units jsonb;
      v_reference_unit_id text;
      v_claimed_flows jsonb;
      v_claimed_occurrences jsonb;
      v_live_occurrences jsonb;
    begin
      -- Target support: the canonical property and unit group, read at the exact declared identities and
      -- only through the support boundary (published, or this actor's owner draft).
      select json_ordered::jsonb into v_target_fp
      from public.flowproperties
      where id = (p_plan #>> '{target_snapshots,flowproperty,id}')::uuid
        and version = p_plan #>> '{target_snapshots,flowproperty,version}'
        and (state_code = 100 or (state_code = 0 and user_id = p_actor));
      select json_ordered::jsonb into v_target_ug
      from public.unitgroups
      where id = (p_plan #>> '{target_snapshots,unitgroup,id}')::uuid
        and version = p_plan #>> '{target_snapshots,unitgroup,version}'
        and (state_code = 100 or (state_code = 0 and user_id = p_actor));
      -- Source support: the declared source unit group and the complete source alias flow property the
      -- plan binds. The historical hour unit group is provenance only and is never read here: the alias
      -- row must reference exactly the unit group the evidence declares.
      select json_ordered::jsonb into v_source_ug
      from public.unitgroups
      where id = v_source_ug_id::uuid
        and version = v_source_ug_version
        and (state_code = 100 or (state_code = 0 and user_id = p_actor));
      select json_ordered::jsonb into v_alias_fp
      from public.flowproperties
      where id = v_alias_id::uuid
        and version = v_alias_version
        and (state_code = 100 or (state_code = 0 and user_id = p_actor));

      v_target_units := case jsonb_typeof(v_target_ug #> '{unitGroupDataSet,units,unit}')
        when 'array' then v_target_ug #> '{unitGroupDataSet,units,unit}'
        when 'object' then jsonb_build_array(v_target_ug #> '{unitGroupDataSet,units,unit}')
        else '[]'::jsonb
      end;
      v_reference_unit_id := v_target_ug #>> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}';

      v_support_current := coalesce(
        v_target_fp is not null
        and v_target_ug is not null
        and v_source_ug is not null
        and v_alias_fp is not null
        and private.dataset_alias_v2_payload_sha256(v_target_fp)
          = p_plan #>> '{target_snapshots,flowproperty,sha256}'
        and private.dataset_alias_v2_payload_sha256(v_target_ug)
          = p_plan #>> '{target_snapshots,unitgroup,sha256}'
        and private.dataset_alias_v2_payload_sha256(v_source_ug)
          = p_plan #>> '{source_evidence,declared_source_unitgroup,sha256}'
        and private.dataset_alias_v2_payload_sha256(v_alias_fp)
          = p_plan #>> '{source_evidence,source_flowproperty,sha256}'
        and v_alias_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
          = v_source_ug_id
        and v_alias_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}'
          = v_source_ug_version
        and p_plan #>> '{source_alias,id}' = v_alias_id
        and p_plan #>> '{source_alias,version}' = v_alias_version
        and p_plan #>> '{source_alias,sha256}'
          = private.dataset_alias_v2_payload_sha256(
              jsonb_build_object('id', v_alias_id, 'version', v_alias_version))
        and v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
          = p_plan #>> '{target_snapshots,unitgroup,id}'
        and v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}'
          = p_plan #>> '{target_snapshots,unitgroup,version}'
        and coalesce(v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@type}',
              'unit group data set') = 'unit group data set'
        and coalesce(v_reference_unit_id, '') <> ''
        and exists (
          select 1 from jsonb_array_elements(v_target_units) as unit
          where unit->>'@dataSetInternalID' = v_reference_unit_id
            and (unit->>'meanValue')::numeric = 1)
        and exists (
          select 1 from jsonb_array_elements(v_target_units) as unit
          where unit->>'name' = 'hr'
            and (unit->>'meanValue')::numeric = private.dataset_alias_v2_factor()),
        false);

      -- The frozen claim sets: the changed Flows and the exact exchange occurrences the plan names.
      select coalesce(jsonb_agg(jsonb_build_object('id', (a->>'id')::uuid, 'version', a->>'version')
        order by (a->>'id')::uuid, a->>'version'), '[]'::jsonb)
        into v_claimed_flows
      from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) as a
      where a->>'table' = 'flows'
        and (a->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
      select coalesce(jsonb_agg(jsonb_build_object(
          'process_id', (a->>'id')::uuid, 'process_version', a->>'version',
          'index', (e->>'index')::integer, 'internal_id', e->>'internal_id',
          'direction', e->>'direction')
        order by (a->>'id')::uuid, a->>'version', (e->>'index')::integer), '[]'::jsonb)
        into v_claimed_occurrences
      from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) as a
      cross join lateral jsonb_array_elements(coalesce(a->'mutation'->'exchanges', '[]'::jsonb)) as e
      where a->>'table' = 'processes'
        and (a->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and (e->>'index') ~ '^[0-9]+$';

      -- The remaining source-alias Flow set: a live consumer of the alias property that is not one of
      -- the plan's changed Flows is a remaining or new source-alias Flow outside the completed plan.
      -- The claimed Flows themselves were moved off the alias by the run, so a legitimate applied plan
      -- leaves no unclaimed consumer.
      v_consumers_current := coalesce(not exists (
        select 1
        from public.flows as f
        where private.dataset_alias_jsonb_array_v1(
                f.json_ordered::jsonb #> '{flowDataSet,flowProperties,flowProperty}'
              ) @> jsonb_build_array(jsonb_build_object(
                'referenceToFlowPropertyDataSet',
                jsonb_build_object('@refObjectId', v_alias_id, '@version', v_alias_version)))
          and not exists (
            select 1 from jsonb_array_elements(v_claimed_flows) as claimed
            where claimed->>'id' = f.id::text and claimed->>'version' = f.version::text)),
        false);

      -- The exact global incoming occurrence set of the changed Flows across all owners and all states:
      -- it must equal the frozen claimed occurrence set, and every live occurrence must be this actor's
      -- owner draft. The frozen source-evidence count must agree with the claimed set as well.
      -- Candidate-driven, exactly as the batch executor's own occurrence closure is: the normalised
      -- reference collection the deployed GIN index is built on is probed first, and only those
      -- candidate rows are read back by primary key and expanded. Containment is strictly weaker than
      -- the exact occurrence predicate below, in both deployed collection shapes, so the candidate set
      -- is a complete superset and the exact check below still decides. The returned material and the
      -- fail-closed exception handler are unchanged.
      with candidate_process_keys as materialized (
        select distinct candidate_process.id, candidate_process.version
        from jsonb_array_elements(v_claimed_flows) as claimed
        cross join lateral (
          select dataset_process.id, dataset_process.version
          from public.processes as dataset_process
          where private.dataset_alias_jsonb_array_v1(
                  dataset_process.json_ordered::jsonb
                    #> '{processDataSet,exchanges,exchange}'
                ) @> jsonb_build_array(jsonb_build_object(
                  'referenceToFlowDataSet',
                  jsonb_build_object(
                    '@refObjectId', claimed->>'id',
                    '@version', claimed->>'version'
                  )
                ))
        ) as candidate_process
      )
      select coalesce(jsonb_agg(jsonb_build_object(
          'process_id', p.id, 'process_version', p.version, 'state_code', p.state_code,
          'user_id', p.user_id, 'index', exchange.ordinality - 1,
          'internal_id', exchange.value->>'@dataSetInternalID',
          'direction', exchange.value->>'exchangeDirection')
        order by p.id, p.version, exchange.ordinality), '[]'::jsonb)
        into v_live_occurrences
      from candidate_process_keys as candidate
      cross join lateral (
        -- LIMIT 1 is lossless because (id, version) is the primary key.
        select candidate_process.id, candidate_process.version, candidate_process.json_ordered,
               candidate_process.user_id, candidate_process.state_code
        from public.processes as candidate_process
        where candidate_process.id = candidate.id
          and candidate_process.version = candidate.version
        limit 1
      ) as p
      cross join lateral jsonb_array_elements(
        coalesce(p.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)
      ) with ordinality as exchange
      where exists (
        select 1 from jsonb_array_elements(v_claimed_flows) as claimed
        where claimed->>'id' = exchange.value->'referenceToFlowDataSet'->>'@refObjectId'
          and claimed->>'version' = exchange.value->'referenceToFlowDataSet'->>'@version');

      v_consumers_current := coalesce(
        v_consumers_current
        and jsonb_array_length(v_live_occurrences) = jsonb_array_length(v_claimed_occurrences)
        and not exists (
          select 1 from jsonb_array_elements(v_claimed_occurrences) as claimed
          where not exists (
            select 1 from jsonb_array_elements(v_live_occurrences) as live
            where live->>'process_id' = claimed->>'process_id'
              and live->>'process_version' = claimed->>'process_version'
              and live->>'index' = claimed->>'index'
              and live->>'internal_id' = claimed->>'internal_id'
              and live->>'direction' = claimed->>'direction'))
        and not exists (
          select 1 from jsonb_array_elements(v_live_occurrences) as live
          where (live->>'state_code')::integer <> 0 or (live->>'user_id')::uuid <> p_actor)
        and (p_plan #>> '{source_evidence,exchange_count}')::bigint
          = jsonb_array_length(v_claimed_occurrences),
        false);
    end;
  exception
    when others then
      -- A shape that cannot be verified is drift, never a pass and never an error.
      v_support_current := false;
      v_consumers_current := false;
  end;

  return jsonb_build_object(
    'ok', v_rows = v_claimed_rows and v_claimed_rows >= 0
      and v_support_current and v_consumers_current,
    'live_closure_proof', v_rows = v_claimed_rows and v_claimed_rows >= 0
      and v_support_current and v_consumers_current,
    'row_count', v_rows,
    'claimed_row_count', v_claimed_rows,
    'exchange_count', v_exchange_count,
    'invalid_action_count', case when v_rows = v_claimed_rows then 0 else v_claimed_rows - v_rows end,
    'proof_sha256', util.dataset_alias_execution_v2_artifact_sha256(
      jsonb_build_object('actor', p_actor, 'rows', v_rows, 'claimed_rows', v_claimed_rows,
        'exchange_count', v_exchange_count, 'plan_sha256', p_plan->>'plan_sha256'))
  );
end
$_$;

ALTER FUNCTION "util"."read_dataset_alias_execution_v2_primary_closure"("p_actor" "uuid", "p_plan" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "util"."read_dataset_alias_execution_v2_primary_closure"("p_actor" "uuid", "p_plan" "jsonb") FROM PUBLIC;
