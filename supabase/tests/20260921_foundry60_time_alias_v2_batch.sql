-- Foundry #60 / Database #673 — v2 batch executor behaviour suite (real rows, TDD).
--
-- Behaviours pinned here, on the real deployed payload shapes:
--   * a real small success applies: the flow's five-key flow-property reference moves to the locked target
--     (common:shortDescription projected from the target's own common:name object), the bound exchange
--     amounts move by the exact factor, the reviewed functional-unit leaf moves, audit rows are written;
--   * a write-pass-induced failure rolls back every already-written row and every audit row;
--   * an exact resubmission returns the stored proof and writes nothing (0 writes, 0 audit rows);
--   * closure, scope, target and derivation negatives are refused for their own reason (details name the
--     offender), never incidentally.
-- No has_function/grep/hash proxies anywhere.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, private;

select plan(60);

-- ------------------------------------------------------------------------------------------------
-- Fixture: one target unit group, one target flow property (real common:name language object), one alias
-- flow property, one alias Product flow, one foreign consumer id, one process carrying one alias exchange
-- (stored exponent literal) plus one unrelated exchange, and two spare consumer ids used by the negatives.
create temp table v2_fixture (
  actor uuid,
  foreign_actor uuid,
  target_ug uuid,
  target_fp uuid,
  alias_fp uuid,
  flow_id uuid,
  foreign_flow_id uuid,
  process_id uuid,
  uncertain_flow_id uuid,
  uncertain_process_id uuid,
  mismatch_process_id uuid
) on commit drop;

insert into v2_fixture values (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444',
  '55555555-5555-4555-8555-555555555555',
  '66666666-6666-4666-8666-666666666666',
  '77777777-7777-4777-8777-777777777777',
  '88888888-8888-4888-8888-888888888888',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
);

-- The deployed five-key reference: @refObjectId/@type/@uri(.json)/@version and one language-tagged
-- common:shortDescription object — the shape the live 113 Flow references carry.
create or replace function pg_temp.v2_ref(p_kind text, p_type text, p_id uuid, p_version text, p_name text)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    '@refObjectId', p_id,
    '@type', p_type,
    '@uri', '../' || p_kind || '/' || p_id || '.json',
    '@version', p_version,
    'common:shortDescription', jsonb_build_object('@xml:lang', 'en', '#text', p_name))
$$;

-- A real Product flow: object-shaped internal-ID-1 property entry, internal quantitative-reference pointer
-- that never moves, and the Product flow eligibility field the plan requires.
create or replace function pg_temp.v2_flow(p_id uuid, p_version text, p_fp uuid, p_fp_version text, p_fp_name text)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'flowDataSet', jsonb_build_object(
      'flowInformation', jsonb_build_object(
        'dataSetInformation', jsonb_build_object('common:UUID', p_id),
        'quantitativeReference', jsonb_build_object('referenceToReferenceFlowProperty', '1')),
      'modellingAndValidation', jsonb_build_object(
        'LCIMethod', jsonb_build_object('typeOfDataSet', 'Product flow')),
      'flowProperties', jsonb_build_object(
        'flowProperty', jsonb_build_object(
          '@dataSetInternalID', '1',
          'meanValue', '1.0',
          'referenceToFlowPropertyDataSet', pg_temp.v2_ref('flowproperties', 'flow property data set', p_fp, p_fp_version, p_fp_name))),
      'administrativeInformation', jsonb_build_object(
        'publicationAndOwnership', jsonb_build_object('common:dataSetVersion', p_version))))
$$;

-- A real process shape: TIDAS internal ids "1"/"2"/"3" for the exchanges while the reviewed source tuples
-- carry the original EcoSpold numbers in their generalComment (730045 output reference, 730046 input); the
-- reference-output source quantity is 1, matching a "1.0 a" functional unit. The third exchange references
-- another flow and is the unrelated complement.
create or replace function pg_temp.v2_process(
  p_id uuid, p_version text, p_flow uuid, p_flow_version text, p_flow_name text,
  p_alias_extra jsonb default '{}'::jsonb
)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'processDataSet', jsonb_build_object(
      'processInformation', jsonb_build_object(
        'dataSetInformation', jsonb_build_object('common:UUID', p_id),
        'quantitativeReference', jsonb_build_object(
          'referenceToReferenceFlow', '1',
          'functionalUnitOrOther', jsonb_build_object('@xml:lang', 'en', '#text', '1.0 a per unit'))),
      'exchanges', jsonb_build_object('exchange', jsonb_build_array(
        jsonb_build_object(
          '@dataSetInternalID', '1',
          'meanAmount', '1',
          'resultingAmount', '1',
          'exchangeDirection', 'Output',
          'generalComment', 'Reviewed source exchange 730045 (EcoSpold).',
          'referenceToFlowDataSet', pg_temp.v2_ref('flows', 'flow data set', p_flow, p_flow_version, p_flow_name))
        || p_alias_extra,
        jsonb_build_object(
          '@dataSetInternalID', '2',
          'meanAmount', '1.03E-4',
          'resultingAmount', '1.03E-4',
          'exchangeDirection', 'Input',
          'generalComment', 'Reviewed source exchange 730046 (EcoSpold).',
          'referenceToFlowDataSet', pg_temp.v2_ref('flows', 'flow data set', p_flow, p_flow_version, 'Alias flow')),
        jsonb_build_object(
          '@dataSetInternalID', '3',
          'meanAmount', '5',
          'resultingAmount', '5',
          'exchangeDirection', 'Input',
          'referenceToFlowDataSet', pg_temp.v2_ref('flows', 'flow data set', '99999999-9999-4999-8999-999999999999', '01.00.000', 'Other flow')))),
      'administrativeInformation', jsonb_build_object(
        'publicationAndOwnership', jsonb_build_object('common:dataSetVersion', p_version))))
