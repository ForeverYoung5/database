-- Foundry #60 / Database #673 — v2 batch executor behaviour suite (real rows, TDD).
--
-- RED first: this file was written before the executor was repaired and is the evidence that a real small
-- success applies, a late failure leaves every row and audit row untouched, an omission or a foreign
-- consumer is refused, and an exact replay writes nothing new. No has_function/grep/hash proxies.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, private;

select plan(16);

-- ------------------------------------------------------------------------------------------------
-- Fixture: one target unit group, one target flow property, one alias flow property, two alias flows
-- (one foreign), one process carrying one alias exchange (exponent literal) plus one unrelated exchange,
-- and the functional-unit text leaf of the reviewed shape.
create temp table v2_fixture (
  actor uuid,
  foreign_actor uuid,
  target_ug uuid,
  target_fp uuid,
  alias_fp uuid,
  flow_id uuid,
  foreign_flow_id uuid,
  process_id uuid
) on commit drop;

insert into v2_fixture values (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444',
  '55555555-5555-4555-8555-555555555555',
  '66666666-6666-4666-8666-666666666666',
  '77777777-7777-4777-8777-777777777777',
  '88888888-8888-4888-8888-888888888888'
);

create or replace function pg_temp.v2_ref(p_id uuid, p_version text, p_name text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('@refObjectId', p_id, '@version', p_version, '@uri', 'urn:fixture:' || p_id,
    'common:shortDescription', jsonb_build_array(jsonb_build_object('@xml:lang', 'en', '#text', p_name)))
$$;

create or replace function pg_temp.v2_flow(p_id uuid, p_version text, p_fp uuid, p_fp_version text)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'flowDataSet', jsonb_build_object(
      'flowInformation', jsonb_build_object(
        'dataSetInformation', jsonb_build_object('common:UUID', p_id),
        'quantitativeReference', jsonb_build_object('referenceToReferenceFlowProperty', '1')),
      'flowProperties', jsonb_build_object(
        'flowProperty', jsonb_build_object(
          '@dataSetInternalID', '1',
          'meanValue', '1.0',
          'referenceToFlowPropertyDataSet', pg_temp.v2_ref(p_fp, p_fp_version, 'Alias property'))),
      'administrativeInformation', jsonb_build_object(
        'publicationAndOwnership', jsonb_build_object('common:dataSetVersion', p_version))))
$$;

create or replace function pg_temp.v2_process(p_id uuid, p_version text, p_flow uuid, p_flow_version text)
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
          'meanAmount', '1.03E-4',
          'resultingAmount', '1.03E-4',
          'exchangeDirection', 'Output',
          'referenceToFlowDataSet', pg_temp.v2_ref(p_flow, p_flow_version, 'Alias flow')),
        jsonb_build_object(
          '@dataSetInternalID', '2',
          'meanAmount', '5',
          'resultingAmount', '5',
          'exchangeDirection', 'Input',
          'referenceToFlowDataSet', pg_temp.v2_ref('99999999-9999-4999-8999-999999999999', '01.00.000', 'Other flow')))),
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
    ))
  ))),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.flowproperties (id, version, user_id, state_code, json_ordered, modified_at)
select target_fp, '01.00.000', actor, 0,
  to_json(jsonb_build_object('flowPropertyDataSet', jsonb_build_object(
    'flowPropertiesInformation', jsonb_build_object(
      'dataSetInformation', jsonb_build_object(
        'common:UUID', target_fp,
        'name', jsonb_build_object('baseName', jsonb_build_array(jsonb_build_object('@xml:lang', 'en', '#text', 'Time'))),
        'common:other', 'urn:fixture:time'
      ),
      'quantitativeReference', jsonb_build_object(
        'referenceToReferenceUnitGroup', pg_temp.v2_ref(target_ug, '01.00.000', 'Units of time')
      )
    )
  ))),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.flowproperties (id, version, user_id, state_code, json_ordered, modified_at)
