-- Foundry #60 / Database #686 — the protected primary_support_plan gate must reach admission inside its
-- existing 55-second statement budget.
--
-- The reproduced defect: one query shape was copied into four places — the fresh-run global occurrence
-- closure of the claimed Flows:
--   select ... from public.processes p
--     cross join lateral jsonb_array_elements(p.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}')
--     where <exact occurrence predicate>
-- The lateral expansion detoasts and re-parses every Process row and materialises every exchange of every
-- Process in the database before the predicate is applied, with no index support, so its cost follows the
-- whole Process table rather than the plan. Measured on an isolated stack at the observed hosted magnitude
-- (44,477 Processes / 134,609 Flows) the statement costs 3.4 s locally over 287k shared buffers; the
-- hosted preflight's database execution for the same work was 40,343 ms against its 60-second budget, and
-- the gate re-runs the identical work under 55 seconds.
--
-- This migration replaces only that scan, in all four places, with the candidate-driven shape the
-- reviewed v1 executor has used since 20260715030848: probe the normalised reference collection the
-- existing GIN index processes_json_ordered_alias_exchange_gin_idx is built on (20260715030844), then read
-- only those candidate rows back by primary key and apply the unchanged exact predicate. Containment is
-- strictly weaker than the exact occurrence predicate in both deployed collection shapes, so the
-- candidate set is a complete superset and the exact predicate still decides. No index is added, no
-- timeout is raised, no consumer is dropped, no scope is capped, and no rule, count, drift condition,
-- returned material, ACL or audit topology changes.
--
-- Each function below is byte-identical to its deployed definition except its own occurrence-closure
-- substitution, so the delta is a diff rather than a claim.

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
  v_text_path constant text := 'processDataSet.processInformation.quantitativeReference.functionalUnitOrOther.#text';
  v_batch_id text;
  v_plan_sha256 text;
  v_factor text;
  v_actions jsonb;
  v_text_actions jsonb;
  v_action_count integer;
  v_action jsonb;
  v_reference jsonb;
  v_alias_fp_id text;
  v_alias_fp_version text;
  v_alias_fp_source_ug_id text;
  v_alias_fp_source_ug_version text;
  v_target_fp jsonb;
  v_target_ug jsonb;
  v_source_ug jsonb;
  v_prepared jsonb := '[]'::jsonb;
  v_derived jsonb;
  v_entry jsonb;
  v_live_flows jsonb;
  v_batch_flows jsonb;
  v_live_occurrences jsonb;
  v_batch_occurrences jsonb;
  v_claim_text_actions jsonb;
  v_moved_text_actions jsonb;
  v_occurrence_count integer;
  v_amount_field_count integer;
  v_selected_exchanges integer := 0;
  v_unrelated integer;
  v_text_count integer := 0;
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
        'schema_version', 'batch_id', 'plan_sha256', 'dimension', 'factor', 'target_visibility',
        'target_snapshots', 'source_evidence', 'source_alias', 'counts', 'text_actions', 'actions'
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
      or jsonb_typeof(p_batch->'actions') is distinct from 'array'
      or jsonb_typeof(p_batch->'text_actions') is distinct from 'array'
      or jsonb_typeof(p_batch->'counts') is distinct from 'object'
      or jsonb_typeof(p_batch->'target_snapshots') is distinct from 'object'
      or jsonb_typeof(p_batch->'source_evidence') is distinct from 'object' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'Batch envelope, dimension, factor, plan identity, counts, text actions, snapshots or action list is invalid');
    end if;
    v_batch_id := btrim(p_batch->>'batch_id');
    v_plan_sha256 := p_batch->>'plan_sha256';
    v_factor := p_batch->>'factor';
    v_actions := p_batch->'actions';
    v_text_actions := p_batch->'text_actions';
    v_action_count := jsonb_array_length(v_actions);
    if v_action_count < 1 or v_action_count > 4096 or jsonb_array_length(v_text_actions) > 4096 then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'A v2 batch carries between one and 4096 actions and at most 4096 text actions');
    end if;

    -- Counts, snapshot and evidence blocks carry exactly the reviewed keys with checked shapes; nothing is
    -- echoed unread and nothing defaults when a value is missing or malformed. `amount_field_count` is the
    -- reviewed two-amount-fields-per-bound-exchange derivation.
    if exists (
      select 1 from jsonb_object_keys(p_batch->'counts') as key(name)
      where key.name <> all (array['action_count', 'flow_count', 'process_count', 'exchange_count',
        'amount_field_count', 'unrelated_exchange_count', 'flowproperty_count'])
    ) or (select count(*) from jsonb_object_keys(p_batch->'counts')) <> 7
      or (p_batch #>> '{counts,action_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,flow_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,process_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,exchange_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,amount_field_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,unrelated_exchange_count}') !~ '^[0-9]+$'
      or (p_batch #>> '{counts,flowproperty_count}') !~ '^[0-9]+$' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'The counts block must carry exactly the seven reviewed numeric keys');
    end if;
    if exists (
      select 1 from jsonb_object_keys(p_batch->'target_snapshots') as key(name)
      where key.name <> all (array['flowproperty', 'unitgroup'])
    )
      or jsonb_typeof(p_batch->'target_snapshots'->'flowproperty') is distinct from 'object'
      or jsonb_typeof(p_batch->'target_snapshots'->'unitgroup') is distinct from 'object'
      or (p_batch #>> '{target_snapshots,flowproperty,id}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or (p_batch #>> '{target_snapshots,unitgroup,id}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or (p_batch #>> '{target_snapshots,flowproperty,version}') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or (p_batch #>> '{target_snapshots,unitgroup,version}') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or (p_batch #>> '{target_snapshots,flowproperty,sha256}') !~ '^[a-f0-9]{64}$'
      or (p_batch #>> '{target_snapshots,unitgroup,sha256}') !~ '^[a-f0-9]{64}$' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'The target snapshot block must carry exactly the target flow property and unit group with their digests');
    end if;
    if exists (
      select 1 from jsonb_object_keys(p_batch->'source_evidence') as key(name)
      where key.name <> all (array['sha256', 'exchange_count', 'source_unitgroup', 'source_flowproperty'])
    ) or (p_batch #>> '{source_evidence,sha256}') !~ '^[a-f0-9]{64}$'
      or (p_batch #>> '{source_evidence,exchange_count}') !~ '^[0-9]+$'
      or jsonb_typeof(p_batch->'source_evidence'->'source_unitgroup') is distinct from 'object'
      or exists (
        select 1 from jsonb_object_keys(p_batch->'source_evidence'->'source_unitgroup') as key(name)
        where key.name <> all (array['id', 'version', 'sha256'])
      )
      or (p_batch #>> '{source_evidence,source_unitgroup,id}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or (p_batch #>> '{source_evidence,source_unitgroup,version}') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or (p_batch #>> '{source_evidence,source_unitgroup,sha256}') !~ '^[a-f0-9]{64}$'
      or jsonb_typeof(p_batch->'source_evidence'->'source_flowproperty') is distinct from 'object'
      or exists (
        select 1 from jsonb_object_keys(p_batch->'source_evidence'->'source_flowproperty') as key(name)
        where key.name <> all (array['id', 'version', 'sha256'])
      )
      or (p_batch #>> '{source_evidence,source_flowproperty,id}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or (p_batch #>> '{source_evidence,source_flowproperty,version}') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or (p_batch #>> '{source_evidence,source_flowproperty,sha256}') !~ '^[a-f0-9]{64}$' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
        'The source evidence block must carry exactly the reviewed digest, exchange count, source unit group and complete source flow property snapshots');
    end if;

    -- Locks: unit groups inside the boundary so no concurrent factor or snapshot change can race.
    lock table public.flowproperties, public.unitgroups, public.flows, public.processes
      in share row exclusive mode;

    -- Target and source evidence are read from the locked rows, never trusted from the envelope, and
    -- only through the reference boundary the actor actually has: a support row is admissible when it
    -- is a published state-100 row or a state-0 row owned by the authenticated plan actor. A foreign
    -- unpublished row is refused here, before any digest diagnostics, even when the caller knows its
    -- complete payload and hash.
    select json_ordered::jsonb into v_target_fp
    from public.flowproperties
    where id = (p_batch #>> '{target_snapshots,flowproperty,id}')::uuid
      and version = p_batch #>> '{target_snapshots,flowproperty,version}'
      and (state_code = 100 or (state_code = 0 and user_id = v_actor));
    select json_ordered::jsonb into v_target_ug
    from public.unitgroups
    where id = (p_batch #>> '{target_snapshots,unitgroup,id}')::uuid
      and version = p_batch #>> '{target_snapshots,unitgroup,version}'
      and (state_code = 100 or (state_code = 0 and user_id = v_actor));
    select json_ordered::jsonb into v_source_ug
    from public.unitgroups
    where id = (p_batch #>> '{source_evidence,source_unitgroup,id}')::uuid
      and version = p_batch #>> '{source_evidence,source_unitgroup,version}'
      and (state_code = 100 or (state_code = 0 and user_id = v_actor));
    if v_target_fp is null or v_target_ug is null or v_source_ug is null then
      perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
        'The declared target flow property, target unit group or source unit group is not readable by this actor');
    end if;
    if private.dataset_alias_v2_payload_sha256(v_target_fp) is distinct from p_batch #>> '{target_snapshots,flowproperty,sha256}'
      or private.dataset_alias_v2_payload_sha256(v_target_ug) is distinct from p_batch #>> '{target_snapshots,unitgroup,sha256}'
      or private.dataset_alias_v2_payload_sha256(v_source_ug) is distinct from p_batch #>> '{source_evidence,source_unitgroup,sha256}' then
      perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409, 'Snapshot content does not match the declared binding',
        jsonb_build_object('fp_observed', private.dataset_alias_v2_payload_sha256(v_target_fp),
          'fp_declared', p_batch #>> '{target_snapshots,flowproperty,sha256}',
          'ug_observed', private.dataset_alias_v2_payload_sha256(v_target_ug),
          'ug_declared', p_batch #>> '{target_snapshots,unitgroup,sha256}',
          'source_observed', private.dataset_alias_v2_payload_sha256(v_source_ug),
          'source_declared', p_batch #>> '{source_evidence,source_unitgroup,sha256}'));
    end if;
    -- The target flow property must reference exactly this target unit group, and that unit group must carry
    -- the reviewed factors. The deployed unit group is read at its canonical paths: the quantitative
    -- reference names the reference unit by internal id (an id string, exactly as the live rows carry it)
    -- and the table itself is `unitGroupDataSet.units.unit[]` with name/meanValue/@dataSetInternalID. The
    -- reference row must be the year base at factor 1 and the table must carry the exact hour factor; the
    -- factors are compared as numbers, so the reviewed value is what binds, not its spelling.
    declare
      v_target_units jsonb := case jsonb_typeof(v_target_ug #> '{unitGroupDataSet,units,unit}')
        when 'array' then v_target_ug #> '{unitGroupDataSet,units,unit}'
        when 'object' then jsonb_build_array(v_target_ug #> '{unitGroupDataSet,units,unit}')
        else '[]'::jsonb
      end;
      -- The base unit is selected at its one canonical parent path, exactly as the official
      -- authenticated export and the deployed expression index show it:
      -- unitGroupDataSet.unitGroupInformation.quantitativeReference.referenceToReferenceUnit. A
      -- root-level lookalike is not a fallback — it yields no reference id here and the unit group is
      -- refused below — and the table itself is only ever read from units.unit[].
      v_reference_unit_id text := v_target_ug #>> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}';
    begin
      if v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
          is distinct from p_batch #>> '{target_snapshots,unitgroup,id}'
        or v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}'
          is distinct from p_batch #>> '{target_snapshots,unitgroup,version}'
        or coalesce(v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@type}',
             'unit group data set') is distinct from 'unit group data set'
        or coalesce(v_reference_unit_id, '') = ''
        or not exists (
          select 1
          from jsonb_array_elements(v_target_units) as unit
          where unit->>'@dataSetInternalID' = v_reference_unit_id
            and (unit->>'meanValue')::numeric = 1
        )
        or not exists (
          select 1
          from jsonb_array_elements(v_target_units) as unit
          where unit->>'name' = 'hr' and (unit->>'meanValue')::numeric = private.dataset_alias_v2_factor()
        ) then
        perform private.dataset_alias_v2_deny('ALIAS_V2_FACTOR_UNSUPPORTED', 409,
          'The target unit group does not carry the reviewed year base and exact hour factor at the canonical quantitative-reference path');
      end if;
    end;

    -- The claimed flow and occurrence sets are aggregated before the structural scan, so every exchange
    -- instance and text action can be bound to a claimed flow or process inside the same pass. The shapes
    -- are pre-guarded so a malformed action cannot raise here; the scan below refuses it properly.
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

    -- Structural scan: identity, closed keys, claimed canonical digests, the alias property identified from
    -- the frozen before payloads, the per-table mutation contracts, and the set of processes whose
    -- functional-unit leaf the batch claims to move.
    for v_action in select * from jsonb_array_elements(v_actions) loop
      if jsonb_typeof(v_action) <> 'object' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Every action must be one JSON object');
      end if;
      if v_action->>'table' not in ('flows', 'processes') then
        perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Every action must name the flows or processes table');
      end if;
      if exists (
        select 1 from jsonb_object_keys(v_action) as key(name)
        where key.name <> all (
          case when v_action->>'table' = 'flows'
            then array['action_id', 'table', 'id', 'version', 'expected_state_code', 'expected_modified_at',
              'expected_json_ordered', 'desired_json_ordered', 'before_sha256', 'desired_sha256',
              'source_flowproperty', 'mutation']
            else array['action_id', 'table', 'id', 'version', 'expected_state_code', 'expected_modified_at',
              'expected_json_ordered', 'desired_json_ordered', 'before_sha256', 'desired_sha256',
              'quantitative_reference', 'mutation']
          end)
      ) or v_action->'desired_json_ordered' is null then
        perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Unknown action keys, or a missing desired claim');
      end if;
      if (v_action->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or (v_action->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
        or (v_action->>'expected_state_code')::integer is distinct from 0
        or jsonb_typeof(v_action->'expected_json_ordered') is distinct from 'object'
        or jsonb_typeof(v_action->'mutation') is distinct from 'object'
        or coalesce(v_action->>'expected_modified_at', '1970-01-01T00:00:00Z') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
        or (v_action->>'before_sha256') !~ '^[a-f0-9]{64}$'
        or (v_action->>'desired_sha256') !~ '^[a-f0-9]{64}$' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
          'Action identity, table, state, before payload, claimed digests, mutation or timestamp is invalid',
          jsonb_build_object('action_id', v_action->>'action_id'));
      end if;
      -- The claimed digests must be the server's own canonical digests of the claimed payloads: hash parity
      -- with the producer is checked, never assumed.
      if private.dataset_alias_v2_payload_sha256(v_action->'expected_json_ordered') is distinct from v_action->>'before_sha256'
        or private.dataset_alias_v2_payload_sha256(v_action->'desired_json_ordered') is distinct from v_action->>'desired_sha256' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_DERIVE_MISMATCH', 409,
          'A claimed before or desired digest is not the canonical digest of the claimed payload',
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
          where key.name <> all (array['reference'])
        ) or jsonb_typeof(v_action->'mutation'->'reference') is distinct from 'object'
          or exists (
            select 1 from jsonb_object_keys(v_action->'mutation'->'reference') as key(name)
            where key.name <> all (array['@refObjectId', '@type', '@uri', '@version', 'common:shortDescription'])
          )
          or (v_action #>> '{mutation,reference,@refObjectId}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          or coalesce(v_action #>> '{mutation,reference,@type}', '') = ''
          or coalesce(v_action #>> '{mutation,reference,@uri}', '') = ''
          or (v_action #>> '{mutation,reference,@version}') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
          or jsonb_typeof(v_action->'mutation'->'reference'->'common:shortDescription') is distinct from 'object'
          or coalesce(v_action #>> '{mutation,reference,common:shortDescription,#text}', '') = '' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
            'A flow action carries exactly the deployed five-key target reference as its mutation',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        -- The claimed source flow property must be the one the frozen before payload references.
        if coalesce(v_action->'source_flowproperty'->>'id', '') = ''
          or coalesce(v_action->'source_flowproperty'->>'version', '') = ''
          or (v_action #>> '{source_flowproperty,id}') is distinct from
             (private.dataset_alias_v2_flow_reference(v_action->'expected_json_ordered') #>> '{@refObjectId}')
          or (v_action #>> '{source_flowproperty,version}') is distinct from
             (private.dataset_alias_v2_flow_reference(v_action->'expected_json_ordered') #>> '{@version}') then
          perform private.dataset_alias_v2_deny('ALIAS_V2_DERIVE_MISMATCH', 409,
            'A flow action does not name the flow property its frozen before payload references',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        v_alias_fp_id := coalesce(v_alias_fp_id, private.dataset_alias_v2_flow_reference(v_action->'expected_json_ordered') #>> '{@refObjectId}');
        v_alias_fp_version := coalesce(v_alias_fp_version, private.dataset_alias_v2_flow_reference(v_action->'expected_json_ordered') #>> '{@version}');
        if private.dataset_alias_v2_flow_reference(v_action->'expected_json_ordered') #>> '{@refObjectId}' is distinct from v_alias_fp_id
          or private.dataset_alias_v2_flow_reference(v_action->'expected_json_ordered') #>> '{@version}' is distinct from v_alias_fp_version then
          perform private.dataset_alias_v2_deny('ALIAS_V2_CLOSURE_MISMATCH', 409, 'Every flow action must start from the same alias flow property');
        end if;
      else
        if exists (
          select 1 from jsonb_object_keys(v_action->'mutation') as key(name)
          where key.name <> all (array['exchanges'])
        ) or jsonb_typeof(v_action->'mutation'->'exchanges') is distinct from 'array'
          or jsonb_array_length(v_action->'mutation'->'exchanges') < 1
          or (v_action #>> '{quantitative_reference}') is distinct from
             (v_action->'expected_json_ordered' #>> '{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}')
          or coalesce(v_action->>'quantitative_reference', '') = '' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
            'A process action carries its bound exchange instances, its quantitative reference and nothing else',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
        for v_entry in select * from jsonb_array_elements(v_action->'mutation'->'exchanges') loop
          if jsonb_typeof(v_entry) <> 'object'
            or exists (
              select 1 from jsonb_object_keys(v_entry) as key(name)
              where key.name <> all (array['index', 'internal_id', 'flow_id', 'flow_version', 'direction',
                'before_amount', 'after_amount', 'before_resulting_amount', 'after_resulting_amount'])
            )
            or coalesce(v_entry->>'index', '') !~ '^[0-9]+$'
            or coalesce(v_entry->>'internal_id', '') = ''
            or coalesce(v_entry->>'flow_id', '') = ''
            or coalesce(v_entry->>'flow_version', '') = ''
            or coalesce(v_entry->>'direction', '') = ''
            or v_entry->>'before_amount' is null
            or v_entry->>'after_amount' is null
            or v_entry->>'before_resulting_amount' is null
            or v_entry->>'after_resulting_amount' is null
            or not exists (
              select 1 from jsonb_array_elements(v_batch_flows) as claimed
              where claimed->>'id' = v_entry->>'flow_id' and claimed->>'version' = v_entry->>'flow_version'
            ) then
            perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
              'Every exchange instance must carry exactly the reviewed keys and name a claimed alias flow',
              jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
        end loop;
        if (select count(distinct entry->>'internal_id')
              from jsonb_array_elements(v_action->'mutation'->'exchanges') as entry)
           <> jsonb_array_length(v_action->'mutation'->'exchanges') then
          perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400,
            'Exchange instances within one action carry distinct internal ids',
            jsonb_build_object('action_id', v_action->>'action_id'));
        end if;
      end if;
    end loop;

    -- The text-action block is the authority for functional-unit moves and must agree, entry by entry, with
    -- the claimed payloads: the frozen before leaf, the anchored-rule after leaf, the process's own
    -- reference-flow exchange bound by its TIDAS internal id, that exchange's reviewed source quantity, and
    -- the reviewed source number carried by the stored source comment when the row records one. The block's
    -- process set must be exactly the set of claimed processes whose functional-unit leaf moves.
    select coalesce(jsonb_agg(jsonb_build_object('id', (t->>'id')::uuid, 'version', t->>'version') order by (t->>'id')::uuid, t->>'version'), '[]'::jsonb)
      into v_claim_text_actions
    from jsonb_array_elements(v_text_actions) as t
    where (t->>'table') = 'processes'
      and (t->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    select coalesce(jsonb_agg(jsonb_build_object('id', (a->>'id')::uuid, 'version', a->>'version') order by (a->>'id')::uuid, a->>'version'), '[]'::jsonb)
      into v_moved_text_actions
    from jsonb_array_elements(v_actions) as a
    where a->>'table' = 'processes'
      and (a->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and (a->'expected_json_ordered' #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}')
          is distinct from
          (a->'desired_json_ordered' #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}');
    for v_entry in select * from jsonb_array_elements(v_text_actions) loop
      declare
        v_text_before text := v_entry->>'before_text';
        v_text_after text := v_entry->>'after_text';
        v_text_source text := v_entry->>'source_exchange_number';
        v_action_match jsonb;
        v_reference_internal text;
        v_reference_entry jsonb;
        v_stored_comment text;
        v_quantity text;
      begin
        if jsonb_typeof(v_entry) <> 'object'
          or exists (
            select 1 from jsonb_object_keys(v_entry) as key(name)
            where key.name <> all (array['table', 'id', 'version', 'before_text', 'after_text', 'source_exchange_number'])
          )
          or (v_entry->>'table') is distinct from 'processes'
          or coalesce(v_entry->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          or coalesce(v_entry->>'version', '') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
          or v_text_before is null
          or v_text_after is null
          or coalesce(v_text_source, '') !~ '^[0-9]{1,18}$' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
            'Every text action carries exactly the reviewed keys, a process identity and the original source exchange number');
        end if;
        select a into v_action_match
        from jsonb_array_elements(v_actions) as a
        where a->>'table' = 'processes' and a->>'id' = v_entry->>'id' and a->>'version' = v_entry->>'version';
        if v_action_match is null then
          perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
            'A text action names a process the batch does not claim',
            jsonb_build_object('action_id', v_entry->>'id'));
        end if;
        if (v_action_match->'expected_json_ordered' #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}') is distinct from v_text_before
          or (v_action_match->'desired_json_ordered' #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}') is distinct from v_text_after
          or private.dataset_alias_v2_fu_apply_rule(v_text_before) is distinct from v_text_after then
          perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_BLOCK_MISMATCH', 409,
            'A text action does not agree byte-for-byte with the claimed before and desired functional-unit leaves under the anchored rule',
            jsonb_build_object('action_id', v_entry->>'id'));
        end if;
        -- Step 1: the process reference exchange is bound by its TIDAS internal id — the frozen internal
        -- pointer — never by the original EcoSpold number, which is a different namespace.
        v_reference_internal := v_action_match->'expected_json_ordered' #>> '{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}';
        select entry into v_reference_entry
        from jsonb_array_elements(v_action_match->'mutation'->'exchanges') as entry
        where entry->>'internal_id' = v_reference_internal;
        if v_reference_entry is null or coalesce(v_reference_internal, '') = '' then
          perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
            'The functional-unit process reference exchange (TIDAS internal id) is not among the bound alias exchanges',
            jsonb_build_object('action_id', v_entry->>'id'));
        end if;
        -- Step 2: the reviewed leading quantity must be that exchange's own source quantity, so a functional
        -- unit can never be moved over a physically different amount.
        v_quantity := substring(v_text_before from '^[0-9.]+');
        if v_quantity is null
          or not private.dataset_alias_v2_amount_grammar_ok(v_quantity)
          or not private.dataset_alias_v2_amount_grammar_ok(v_reference_entry->>'before_amount')
          or (v_quantity)::numeric is distinct from (v_reference_entry->>'before_amount')::numeric then
          perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
            'The functional-unit quantity is not the reference exchange''s reviewed source quantity',
            jsonb_build_object('action_id', v_entry->>'id'));
        end if;
        -- Step 3: when the stored reference exchange carries the reviewed source comment, it must name the
        -- declared source tuple; a text action contradicting the stored source row fails closed.
        select stored_exchange.value->>'generalComment' into v_stored_comment
        from jsonb_array_elements(coalesce(v_action_match->'expected_json_ordered' #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) as stored_exchange
        where stored_exchange.value->>'@dataSetInternalID' = v_reference_internal;
        if v_stored_comment is not null
          and v_stored_comment !~ ('(^|[^0-9])' || v_text_source || '([^0-9]|$)') then
          perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
            'The reviewed source comment of the reference exchange does not carry the declared source exchange number',
            jsonb_build_object('action_id', v_entry->>'id'));
        end if;
      end;
    end loop;
    if v_claim_text_actions is distinct from v_moved_text_actions then
      perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_BLOCK_MISMATCH', 409,
        'The text-action block must name exactly the claimed processes whose functional-unit leaf moves',
        jsonb_build_object('text_actions', v_claim_text_actions, 'moved', v_moved_text_actions));
    end if;
    v_text_count := jsonb_array_length(v_claim_text_actions);

    if (select count(*) from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows')
        <> (select count(distinct (a->>'id') || '|' || (a->>'version')) from jsonb_array_elements(v_actions) as a where a->>'table' = 'flows')
      or (select count(*) from jsonb_array_elements(v_actions) as a where a->>'table' = 'processes')
        <> (select count(distinct (a->>'id') || '|' || (a->>'version')) from jsonb_array_elements(v_actions) as a where a->>'table' = 'processes') then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'Duplicate action identities are refused');
    end if;
    if v_alias_fp_id is null then
      perform private.dataset_alias_v2_deny('ALIAS_V2_BATCH_INVALID', 400, 'A v2 batch needs at least one flow action to identify the alias property');
    end if;

    -- The alias flow property must reference the declared source unit group; together with the target
    -- pointer and the two flow-property names this is the whole support evidence the plan binds.
    declare
      v_alias_fp_row jsonb;
      v_alias_fp_name jsonb;
    begin
      select json_ordered::jsonb into v_alias_fp_row
      from public.flowproperties
      where id = v_alias_fp_id::uuid and version = v_alias_fp_version
        and (state_code = 100 or (state_code = 0 and user_id = v_actor));
      if v_alias_fp_row is null then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The source flow property named by the frozen before payloads is not readable by this actor');
      end if;
      if v_alias_fp_row #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
          is distinct from p_batch #>> '{source_evidence,source_unitgroup,id}'
        or v_alias_fp_row #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}'
          is distinct from p_batch #>> '{source_evidence,source_unitgroup,version}' then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The alias flow property does not reference the declared source unit group');
      end if;
      v_alias_fp_source_ug_id := p_batch #>> '{source_evidence,source_unitgroup,id}';
      v_alias_fp_source_ug_version := p_batch #>> '{source_evidence,source_unitgroup,version}';
      -- The frozen source flow property snapshot is the complete current payload, not only its
      -- identity: the lock holds the row, so a payload that moved after the freeze — including a
      -- name-only change — is refused here even though the identity digest still matches.
      if p_batch->'source_evidence'->'source_flowproperty' is null
        or (p_batch #>> '{source_evidence,source_flowproperty,id}')
          is distinct from v_alias_fp_id
        or (p_batch #>> '{source_evidence,source_flowproperty,version}')
          is distinct from v_alias_fp_version
        or (p_batch #>> '{source_evidence,source_flowproperty,sha256}')
          is distinct from private.dataset_alias_v2_payload_sha256(v_alias_fp_row) then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The frozen source flow property snapshot is not the complete locked current source flow property payload');
      end if;
      -- The reviewed plan binds the source alias identity, not the alias row's whole payload: its
      -- digest is the canonical hash of the {id, version} tuple. The row itself is bound by the
      -- identity check below and by the declared source unit group the row must actually reference,
      -- so the alias content cannot move without the identity or the unit-group pointer moving too.
      if p_batch->'source_alias' is not null
        and (p_batch #>> '{source_alias,sha256}') is distinct from
          private.dataset_alias_v2_payload_sha256(
            jsonb_build_object('id', v_alias_fp_id, 'version', v_alias_fp_version)) then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The declared source alias digest is not the canonical identity digest of the alias the plan runs against');
      end if;
      if p_batch->'source_alias' is not null
        and ((p_batch #>> '{source_alias,id}') is distinct from v_alias_fp_id
          or (p_batch #>> '{source_alias,version}') is distinct from v_alias_fp_version) then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'The declared source alias identity is not the alias the frozen before payloads reference');
      end if;
    end;

    -- The derived reference is the deployed five-key shape (root-verified against the live BAFU Time flow
    -- property snapshot): @refObjectId/@type/@uri/@version plus one language-tagged common:shortDescription
    -- object projected from the locked target row's own
    -- flowPropertyDataSet.flowPropertiesInformation.dataSetInformation["common:name"] — never from a
    -- Process-shaped name path and never invented. @type and the @uri convention come from the frozen
    -- before reference with the target id/version substituted; every flow action's claimed reference must
    -- equal it exactly.
    declare
      v_before_reference jsonb := (
        select private.dataset_alias_v2_flow_reference(a->'expected_json_ordered')
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
      if exists (
        select 1 from jsonb_array_elements(v_actions) as a
        where a->>'table' = 'flows' and a->'mutation'->'reference' is distinct from v_reference
      ) then
        perform private.dataset_alias_v2_deny('ALIAS_V2_EVIDENCE_MISMATCH', 409,
          'A flow action''s declared target reference is not the canonical reference derived from the locked target row',
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
        v_text_claim jsonb;
      begin
        execute format('select state_code, modified_at, json_ordered::jsonb from public.%I where id = $1 and version = $2', v_table)
          into v_row_state, v_row_modified, v_row_payload using (v_action->>'id')::uuid, v_action->>'version';
        if v_row_state is not distinct from 0 and v_row_payload is not distinct from v_before
          and (not (v_action ? 'expected_modified_at')
               or v_row_modified is not distinct from (v_action->>'expected_modified_at')::timestamptz) then
          if v_table = 'flows' then
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
            select t into v_text_claim
            from jsonb_array_elements(v_text_actions) as t
            where t->>'id' = v_action->>'id' and t->>'version' = v_action->>'version';
            if v_text_claim is not null then
              v_derived := private.dataset_alias_v2_replace_fu_text(v_derived, jsonb_build_object(
                'path', v_text_path,
                'before_text', v_text_claim->>'before_text',
                'after_text', v_text_claim->>'after_text'));
              if v_derived is null then
                perform private.dataset_alias_v2_deny('ALIAS_V2_TEXT_RULE_VIOLATION', 400,
                  'The functional-unit text is not the reviewed leaf under the anchored rule',
                  jsonb_build_object('action_id', v_action->>'action_id'));
              end if;
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
            'expected_modified_at', v_action->'expected_modified_at', 'observed_modified_at', to_jsonb(v_row_modified),
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
    v_amount_field_count := v_occurrence_count * 2;
    v_unrelated := v_selected_exchanges - v_occurrence_count;
    if (p_batch #>> '{counts,action_count}')::integer is distinct from v_action_count
      or (p_batch #>> '{counts,flow_count}')::integer is distinct from jsonb_array_length(v_batch_flows)
      or (p_batch #>> '{counts,process_count}')::integer is distinct from v_action_count - jsonb_array_length(v_batch_flows)
      or (p_batch #>> '{counts,exchange_count}')::integer is distinct from v_occurrence_count
      or (p_batch #>> '{counts,amount_field_count}')::integer is distinct from v_amount_field_count
      or (p_batch #>> '{counts,unrelated_exchange_count}')::integer is distinct from v_unrelated
      or (p_batch #>> '{counts,flowproperty_count}')::integer is distinct from 0 then
      perform private.dataset_alias_v2_deny('ALIAS_V2_COUNT_MISMATCH', 409, 'Derived live counts differ from the submitted plan counts',
        jsonb_build_object('actions', v_action_count, 'flows', jsonb_array_length(v_batch_flows),
          'occurrences', v_occurrence_count, 'amount_fields', v_amount_field_count, 'unrelated', v_unrelated));
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
      where private.dataset_alias_jsonb_array_v1(
          f.json_ordered::jsonb #> '{flowDataSet,flowProperties,flowProperty}'
        ) @> jsonb_build_array(jsonb_build_object(
          'referenceToFlowPropertyDataSet',
          jsonb_build_object('@refObjectId', v_alias_fp_id, '@version', v_alias_fp_version)
        ));
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
      --
      -- Candidate-driven, mirroring the reviewed v1 executor (20260715030848): the same normalised
      -- reference collection the deployed GIN index processes_json_ordered_alias_exchange_gin_idx is
      -- built on (20260715030844) is probed first, and only those candidate rows are read back by
      -- primary key and expanded. Containment is strictly weaker than the exact occurrence predicate
      -- below, in both deployed collection shapes: if an exchange carries
      -- referenceToFlowDataSet.@refObjectId = id and .@version = version, the normalised collection
      -- contains an element satisfying the containment, so the candidate set is a complete superset of
      -- the exact set and the exact check below still decides. A collection that is neither an array nor
      -- a single object yields no candidate, and it cannot carry a claimed occurrence either.
      -- The expansion and the returned material are byte-identical to the previous definition.
      with candidate_process_keys as materialized (
        select distinct candidate_process.id, candidate_process.version
        from jsonb_array_elements(v_batch_flows) as claimed
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
      select coalesce(jsonb_agg(jsonb_build_object('process_id', p.id, 'process_version', p.version, 'state_code', p.state_code, 'user_id', p.user_id, 'index', exchange.ordinality - 1, 'internal_id', exchange.value->>'@dataSetInternalID', 'direction', exchange.value->>'exchangeDirection') order by p.id, p.version, exchange.ordinality), '[]'::jsonb)
        into v_live_occurrences
      from candidate_process_keys as candidate
      cross join lateral (
        -- LIMIT 1 is lossless because (id, version) is the primary key, and it keeps the exact rows a
        -- candidate-driven primary-key lookup instead of a wide-row heap scan.
        select candidate_process.id, candidate_process.version, candidate_process.json_ordered,
               candidate_process.user_id, candidate_process.state_code
        from public.processes as candidate_process
        where candidate_process.id = candidate.id
          and candidate_process.version = candidate.version
        limit 1
      ) as p
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
                and t.json_ordered::jsonb is not distinct from $6
            returning t.modified_at, t.json_ordered::jsonb', v_action->>'table')
            into v_committed_modified_at, v_committed_payload
            using v_action->'desired', (v_action->>'id')::uuid, v_action->>'version', v_actor, 0,
              v_action->'before';
          if v_committed_modified_at is null or v_committed_payload is distinct from v_action->'desired' then
            perform private.dataset_alias_v2_deny('ALIAS_V2_ACTION_DRIFT', 409, 'The guarded update lost its precondition', jsonb_build_object('action_id', v_action->>'action_id'));
          end if;
          insert into private.command_audit_log (command, actor_user_id, target_table, target_id, target_version, payload)
          values (v_command, v_actor, v_action->>'table', (v_action->>'id')::uuid, v_action->>'version',
            jsonb_build_object(
              'record_type', 'row', 'schema_version', v_schema_version, 'plan_sha256', v_plan_sha256,
              'batch_id', v_batch_id, 'dimension', 'time', 'factor', v_factor,
              'target_visibility', 'owner_draft', 'action_id', v_action->>'action_id',
              'expected_state_code', 0, 'expected_modified_at', v_action->'expected_modified_at',
              'observed_modified_at', v_action->'observed_modified_at',
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
          'batch_id', v_batch_id, 'dimension', 'time', 'factor', v_factor,
          'action_count', v_action_count, 'fresh_actions', v_action_count, 'replayed_actions', 0,
          'text_action_count', v_text_count,
          'source_evidence', p_batch->'source_evidence',
          'target_snapshots', p_batch->'target_snapshots',
          'counts', jsonb_build_object('action_count', v_action_count, 'flow_count', jsonb_array_length(v_batch_flows),
            'process_count', v_action_count - jsonb_array_length(v_batch_flows),
            'exchange_count', v_occurrence_count, 'amount_field_count', v_amount_field_count,
            'unrelated_exchange_count', v_unrelated)))
        returning id into v_summary_id;

        return jsonb_build_object('ok', true, 'code', 'ALIAS_V2_BATCH_APPLIED', 'status', 200,
          'idempotent_replay', false, 'plan_sha256', v_plan_sha256, 'batch_id', v_batch_id,
          'counts', jsonb_build_object('action_count', v_action_count, 'flow_count', jsonb_array_length(v_batch_flows),
            'process_count', v_action_count - jsonb_array_length(v_batch_flows),
            'exchange_count', v_occurrence_count, 'amount_field_count', v_amount_field_count,
            'unrelated_exchange_count', v_unrelated, 'text_action_count', v_text_count),
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
          'counts', v_summary_payload->'counts'
            || jsonb_build_object('text_action_count', v_summary_payload->'text_action_count'),
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


create or replace function util.read_dataset_alias_execution_v2_primary_closure(
  p_actor uuid,
  p_plan jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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
$$;


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
      or not private.dataset_length_time_v1_scalar_ok(p_plan->'plan_sha256', '^[a-f0-9]{64}$')
      or not private.dataset_length_time_v1_scalar_ok(p_plan->'actor_id', '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      or not private.dataset_length_time_v1_scalar_ok(p_plan->'target_visibility', '^owner_draft$')
      or jsonb_typeof(p_plan->'flow_snapshots') is distinct from 'array'
      or jsonb_array_length(p_plan->'flow_snapshots') < 1
      or jsonb_typeof(p_plan->'target_flow_property') is distinct from 'object'
      or jsonb_typeof(p_plan->'target_unit_group') is distinct from 'object'
      or jsonb_typeof(p_plan->'source_evidence') is distinct from 'object'
      or jsonb_typeof(p_plan->'expected') is distinct from 'object'
      or jsonb_typeof(p_plan->'actions') is distinct from 'array'
      or jsonb_array_length(p_plan->'actions') < 1
      or jsonb_array_length(p_plan->'actions') > 4096
      -- The two canonical support snapshots are closed three-key objects with typed scalars.
      or (exists (
            select 1 from jsonb_object_keys(p_plan->'target_flow_property') as key(name)
            where key.name <> all (array['id', 'version', 'sha256']))
          or (select count(*) from jsonb_object_keys(p_plan->'target_flow_property')) <> 3
          or not private.dataset_length_time_v1_scalar_ok(p_plan->'target_flow_property'->'id', '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          or not private.dataset_length_time_v1_scalar_ok(p_plan->'target_flow_property'->'version', '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$')
          or not private.dataset_length_time_v1_scalar_ok(p_plan->'target_flow_property'->'sha256', '^[a-f0-9]{64}$'))
      or (exists (
            select 1 from jsonb_object_keys(p_plan->'target_unit_group') as key(name)
            where key.name <> all (array['id', 'version', 'sha256']))
          or (select count(*) from jsonb_object_keys(p_plan->'target_unit_group')) <> 3
          or not private.dataset_length_time_v1_scalar_ok(p_plan->'target_unit_group'->'id', '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          or not private.dataset_length_time_v1_scalar_ok(p_plan->'target_unit_group'->'version', '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$')
          or not private.dataset_length_time_v1_scalar_ok(p_plan->'target_unit_group'->'sha256', '^[a-f0-9]{64}$')) then
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
        or v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}'
            is distinct from (p_plan #>> '{target_unit_group,version}')
        or coalesce(v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@type}', 'unit group data set')
            is distinct from 'unit group data set'
        or coalesce(v_reference_unit_id, '') = ''
        or not exists (
          select 1 from jsonb_array_elements(v_units) as unit
          where unit->>'@dataSetInternalID' = v_reference_unit_id
            and unit->>'name' = 'm*a'
            -- The factor is compared as an exact decimal through the reviewed bounded grammar: a
            -- malformed spelling refuses here instead of raising, a value-equal spelling (1.0, 1e3)
            -- is the same decimal, and nothing outside the grammar is interpreted.
            and case when private.dataset_alias_v2_amount_grammar_ok(unit->>'meanValue')
              then (unit->>'meanValue')::numeric = 1 else false end
        )
        or not exists (
          select 1 from jsonb_array_elements(v_units) as unit
          where unit->>'name' = 'kmy'
            and case when private.dataset_alias_v2_amount_grammar_ok(unit->>'meanValue')
              then (unit->>'meanValue')::numeric = private.dataset_length_time_v1_factor() else false end
        ) then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_UNITGROUP_MISMATCH', 409,
          'The canonical unit group does not declare the reviewed m*a reference at factor 1 and the kmy ratio at the canonical quantitative-reference path');
      end if;
      select case when private.dataset_alias_v2_amount_grammar_ok(unit->>'meanValue')
        then (unit->>'meanValue')::numeric else null end into v_ratio
      from jsonb_array_elements(v_units) as unit
      where unit->>'name' = 'kmy';
      -- The evidence block is a closed five-key object with typed scalars: a JSON null, an absent key
      -- or a wrong type is a shape refusal before any semantics are compared.
      if exists (
        select 1 from jsonb_object_keys(p_plan->'source_evidence') as key(name)
        where key.name <> all (array['sha256', 'source_unit', 'reference_unit', 'factor', 'instance_count'])
      ) or (select count(*) from jsonb_object_keys(p_plan->'source_evidence')) <> 5
        or not private.dataset_length_time_v1_scalar_ok(p_plan->'source_evidence'->'sha256', '^[a-f0-9]{64}$')
        or not private.dataset_length_time_v1_scalar_ok(p_plan->'source_evidence'->'source_unit', '^kmy$')
        or not private.dataset_length_time_v1_scalar_ok(p_plan->'source_evidence'->'reference_unit', '^m\*a$')
        or not private.dataset_length_time_v1_scalar_ok(p_plan->'source_evidence'->'factor', '^[0-9]+$')
        or not private.dataset_length_time_v1_nonneg_int_ok(p_plan->'source_evidence'->'instance_count') then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_PLAN_INVALID', 400,
          'The source evidence block must carry exactly the reviewed digest, unit pair, factor and instance count, each a JSON string of the declared shape');
      end if;
      -- Three independent factor checks: the declared constant, the locked data, and the derived ratio.
      if p_plan #>> '{source_evidence,factor}' is distinct from v_factor
        or p_plan #>> '{source_evidence,source_unit}' is distinct from 'kmy'
        or p_plan #>> '{source_evidence,reference_unit}' is distinct from 'm*a'
        or v_ratio is null
        or v_ratio is distinct from private.dataset_length_time_v1_factor()
        or v_ratio is distinct from (p_plan #>> '{source_evidence,factor}')::numeric then
        perform private.dataset_alias_v2_deny('LENGTH_TIME_FACTOR_MISMATCH', 409,
          'The declared factor, the locked unit-group ratio and the reviewed constant 1000 must be one value; source unit kmy and reference unit m*a are required');
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
      or not private.dataset_length_time_v1_scalar_ok(entry.value->'id', '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      or not private.dataset_length_time_v1_scalar_ok(entry.value->'version', '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$')
      or not private.dataset_length_time_v1_scalar_ok(entry.value->'sha256', '^[a-f0-9]{64}$')
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
        or not private.dataset_length_time_v1_scalar_ok(v_action->'id', '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        or not private.dataset_length_time_v1_scalar_ok(v_action->'version', '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$')
        or (v_action->>'expected_state_code')::integer is distinct from 0
        or jsonb_typeof(v_action->'expected_json_ordered') is distinct from 'object'
        or jsonb_typeof(v_action->'desired_json_ordered') is distinct from 'object'
        or jsonb_typeof(v_action->'mutation') is distinct from 'object'
        or not private.dataset_length_time_v1_scalar_ok(v_action->'expected_modified_at',
             '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$')
        or not private.dataset_length_time_v1_scalar_ok(v_action->'before_sha256', '^[a-f0-9]{64}$')
        or not private.dataset_length_time_v1_scalar_ok(v_action->'desired_sha256', '^[a-f0-9]{64}$') then
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
        if not private.dataset_length_time_v1_nonneg_int_ok(v_instance->'index')
          or not private.dataset_length_time_v1_scalar_ok(v_instance->'internal_id', '^.+$')
          or not private.dataset_length_time_v1_scalar_ok(v_instance->'source_exchange_number', '^[0-9]+$')
          or not private.dataset_length_time_v1_scalar_ok(v_instance->'direction', '^(Input|Output)$')
          or not private.dataset_length_time_v1_scalar_ok(v_instance->'flow_id', '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          or not private.dataset_length_time_v1_scalar_ok(v_instance->'flow_version', '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$')
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
      -- Candidate-driven, exactly as the Time batch executor's own occurrence closure is: the normalised
      -- reference collection the deployed GIN index is built on is probed first, and only those candidate
      -- rows are read back by primary key and expanded. Containment is strictly weaker than the exact
      -- occurrence predicate below, in both deployed collection shapes, so the candidate set is a complete
      -- superset and the exact check below still decides. The returned material is unchanged.
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
      select coalesce(jsonb_agg(jsonb_build_object('process_id', p.id, 'process_version', btrim(p.version::text),
          'state_code', p.state_code, 'user_id', p.user_id, 'index', exchange.ordinality - 1,
          'internal_id', exchange.value->>'@dataSetInternalID', 'direction', exchange.value->>'exchangeDirection')
        order by p.id, p.version, exchange.ordinality), '[]'::jsonb)
        into v_live_occurrences
      from candidate_process_keys as candidate
      cross join lateral (
        -- LIMIT 1 is lossless because (id, version) is the primary key.
        select candidate_process.id, candidate_process.version, candidate_process.json_ordered,
               candidate_process.state_code, candidate_process.user_id
        from public.processes as candidate_process
        where candidate_process.id = candidate.id
          and candidate_process.version = candidate.version
        limit 1
      ) as p
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

  -- The same candidate-driven shape as the batch executor's occurrence closure, applied to each of
  -- the two scans below: the normalised reference collection the deployed GIN index is built on is
  -- probed first, and only those candidate rows are read back by primary key and expanded.
  -- Containment is strictly weaker than the exact predicate, in both deployed collection shapes, so
  -- the candidate set is a complete superset and the exact predicate still decides. Every drift
  -- condition and both counts are unchanged.
  with candidate_process_keys as materialized (
    select distinct candidate_process.id, candidate_process.version
    from jsonb_array_elements(coalesce(p_plan->'flow_snapshots', '[]'::jsonb)) as claimed
    cross join lateral (
      select dataset_process.id, dataset_process.version
      from public.processes as dataset_process
      where private.dataset_alias_jsonb_array_v1(
              dataset_process.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}'
            ) @> jsonb_build_array(jsonb_build_object(
              'referenceToFlowDataSet',
              jsonb_build_object('@refObjectId', claimed->>'id', '@version', claimed->>'version')))
    ) as candidate_process
  )
  select count(*) into v_live_occurrences
  from candidate_process_keys as candidate
  cross join lateral (
    -- LIMIT 1 is lossless because (id, version) is the primary key.
    select candidate_process.id, candidate_process.version, candidate_process.json_ordered,
           candidate_process.state_code, candidate_process.user_id
    from public.processes as candidate_process
    where candidate_process.id = candidate.id
      and candidate_process.version = candidate.version
    limit 1
  ) as process
  cross join lateral jsonb_array_elements(
    coalesce(process.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}', '[]'::jsonb)) as exchange
  where exists (
    select 1 from jsonb_array_elements(coalesce(p_plan->'flow_snapshots', '[]'::jsonb)) as claimed
    where claimed->>'id' = exchange.value->'referenceToFlowDataSet'->>'@refObjectId'
      and claimed->>'version' = exchange.value->'referenceToFlowDataSet'->>'@version');

  with candidate_process_keys as materialized (
    select distinct candidate_process.id, candidate_process.version
    from jsonb_array_elements(coalesce(p_plan->'flow_snapshots', '[]'::jsonb)) as claimed
    cross join lateral (
      select dataset_process.id, dataset_process.version
      from public.processes as dataset_process
      where private.dataset_alias_jsonb_array_v1(
              dataset_process.json_ordered::jsonb #> '{processDataSet,exchanges,exchange}'
            ) @> jsonb_build_array(jsonb_build_object(
              'referenceToFlowDataSet',
              jsonb_build_object('@refObjectId', claimed->>'id', '@version', claimed->>'version')))
    ) as candidate_process
  )
  select count(*) into v_closure_mismatch
  from candidate_process_keys as candidate
  cross join lateral (
    -- LIMIT 1 is lossless because (id, version) is the primary key.
    select candidate_process.id, candidate_process.version, candidate_process.json_ordered,
           candidate_process.state_code, candidate_process.user_id
    from public.processes as candidate_process
    where candidate_process.id = candidate.id
      and candidate_process.version = candidate.version
    limit 1
  ) as process
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


alter function private.cmd_dataset_alias_batch_v2_guarded(jsonb) owner to postgres;
revoke all on function private.cmd_dataset_alias_batch_v2_guarded(jsonb) from public;
comment on function private.cmd_dataset_alias_batch_v2_guarded(jsonb) is
  'Versioned guarded v2 batch executor: all-or-none validation-then-write, exact reference closure, recomputed target and source evidence, canonical digest parity, server-derived desired payloads, ordinary audit and exact replay. The fresh-run global occurrence closure is candidate-driven through the deployed processes_json_ordered_alias_exchange_gin_idx — the containment probe is a proven superset of the exact occurrence predicate in both deployed collection shapes — so its cost follows the plan rather than the Process table. v1 untouched.';
alter function util.read_dataset_alias_execution_v2_primary_closure(uuid, jsonb) owner to postgres;
revoke all on function util.read_dataset_alias_execution_v2_primary_closure(uuid, jsonb) from public;
comment on function util.read_dataset_alias_execution_v2_primary_closure(uuid, jsonb) is
  'Fresh Time-v2 primary closure readback: every claimed row must currently hold exactly its claimed desired payload for this actor in the owner-draft state, and the plan''s frozen support and global occurrence closure must still be current — the canonical target property and unit group, the source alias flow property and its declared source unit group, no remaining source-alias Flow outside the plan, and the exact live occurrence set of the changed Flows across all owners and states. The occurrence set is read candidate-driven through the deployed processes_json_ordered_alias_exchange_gin_idx, so its cost follows the plan rather than the Process table. A drifted support or consumer makes live_closure_proof false; an unverifiable shape fails closed.';
alter function private.cmd_dataset_length_time_v1_guarded(jsonb) owner to postgres;
revoke all on function private.cmd_dataset_length_time_v1_guarded(jsonb) from public;
alter function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) owner to postgres;
revoke all on function util.read_dataset_length_time_v1_primary_closure(uuid, jsonb) from public;