$$;

-- Transaction-local vault prerequisites the row triggers need (fixture values only).
delete from vault.secrets where name in ('project_secret_key', 'project_url');
select vault.create_secret('fixture-service-secret', 'project_secret_key', 'transaction-local v2 batch test key');
select vault.create_secret('http://127.0.0.1:55341', 'project_url', 'transaction-local v2 batch test URL');

insert into public.unitgroups (id, version, user_id, state_code, json_ordered, modified_at)
select target_ug, '01.00.000', actor, 0,
  to_json(jsonb_build_object('unitGroupDataSet', jsonb_build_object(
    'unitGroupInformation', jsonb_build_object('quantitativeReference', jsonb_build_object(
      'referenceToReferenceUnit', jsonb_build_array(
        jsonb_build_object('@dataSetInternalID', '1', '@unitName', 'a', 'meanValue', '1'),
        jsonb_build_object('@dataSetInternalID', '2', '@unitName', 'hr', 'meanValue', '0.00011415525114155251')
      )
    )),
    'administrativeInformation', jsonb_build_object(
      'publicationAndOwnership', jsonb_build_object('common:dataSetVersion', '01.00.000'))
  ))),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
-- The target flow property: name lives at flowPropertiesInformation.dataSetInformation["common:name"] as a
-- single language object — never at a Process-shaped name/baseName path.
insert into public.flowproperties (id, version, user_id, state_code, json_ordered, modified_at)
select target_fp, '01.00.000', actor, 0,
  to_json(jsonb_build_object('flowPropertyDataSet', jsonb_build_object(
    'flowPropertiesInformation', jsonb_build_object(
      'dataSetInformation', jsonb_build_object(
        'common:UUID', target_fp,
        'common:name', jsonb_build_object('@xml:lang', 'en', '#text', 'Time'),
        'common:other', 'urn:fixture:time'
      ),
      'quantitativeReference', jsonb_build_object(
        'referenceToReferenceUnitGroup', pg_temp.v2_ref('unitgroups', 'unit group data set', target_ug, '01.00.000', 'Units of time')
      )
    ),
    'administrativeInformation', jsonb_build_object(
      'publicationAndOwnership', jsonb_build_object('common:dataSetVersion', '01.00.000'))
  ))),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.flowproperties (id, version, user_id, state_code, json_ordered, modified_at)
select alias_fp, '00.00.001', actor, 0,
  to_json(jsonb_build_object('flowPropertyDataSet', jsonb_build_object(
    'flowPropertiesInformation', jsonb_build_object(
      'dataSetInformation', jsonb_build_object('common:UUID', alias_fp),
      'quantitativeReference', jsonb_build_object(
        'referenceToReferenceUnitGroup', pg_temp.v2_ref('unitgroups', 'unit group data set', target_ug, '01.00.000', 'Units of time')
      )
    ),
    'administrativeInformation', jsonb_build_object(
      'publicationAndOwnership', jsonb_build_object('common:dataSetVersion', '00.00.001'))
  ))),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select flow_id, '01.00.000', actor, 0, to_json(pg_temp.v2_flow(flow_id, '01.00.000', alias_fp, '00.00.001', 'Alias property')),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at)
select process_id, '01.00.000', actor, 0,
  to_json(pg_temp.v2_process(process_id, '01.00.000', flow_id, '01.00.000', 'Alias flow')),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;

