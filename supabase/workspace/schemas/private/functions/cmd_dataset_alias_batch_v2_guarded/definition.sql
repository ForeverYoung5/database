CREATE OR REPLACE FUNCTION "private"."cmd_dataset_alias_batch_v2_guarded"("p_batch" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "lock_timeout" TO '5s'
    AS $_$
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
      -- The deployed rows nest the quantitative reference under unitGroupInformation (the path the
      -- official authenticated export and the deployed expression index both show); the reviewed
      -- producer's synthetic cohort carries the same string one level up, directly under
      -- unitGroupDataSet. Both spellings name the same internal id and the table itself is only ever
      -- read from units.unit[].
      v_reference_unit_id text := coalesce(
        v_target_ug #>> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}',
        v_target_ug #>> '{unitGroupDataSet,quantitativeReference,referenceToReferenceUnit}');
    begin
      if v_target_fp #>> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@refObjectId}'
          is distinct from p_batch #>> '{target_snapshots,unitgroup,id}'
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
          'The target unit group does not carry the reviewed year base and exact hour factor');
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
$_$;

ALTER FUNCTION "private"."cmd_dataset_alias_batch_v2_guarded"("p_batch" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."cmd_dataset_alias_batch_v2_guarded"("p_batch" "jsonb") FROM PUBLIC;