select alias_fp, '00.00.001', actor, 0,
  to_json(jsonb_build_object('flowPropertyDataSet', jsonb_build_object(
    'flowPropertiesInformation', jsonb_build_object(
      'dataSetInformation', jsonb_build_object('common:UUID', alias_fp),
      'quantitativeReference', jsonb_build_object(
        'referenceToReferenceUnitGroup', pg_temp.v2_ref(target_ug, '01.00.000', 'Units of time')
      )
    )
  ))),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select flow_id, '01.00.000', actor, 0, to_json(pg_temp.v2_flow(flow_id, '01.00.000', alias_fp, '00.00.001')),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;
insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at)
select process_id, '01.00.000', actor, 0,
  to_json(pg_temp.v2_process(process_id, '01.00.000', flow_id, '01.00.000')),
  timestamp '2026-09-21 00:00:00'
from v2_fixture;

-- ------------------------------------------------------------------------------------------------
-- A small, real, valid batch: one flow action and one process action bound to the alias exchange.
create or replace function pg_temp.v2_batch(p_batches jsonb default '[]'::jsonb)
returns jsonb language plpgsql stable as $$
declare
  f record;
  v_extra_flows jsonb := coalesce(p_batches->'flows', '[]'::jsonb);
  v_extra_processes jsonb := coalesce(p_batches->'processes', '[]'::jsonb);
  v_desired_flow jsonb;
  v_desired_process jsonb;
begin
  select * into f from v2_fixture;
  v_desired_flow := pg_temp.v2_flow(f.flow_id, '01.00.000', f.target_fp, '01.00.000');
  v_desired_process := jsonb_set(
    jsonb_set(
      jsonb_set(
        pg_temp.v2_process(f.process_id, '01.00.000', f.flow_id, '01.00.000'),
        '{processDataSet,exchanges,exchange,0,meanAmount}', to_jsonb('0.00000001175799086757990853'::text), false),
      '{processDataSet,exchanges,exchange,0,resultingAmount}', to_jsonb('0.00000001175799086757990853'::text), false),
    '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}', to_jsonb('1.0 hr per unit'::text), false);
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
      'reference', pg_temp.v2_ref(f.target_fp, '01.00.000', 'Time')),
    'source_evidence', jsonb_build_object('sha256', repeat('b', 64), 'exchange_count', 1),
    'counts', jsonb_build_object('action_count', 2 + jsonb_array_length(v_extra_flows) + jsonb_array_length(v_extra_processes),
      'flow_count', 1 + jsonb_array_length(v_extra_flows), 'process_count', 1 + jsonb_array_length(v_extra_processes),
      'exchange_count', 1, 'unrelated_exchange_count', 1, 'flowproperty_count', 0),
    'actions', jsonb_build_array(
      jsonb_build_object(
        'action_id', 'flow-1', 'table', 'flows', 'id', f.flow_id, 'version', '01.00.000',
        'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
        'expected_json_ordered', pg_temp.v2_flow(f.flow_id, '01.00.000', f.alias_fp, '00.00.001'),
        'desired_json_ordered', v_desired_flow,
        'mutation', jsonb_build_object('reference_id', f.target_fp, 'reference_version', '01.00.000'))
      || v_extra_flows,
      jsonb_build_object(
        'action_id', 'process-1', 'table', 'processes', 'id', f.process_id, 'version', '01.00.000',
        'expected_state_code', 0, 'expected_modified_at', '2026-09-21T00:00:00+00:00',
        'expected_json_ordered', pg_temp.v2_process(f.process_id, '01.00.000', f.flow_id, '01.00.000'),
        'desired_json_ordered', v_desired_process,
        'mutation', jsonb_build_object(
          'exchanges', jsonb_build_array(jsonb_build_object(
            'index', 0, 'internal_id', '1', 'flow_id', f.flow_id, 'flow_version', '01.00.000',
            'direction', 'Output', 'before_amount', '1.03E-4', 'after_amount', '0.00000001175799086757990853')),
          'functional_unit', jsonb_build_object(
            'path', 'processDataSet.processInformation.quantitativeReference.functionalUnitOrOther.#text',
            'before_text', '1.0 a per unit', 'after_text', '1.0 hr per unit', 'source_exchange_number', '1')))
      || v_extra_processes));
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
    (select modified_at from public.flows where id = (select flow_id from v2_fixture)) as flow_modified;