-- ------------------------------------------------------------------------------------------------
-- A small, real, valid batch: one flow action and one process action bound to the alias exchange. The
-- extra_flows/extra_processes slots append further claimed actions and keep the derived counts consistent.
create or replace function pg_temp.v2_batch(p_extras jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable as $$
declare
  f record;
  v_extra_flows jsonb := coalesce(p_extras->'flows', '[]'::jsonb);
  v_extra_processes jsonb := coalesce(p_extras->'processes', '[]'::jsonb);
  v_desired_flow jsonb;
  v_desired_process jsonb;
  v_occurrences integer;
  v_selected integer;
begin
  select * into f from v2_fixture;
  v_desired_flow := pg_temp.v2_flow(f.flow_id, '01.00.000', f.target_fp, '01.00.000', 'Time');
  v_desired_process := jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            pg_temp.v2_process(f.process_id, '01.00.000', f.flow_id, '01.00.000', 'Alias flow'),
            '{processDataSet,exchanges,exchange,0,meanAmount}',
            to_jsonb(private.dataset_alias_v2_multiply_amount('1', private.dataset_alias_v2_factor()::text)), false),
          '{processDataSet,exchanges,exchange,0,resultingAmount}',
          to_jsonb(private.dataset_alias_v2_multiply_amount('1', private.dataset_alias_v2_factor()::text)), false),
        '{processDataSet,exchanges,exchange,1,meanAmount}',
        to_jsonb(private.dataset_alias_v2_multiply_amount('1.03E-4', private.dataset_alias_v2_factor()::text)), false),
      '{processDataSet,exchanges,exchange,1,resultingAmount}',
      to_jsonb(private.dataset_alias_v2_multiply_amount('1.03E-4', private.dataset_alias_v2_factor()::text)), false),
    '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}', to_jsonb('1.0 hr per unit'::text), false);
  select 2 + coalesce(sum(jsonb_array_length(coalesce(a->'mutation'->'exchanges', '[]'::jsonb))), 0)
    into v_occurrences
  from jsonb_array_elements(v_extra_processes) as a;
  select 3 + coalesce(sum(jsonb_array_length(coalesce(a->'expected_json_ordered' #> '{processDataSet,exchanges,exchange}', '[]'::jsonb))), 0)
    into v_selected
  from jsonb_array_elements(v_extra_processes) as a;
  return jsonb_build_object(
    'schema_version', 'dataset-alias-batch.v2',
    'batch_id', 'fixture-batch-1',
    'operation_id', 'fixture-operation-1',
    'plan_sha256', repeat('a', 64),
    'dimension', 'time',
    'factor', '0.00011415525114155251',
    'target_visibility', 'owner_draft',
    'target_snapshots', jsonb_build_object(
      'flowproperty', jsonb_build_object('id', f.target_fp, 'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select json_ordered::jsonb from public.flowproperties where id = f.target_fp and version = '01.00.000'))),
      'unitgroup', jsonb_build_object('id', f.target_ug, 'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select json_ordered::jsonb from public.unitgroups where id = f.target_ug and version = '01.00.000'))),
      'reference', pg_temp.v2_ref('flowproperties', 'flow property data set', f.target_fp, '01.00.000', 'Time')),
    'source_evidence', jsonb_build_object('sha256', repeat('b', 64), 'exchange_count', v_occurrences),
    'counts', jsonb_build_object(
      'action_count', 2 + jsonb_array_length(v_extra_flows) + jsonb_array_length(v_extra_processes),
      'flow_count', 1 + jsonb_array_length(v_extra_flows),
      'process_count', 1 + jsonb_array_length(v_extra_processes),
      'exchange_count', v_occurrences,
      'unrelated_exchange_count', v_selected - v_occurrences,
      'flowproperty_count', 0),
    'actions', jsonb_build_array(
      jsonb_build_object(
        'action_id', 'flow-1', 'table', 'flows', 'id', f.flow_id, 'version', '01.00.000',
        'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
        'expected_json_ordered', pg_temp.v2_flow(f.flow_id, '01.00.000', f.alias_fp, '00.00.001', 'Alias property'),
        'desired_json_ordered', v_desired_flow,
        'mutation', jsonb_build_object('reference_id', f.target_fp, 'reference_version', '01.00.000')))
      || v_extra_flows
      || jsonb_build_array(
        jsonb_build_object(
          'action_id', 'process-1', 'table', 'processes', 'id', f.process_id, 'version', '01.00.000',
          'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
          'expected_json_ordered', pg_temp.v2_process(f.process_id, '01.00.000', f.flow_id, '01.00.000', 'Alias flow'),
          'desired_json_ordered', v_desired_process,
          'mutation', jsonb_build_object(
            'exchanges', jsonb_build_array(
              jsonb_build_object(
                'index', 0, 'internal_id', '1', 'source_exchange_number', '730045',
                'flow_id', f.flow_id, 'flow_version', '01.00.000', 'direction', 'Output',
                'before_amount', '1',
                'after_amount', private.dataset_alias_v2_multiply_amount('1', private.dataset_alias_v2_factor()::text)),
              jsonb_build_object(
                'index', 1, 'internal_id', '2', 'source_exchange_number', '730046',
                'flow_id', f.flow_id, 'flow_version', '01.00.000', 'direction', 'Input',
                'before_amount', '1.03E-4',
                'after_amount', private.dataset_alias_v2_multiply_amount('1.03E-4', private.dataset_alias_v2_factor()::text))),
            'functional_unit', jsonb_build_object(
              'path', 'processDataSet.processInformation.quantitativeReference.functionalUnitOrOther.#text',
              'before_text', '1.0 a per unit', 'after_text', '1.0 hr per unit', 'source_exchange_number', '730045'))))
      || v_extra_processes);
end
$$;

-- The executor is private by design; the suite reaches it through a superuser-owned wrapper that sets the
-- verified-actor claims the protected façade would set, exactly as the v1 suites do.
create or replace function pg_temp.v2_call(p_batch jsonb)
returns jsonb language plpgsql as $$
begin
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', (select actor::text from v2_fixture), true);
  perform set_config('request.jwt.claim.email', 'fixture@example.invalid', true);
  return private.cmd_dataset_alias_batch_v2_guarded(p_batch);
end
$$;

create temp table v2_before_state as
  select (select count(*) from private.command_audit_log) as audits,
    (select json_ordered::jsonb from public.flows where id = (select flow_id from v2_fixture)) as flow_payload,
    (select json_ordered::jsonb from public.processes where id = (select process_id from v2_fixture)) as process_payload,
    (select modified_at from public.flows where id = (select flow_id from v2_fixture)) as flow_modified,
    (select modified_at from public.processes where id = (select process_id from v2_fixture)) as process_modified;

-- ================================================================================================
-- 1. Negatives on the pristine rows. None of them may write.
-- ================================================================================================

-- 1.1 a stale second action is a content drift, not a closure problem
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,1,expected_modified_at}', '"2020-01-01T00:00:00+00:00"'::jsonb)) ->> 'code'),
  'ALIAS_V2_ACTION_DRIFT',
  'a stale second action refuses the whole batch as a drift'
);

-- 1.2 an omitted consumer breaks the exchange closure, and the refusal names the live occurrence
create temp table v2_neg_omit as select pg_temp.v2_call(
  jsonb_set(
    jsonb_set(pg_temp.v2_batch() #- '{actions,1}',
      '{counts}', jsonb_build_object('action_count', 1, 'flow_count', 1, 'process_count', 0,
        'exchange_count', 0, 'unrelated_exchange_count', 0, 'flowproperty_count', 0)),
    '{source_evidence,exchange_count}', '0'::jsonb)
) as result;
select is((select result->>'code' from v2_neg_omit), 'ALIAS_V2_CLOSURE_MISMATCH', 'an omitted consumer is refused as a closure mismatch');
select ok(exists (
  select 1 from jsonb_array_elements((select result->'details' from v2_neg_omit) -> 'live_occurrences') as live
  where live->>'process_id' = (select process_id::text from v2_fixture)
), 'the closure refusal names the unclaimed live occurrence');

-- 1.3 scope eligibility: only Product flows may enter the maintenance path
select is(
  (pg_temp.v2_call(pg_temp.v2_batch() #- '{actions,0,expected_json_ordered,flowDataSet,modellingAndValidation}') ->> 'code'),
  'ALIAS_V2_BATCH_INVALID',
  'a flow without the typeOfDataSet eligibility field is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,0,expected_json_ordered,flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}', '"Elementary flow"'::jsonb)) ->> 'code'),
  'ALIAS_V2_BATCH_INVALID',
  'an Elementary flow is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,0,expected_json_ordered,flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}', '"Waste flow"'::jsonb)) ->> 'code'),
  'ALIAS_V2_BATCH_INVALID',
  'a Waste flow is refused'
);

-- 1.4 the functional-unit mutation must be the process's own reference-flow exchange, one of its bound
-- exchanges, and only the reviewed leaf may move
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,source_exchange_number}', '"730046"'::jsonb)) ->> 'code')
    || ' / ' || (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,source_exchange_number}', '"730046"'::jsonb)) ->> 'message'),
  'ALIAS_V2_TEXT_RULE_VIOLATION / The functional-unit source exchange number is not the reference exchange''s reviewed source number',
  'a functional-unit source number that is not the reference exchange''s own source number is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,source_exchange_number}', '"2"'::jsonb)) ->> 'code')
    || ' / ' || (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,source_exchange_number}', '"2"'::jsonb)) ->> 'message'),
  'ALIAS_V2_TEXT_RULE_VIOLATION / The functional-unit source exchange number is not the reference exchange''s reviewed source number',
  'a TIDAS internal id used where the original EcoSpold source number belongs is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(
    jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,source_exchange_number}', '"730046"'::jsonb),
    '{actions,1,mutation,exchanges,0,source_exchange_number}', '"730046"'::jsonb)) ->> 'code')
    || ' / ' || (pg_temp.v2_call(jsonb_set(
      jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,source_exchange_number}', '"730046"'::jsonb),
      '{actions,1,mutation,exchanges,0,source_exchange_number}', '"730046"'::jsonb)) ->> 'message'),
  'ALIAS_V2_EVIDENCE_MISMATCH / The reviewed source comment of the reference exchange does not carry the declared source exchange number',
  'a source number contradicting the stored reviewed source comment is refused'
);
select ok(
  (pg_temp.v2_batch() #>> '{actions,1,mutation,exchanges,0,internal_id}') = '1'
    and (pg_temp.v2_batch() #>> '{actions,1,mutation,exchanges,0,source_exchange_number}') = '730045'
    and (pg_temp.v2_batch() #>> '{actions,1,mutation,exchanges,1,internal_id}') = '2'
    and (pg_temp.v2_batch() #>> '{actions,1,mutation,exchanges,1,source_exchange_number}') = '730046',
  'the fixture binds TIDAS internal ids and original source numbers as distinct namespaces'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,path}', '"processDataSet.processInformation.dataSetInformation.common:UUID"'::jsonb)) ->> 'code'),
  'ALIAS_V2_TEXT_RULE_VIOLATION',
  'a functional-unit path outside the reviewed leaf is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,1,mutation,functional_unit,evidence}', '"x"'::jsonb)) ->> 'code'),
  'ALIAS_V2_TEXT_RULE_VIOLATION',
  'a functional-unit block with an unknown key is refused'
);