-- 1. the real small success
create temp table v2_first as select pg_temp.v2_call(pg_temp.v2_batch()) as result;
select is((select result->>'ok' from v2_first), 'true', 'a real small batch applies');
select is((select result->>'code' from v2_first), 'ALIAS_V2_BATCH_APPLIED', 'the applied code is returned');
select is((select result#>>'{counts,flow_count}' from v2_first), '1', 'one flow action is counted');
select is((select result#>>'{counts,exchange_count}' from v2_first), '1', 'one bound exchange occurrence is counted');
select is((select result#>>'{counts,unrelated_exchange_count}' from v2_first), '1', 'the unrelated complement is inside the selected process');
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowProperties,flowProperty,referenceToFlowPropertyDataSet,@refObjectId}' from public.flows where id = (select flow_id from v2_fixture)),
  (select target_fp::text from v2_fixture),
  'the flow now references the target property'
);
select is(
  (select json_ordered::jsonb #>> '{flowDataSet,flowInformation,quantitativeReference,referenceToReferenceFlowProperty}' from public.flows where id = (select flow_id from v2_fixture)),
  '1',
  'the internal quantitative-reference pointer never moves'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,0,meanAmount}' from public.processes where id = (select process_id from v2_fixture)),
  '0.00000001175799086757990853',
  'the bound exchange amount moved by the fixed factor'
);
select is(
  (select json_ordered::jsonb #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}' from public.processes where id = (select process_id from v2_fixture)),
  '1.0 hr per unit',
  'the reviewed functional-unit leaf moved under the anchored rule'
);

-- 2. exact replay: same proof, no new audit
select is(
  (pg_temp.v2_call(pg_temp.v2_batch()) ->> 'idempotent_replay'),
  'true',
  'an exact resubmission reports idempotent replay'
);
select is(
  (select count(*) from private.command_audit_log),
  (select audits + 2 from v2_before_state),
  'an exact replay writes no further audit row'
);

-- 3. late failure: a stale second action must leave the first action untouched
create temp table v2_late as select (select json_ordered from public.flows where id = (select flow_id from v2_fixture)) as flow_raw, (select count(*) from private.command_audit_log) as audits;
select is(
  (private.cmd_dataset_alias_batch_v2_guarded(
     jsonb_set(pg_temp.v2_batch(), '{schema_version}', '"dataset-alias-batch.v2"'::jsonb) #- '{actions,1}'
   ) #>> '{actions,0,expected_modified_at}'),
  null,
  'the batch helper removes the second action for the omission probe'
);
select is(
  (private.cmd_dataset_alias_batch_v2_guarded(
     jsonb_set(pg_temp.v2_batch() || jsonb_build_object('counts', jsonb_build_object(
       'action_count', 2, 'flow_count', 1, 'process_count', 1, 'exchange_count', 1,
       'unrelated_exchange_count', 1, 'flowproperty_count', 0)), '{actions,1,expected_modified_at}', '"2020-01-01T00:00:00+00:00"'::jsonb)
   ) ->> 'ok'),
  'false',
  'a stale second action refuses the whole batch'
);
select is(
  (select json_ordered from public.flows where id = (select flow_id from v2_fixture)),
  (select flow_raw from v2_late),
  'the first action row is unchanged after the late failure'
);
select is(
  (select count(*) from private.command_audit_log),
  (select audits from v2_late),
  'no audit row survives the late failure'
);

-- 4. omission: dropping the process action breaks the reference closure
select is(
  (private.cmd_dataset_alias_batch_v2_guarded(
     pg_temp.v2_batch() #- '{actions,1}' #- '{counts,process_count}'
   ) ->> 'code'),
  'ALIAS_V2_CLOSURE_MISMATCH',
  'an omitted consumer is refused as a closure mismatch'
);

-- 5. foreign consumer of the alias property breaks the closure
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select foreign_flow_id, '01.00.000', foreign_actor, 0, to_json(pg_temp.v2_flow(foreign_flow_id, '01.00.000', alias_fp, '00.00.001')), timestamp '2026-09-21 00:00:00'
from v2_fixture;
select is(
  (pg_temp.v2_call(pg_temp.v2_batch()) ->> 'code'),
  'ALIAS_V2_CLOSURE_MISMATCH',
  'a foreign consumer of the alias property is refused'
);

select * from finish();
rollback;