-- 1.5 the flow mutation must name the derived target reference
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions,0,mutation,reference_id}', '"99999999-9999-4999-8999-999999999999"'::jsonb)) ->> 'code'),
  'ALIAS_V2_DERIVE_MISMATCH',
  'a flow mutation naming another reference is refused'
);

-- 1.6 target evidence: snapshot digest and the derived canonical reference
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{target_snapshots,flowproperty,sha256}', to_jsonb(repeat('c', 64)))) ->> 'code'),
  'ALIAS_V2_EVIDENCE_MISMATCH',
  'a target snapshot digest that does not match the locked row is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{target_snapshots,reference,common:shortDescription,#text}', '"Alias property"'::jsonb)) ->> 'code'),
  'ALIAS_V2_EVIDENCE_MISMATCH',
  'a declared reference that is not the canonical derived reference is refused'
);

-- 1.7 envelope, counts and source evidence
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{factor}', '"0.5"'::jsonb)) ->> 'code'),
  'ALIAS_V2_BATCH_INVALID',
  'a plan-supplied factor is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{counts,flow_count}', '2'::jsonb)) ->> 'code'),
  'ALIAS_V2_COUNT_MISMATCH',
  'counts that differ from the derived live counts are refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{source_evidence,exchange_count}', '9'::jsonb)) ->> 'code'),
  'ALIAS_V2_EVIDENCE_MISMATCH',
  'a source evidence exchange count that differs from the batch exchange count is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{actions}', (pg_temp.v2_batch()->'actions') || jsonb_build_array(pg_temp.v2_batch()->'actions'->0))) ->> 'code'),
  'ALIAS_V2_BATCH_INVALID',
  'a duplicate action identity is refused'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{note}', '"x"'::jsonb)) ->> 'code'),
  'ALIAS_V2_BATCH_INVALID',
  'an unknown batch key is refused'
);

-- 1.8 a foreign live consumer of the alias property breaks the closure, and the refusal names it
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select foreign_flow_id, '01.00.000', foreign_actor, 0,
  to_json(pg_temp.v2_flow(foreign_flow_id, '01.00.000', alias_fp, '00.00.001', 'Alias property')), timestamp '2026-09-21 00:00:00'
from v2_fixture;
create temp table v2_neg_foreign as select pg_temp.v2_call(pg_temp.v2_batch()) as result;
select is((select result->>'code' from v2_neg_foreign), 'ALIAS_V2_CLOSURE_MISMATCH', 'a foreign consumer of the alias property is refused');
select ok(exists (
  select 1 from jsonb_array_elements((select result->'details' from v2_neg_foreign) -> 'live_flows') as live
  where live->>'id' = (select foreign_flow_id::text from v2_fixture)
    and live->>'user_id' = (select foreign_actor::text from v2_fixture)
), 'the closure refusal names the foreign live consumer');
delete from public.flows where id = (select foreign_flow_id from v2_fixture);

-- 1.9 a same-id different-version consumer is a distinct live consumer
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select flow_id, '02.00.000', actor, 0,
  to_json(pg_temp.v2_flow(flow_id, '02.00.000', alias_fp, '00.00.001', 'Alias property')), timestamp '2026-09-21 00:00:00'
from v2_fixture;
create temp table v2_neg_version as select pg_temp.v2_call(pg_temp.v2_batch()) as result;
select is((select result->>'code' from v2_neg_version), 'ALIAS_V2_CLOSURE_MISMATCH', 'a same-id second-version consumer is refused');
select ok(exists (
  select 1 from jsonb_array_elements((select result->'details' from v2_neg_version) -> 'live_flows') as live
  where live->>'version' = '02.00.000'
), 'the closure refusal names the second-version consumer');
delete from public.flows where id = (select flow_id from v2_fixture) and version = '02.00.000';

-- 1.10 a stored absolute uncertainty bound has no reviewed scaling and fails the closed key set
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select uncertain_flow_id, '01.00.000', actor, 0,
  to_json(pg_temp.v2_flow(uncertain_flow_id, '01.00.000', alias_fp, '00.00.001', 'Alias property')), timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at)
select uncertain_process_id, '01.00.000', actor, 0,
  to_json(pg_temp.v2_process(uncertain_process_id, '01.00.000', uncertain_flow_id, '01.00.000', 'Alias flow',
    jsonb_build_object('absoluteStandardDeviation95In', '0.1'))), timestamp '2026-09-21 00:00:00'
from v2_fixture;
select is(
  (pg_temp.v2_call(pg_temp.v2_batch(jsonb_build_object(
    'flows', jsonb_build_array(jsonb_build_object(
      'action_id', 'flow-2', 'table', 'flows', 'id', (select uncertain_flow_id from v2_fixture), 'version', '01.00.000',
      'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
      'expected_json_ordered', pg_temp.v2_flow((select uncertain_flow_id from v2_fixture), '01.00.000', (select alias_fp from v2_fixture), '00.00.001', 'Alias property'),
      'desired_json_ordered', pg_temp.v2_flow((select uncertain_flow_id from v2_fixture), '01.00.000', (select target_fp from v2_fixture), '01.00.000', 'Time'),
      'mutation', jsonb_build_object('reference_id', (select target_fp from v2_fixture), 'reference_version', '01.00.000'))),
    'processes', jsonb_build_array(jsonb_build_object(
      'action_id', 'process-2', 'table', 'processes', 'id', (select uncertain_process_id from v2_fixture), 'version', '01.00.000',
      'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
      'expected_json_ordered', pg_temp.v2_process((select uncertain_process_id from v2_fixture), '01.00.000', (select uncertain_flow_id from v2_fixture), '01.00.000', 'Alias flow',
        jsonb_build_object('absoluteStandardDeviation95In', '0.1')),
      'desired_json_ordered', pg_temp.v2_process((select uncertain_process_id from v2_fixture), '01.00.000', (select uncertain_flow_id from v2_fixture), '01.00.000', 'Alias flow',
        jsonb_build_object('absoluteStandardDeviation95In', '0.1')),
      'mutation', jsonb_build_object('exchanges', jsonb_build_array(jsonb_build_object(
        'index', 0, 'internal_id', '1', 'source_exchange_number', '730001', 'flow_id', (select uncertain_flow_id from v2_fixture), 'flow_version', '01.00.000',
        'direction', 'Output', 'before_amount', '1', 'after_amount', private.dataset_alias_v2_multiply_amount('1', private.dataset_alias_v2_factor()::text)))))))))
  ) ->> 'code',
  'ALIAS_V2_DERIVE_MISMATCH',
  'a stored absolute uncertainty bound fails the closed exchange key set'
);
delete from public.processes where id = (select uncertain_process_id from v2_fixture);
delete from public.flows where id = (select uncertain_flow_id from v2_fixture);

-- 1.11 a reference exchange whose own source quantity is 5 cannot carry a "1.0 a" functional unit even
-- though the anchored spelling rule alone would accept the text
create temp table v2_mismatch_payload as
  select jsonb_set(jsonb_set(
      pg_temp.v2_process(mismatch_process_id, '01.00.000', flow_id, '01.00.000', 'Alias flow'),
      '{processDataSet,exchanges,exchange,0,meanAmount}', '"5"'::jsonb),
    '{processDataSet,exchanges,exchange,0,resultingAmount}', '"5"'::jsonb) as payload
  from v2_fixture;
insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at)
select mismatch_process_id, '01.00.000', actor, 0, to_json(payload), timestamp '2026-09-21 00:00:00'
from v2_fixture, v2_mismatch_payload;
select is(
  (pg_temp.v2_call(pg_temp.v2_batch(jsonb_build_object('processes', jsonb_build_array(jsonb_build_object(
    'action_id', 'process-mismatch', 'table', 'processes', 'id', (select mismatch_process_id from v2_fixture), 'version', '01.00.000',
    'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
    'expected_json_ordered', (select payload from v2_mismatch_payload),
    'desired_json_ordered', jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            jsonb_set((select payload from v2_mismatch_payload),
              '{processDataSet,exchanges,exchange,0,meanAmount}', to_jsonb(private.dataset_alias_v2_multiply_amount('5', private.dataset_alias_v2_factor()::text)), false),
            '{processDataSet,exchanges,exchange,0,resultingAmount}', to_jsonb(private.dataset_alias_v2_multiply_amount('5', private.dataset_alias_v2_factor()::text)), false),
          '{processDataSet,exchanges,exchange,1,meanAmount}', to_jsonb(private.dataset_alias_v2_multiply_amount('1.03E-4', private.dataset_alias_v2_factor()::text)), false),
        '{processDataSet,exchanges,exchange,1,resultingAmount}', to_jsonb(private.dataset_alias_v2_multiply_amount('1.03E-4', private.dataset_alias_v2_factor()::text)), false),
      '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}', to_jsonb('1.0 hr per unit'::text), false),
    'mutation', jsonb_build_object(
      'exchanges', jsonb_build_array(
        jsonb_build_object(
          'index', 0, 'internal_id', '1', 'source_exchange_number', '730048',
          'flow_id', (select flow_id from v2_fixture), 'flow_version', '01.00.000', 'direction', 'Output',
          'before_amount', '5',
          'after_amount', private.dataset_alias_v2_multiply_amount('5', private.dataset_alias_v2_factor()::text)),
        jsonb_build_object(
          'index', 1, 'internal_id', '2', 'source_exchange_number', '730046',
          'flow_id', (select flow_id from v2_fixture), 'flow_version', '01.00.000', 'direction', 'Input',
          'before_amount', '1.03E-4',
          'after_amount', private.dataset_alias_v2_multiply_amount('1.03E-4', private.dataset_alias_v2_factor()::text))),
      'functional_unit', jsonb_build_object(
        'path', 'processDataSet.processInformation.quantitativeReference.functionalUnitOrOther.#text',
        'before_text', '1.0 a per unit', 'after_text', '1.0 hr per unit', 'source_exchange_number', '730048'))))))) ->> 'code')
    || ' / ' ||
    (pg_temp.v2_call(pg_temp.v2_batch(jsonb_build_object('processes', jsonb_build_array(jsonb_build_object(
      'action_id', 'process-mismatch', 'table', 'processes', 'id', (select mismatch_process_id from v2_fixture), 'version', '01.00.000',
      'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
      'expected_json_ordered', (select payload from v2_mismatch_payload),
      'desired_json_ordered', (select payload from v2_mismatch_payload),
      'mutation', jsonb_build_object(
        'exchanges', jsonb_build_array(
          jsonb_build_object(
            'index', 0, 'internal_id', '1', 'source_exchange_number', '730048',
            'flow_id', (select flow_id from v2_fixture), 'flow_version', '01.00.000', 'direction', 'Output',
            'before_amount', '5',
            'after_amount', private.dataset_alias_v2_multiply_amount('5', private.dataset_alias_v2_factor()::text)),
          jsonb_build_object(
            'index', 1, 'internal_id', '2', 'source_exchange_number', '730046',
            'flow_id', (select flow_id from v2_fixture), 'flow_version', '01.00.000', 'direction', 'Input',
            'before_amount', '1.03E-4',
            'after_amount', private.dataset_alias_v2_multiply_amount('1.03E-4', private.dataset_alias_v2_factor()::text))),
        'functional_unit', jsonb_build_object(
          'path', 'processDataSet.processInformation.quantitativeReference.functionalUnitOrOther.#text',
          'before_text', '1.0 a per unit', 'after_text', '1.0 hr per unit', 'source_exchange_number', '730048'))))))) ->> 'message'),
  'ALIAS_V2_TEXT_RULE_VIOLATION / The functional-unit quantity is not the reference exchange''s reviewed source quantity',
  'a functional-unit quantity that is not the reference exchange quantity is refused'
);
delete from public.processes where id = (select mismatch_process_id from v2_fixture);

-- ================================================================================================
-- 2. A failure induced inside the write pass must roll back rows and audit alike.
-- ================================================================================================
create or replace function pg_temp.v2_fail_process_write()
returns trigger language plpgsql as $$
begin
  if current_setting('fixture.v2_write_fail', true) = 'on' then
    raise exception 'fixture-induced write-pass failure' using errcode = '23505';
  end if;
  return new;
end
$$;
create trigger v2_fail_process_write before update on public.processes
  for each row execute function pg_temp.v2_fail_process_write();
set local fixture.v2_write_fail = 'on';
create temp table v2_late as select pg_temp.v2_call(pg_temp.v2_batch()) as result;
set local fixture.v2_write_fail = 'off';
drop trigger v2_fail_process_write on public.processes;

select is((select result->>'code' from v2_late), 'ALIAS_V2_INTERNAL_ERROR', 'a write-pass failure is reported as an internal failure');
select is(
  (select json_ordered::jsonb from public.flows where id = (select flow_id from v2_fixture)),
  (select flow_payload from v2_before_state),
  'the already-updated flow row is rolled back by the write-pass failure'
);
select is(
  (select modified_at from public.flows where id = (select flow_id from v2_fixture)),
  (select flow_modified from v2_before_state),
  'the flow modified_at is untouched by the write-pass failure'
);
select is(
  (select json_ordered::jsonb from public.processes where id = (select process_id from v2_fixture)),
  (select process_payload from v2_before_state),
  'the process row is untouched by the write-pass failure'
);
select is(
  (select count(*) from private.command_audit_log),
  (select audits from v2_before_state),
  'no audit row survives the write-pass failure'
);

-- ================================================================================================
-- 3. The real small success.
-- ================================================================================================
create temp table v2_first as select pg_temp.v2_call(pg_temp.v2_batch()) as result;
select is((select result->>'ok' from v2_first), 'true', 'a real small batch applies');
select is((select result->>'code' from v2_first), 'ALIAS_V2_BATCH_APPLIED', 'the applied code is returned');
select is((select result#>>'{counts,flow_count}' from v2_first), '1', 'one flow action is counted');
select is((select result#>>'{counts,exchange_count}' from v2_first), '2', 'both bound exchange occurrences are counted');
select is((select result#>>'{counts,unrelated_exchange_count}' from v2_first), '1', 'the unrelated complement is inside the selected process');
select is((select result#>>'{counts,fu_text_actions}' from v2_first), '1', 'one functional-unit text action is counted');
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}' from public.flows where id = (select flow_id from v2_fixture)),
  (select target_fp::text from v2_fixture),
  'the flow now references the target property'
);
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@version}' from public.flows where id = (select flow_id from v2_fixture)),
  '01.00.000',
  'the derived reference carries the target version'
);
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@type}' from public.flows where id = (select flow_id from v2_fixture)),
  'flow property data set',
  'the derived reference keeps the deployed @type'
);
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@uri}' from public.flows where id = (select flow_id from v2_fixture)),
  '../flowproperties/' || (select target_fp::text from v2_fixture) || '.json',
  'the derived reference keeps the .json uri convention with the target id'
);
select is(
  (select jsonb_typeof(json_ordered::jsonb #> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,common:shortDescription}') from public.flows where id = (select flow_id from v2_fixture)),
  'object',
  'the derived reference description is a single language object'
);
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,common:shortDescription,#text}' from public.flows where id = (select flow_id from v2_fixture)),
  'Time',
  'the description is the target flow property''s own common:name text'
);
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowInformation,quantitativeReference,referenceToReferenceFlowProperty}' from public.flows where id = (select flow_id from v2_fixture)),
  '1',
  'the internal quantitative-reference pointer never moves'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,0,meanAmount}' from public.processes where id = (select process_id from v2_fixture)),
  '0.00011415525114155251',
  'the reference output exchange (internal id 1, source 730045, quantity 1) moved by the fixed factor'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,0,resultingAmount}' from public.processes where id = (select process_id from v2_fixture)),
  '0.00011415525114155251',
  'the reference output resultingAmount moved by the fixed factor'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,1,meanAmount}' from public.processes where id = (select process_id from v2_fixture)),
  '0.00000001175799086757990853',
  'the bound input exchange (internal id 2, source 730046) moved by the fixed factor'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,2,meanAmount}' from public.processes where id = (select process_id from v2_fixture)),
  '5',
  'the unrelated exchange amount is untouched'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,0,generalComment}' from public.processes where id = (select process_id from v2_fixture)),
  'Reviewed source exchange 730045 (EcoSpold).',
  'the reviewed source tuple of the reference output survives the amount move'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,1,generalComment}' from public.processes where id = (select process_id from v2_fixture)),
  'Reviewed source exchange 730046 (EcoSpold).',
  'the second source tuple survives independently of the first'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}' from public.processes where id = (select process_id from v2_fixture)),
  '1',
  'the TIDAS internal reference-flow pointer never moves'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}' from public.processes where id = (select process_id from v2_fixture)),
  '1.0 hr per unit',
  'the reviewed functional-unit leaf moved under the anchored rule'
);
select ok(
  (select modified_at from public.flows where id = (select flow_id from v2_fixture)) > (select flow_modified from v2_before_state),
  'the applied row carries a fresh modified_at'
);
select is(
  (select count(*) from private.command_audit_log),
  (select audits + 3 from v2_before_state),
  'two row audit entries and one plan summary are written'
);
select ok(exists (
  select 1 from private.command_audit_log as audit_log
  where audit_log.command = 'cmd_dataset_alias_batch_v2_guarded'
    and audit_log.payload->>'record_type' = 'plan'
    and audit_log.payload->>'plan_sha256' = repeat('a', 64)
    and audit_log.payload#>>'{source_evidence,sha256}' = repeat('b', 64)
), 'the plan summary durably binds the source evidence digest');
create temp table v2_after_state as
  select (select modified_at from public.flows where id = (select flow_id from v2_fixture)) as flow_modified;

-- ================================================================================================
-- 4. Exact resubmission: the stored proof, zero writes.
-- ================================================================================================
create temp table v2_replay as select pg_temp.v2_call(pg_temp.v2_batch()) as result;
select is((select result->>'code' from v2_replay), 'ALIAS_V2_BATCH_REPLAYED', 'an exact resubmission reports the stored replay proof');
select is((select result->>'idempotent_replay' from v2_replay), 'true', 'the replay is flagged idempotent');
select is(
  (select count(*) from private.command_audit_log),
  (select audits + 3 from v2_before_state),
  'an exact replay writes no further audit row'
);
select is(
  (select modified_at from public.flows where id = (select flow_id from v2_fixture)),
  (select flow_modified from v2_after_state),
  'an exact replay leaves the applied rows untouched'
);
select is(
  (pg_temp.v2_call(jsonb_set(pg_temp.v2_batch(), '{source_evidence,sha256}', to_jsonb(repeat('c', 64)))) ->> 'code'),
  'ALIAS_V2_REPLAY_CONFLICT',
  'a resubmission carrying different source evidence is refused as a replay conflict'
);

select * from finish();
rollback;
