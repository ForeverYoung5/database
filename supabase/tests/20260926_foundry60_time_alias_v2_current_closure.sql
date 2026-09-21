-- Foundry #60 / Database #680 — the Time-v2 fresh closure must prove the CURRENT support and the
-- exact global occurrence closure, not just that the claimed rows still hold their desired payloads.
--
-- The fixture is the reviewed Time wire's own shape with synthetic content: a source alias flow
-- property, a canonical target flow property, both unit groups, the converted flows and the one
-- owner-draft process that consumes them, plus one unrelated canonical flow that is outside the plan.
-- Every drift case runs rollback-only on this transaction: a support or consumer change after the run
-- must make `live_closure_proof` false while the claimed rows themselves still match, and any plan or
-- live shape problem must fail closed rather than raise.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, util;

select plan(29);

-- ------------------------------------------------------------------------------------------------
-- Fixture: support rows (both unit groups, both flow properties), the converted flows, the consuming
-- process and one unrelated canonical flow. Synthetic identifiers; the shapes mirror the reviewed wire.
-- ------------------------------------------------------------------------------------------------
delete from vault.secrets where name in ('project_secret_key', 'project_url');
select vault.create_secret('fixture-service-secret', 'project_secret_key', 'closure fixture key');
select vault.create_secret('https://closure-synthetic.invalid', 'project_url', 'closure fixture url');

delete from public.processes where id::text like 'aa000000-0000-4000-8000-%';
delete from public.flows where id::text like 'aa000000-0000-4000-8000-%';
delete from public.flowproperties where id::text like 'aa000000-0000-4000-8000-%';
delete from public.unitgroups where id::text like 'aa000000-0000-4000-8000-%';

create or replace function pg_temp.seal_plan(p_plan jsonb) returns jsonb language sql immutable as $$
  select p_plan || jsonb_build_object('plan_sha256', util.dataset_alias_execution_v2_artifact_sha256(p_plan))
$$;

create or replace function pg_temp.reseal_live_plan() returns jsonb language plpgsql stable as $$
declare
  v_plan jsonb;
begin
  -- Rebuild the plan document from the current live rows so every declared digest is self-hashed, then
  -- re-seal it. Only the pointer comparison under test can refuse the rebuilt document.
  select pg_temp.seal_plan(jsonb_build_object(
    'schema_version', 'dataset-alias-plan.v2',
    'actor_id', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    'target_visibility', 'owner_draft',
    'source_alias', jsonb_build_object(
      'id', 'aa000000-0000-4000-8000-000000000012', 'version', '00.00.001',
      'sha256', private.dataset_alias_v2_payload_sha256(
        jsonb_build_object('id', 'aa000000-0000-4000-8000-000000000012', 'version', '00.00.001'))),
    'source_evidence', jsonb_build_object(
      'sha256', repeat('b', 64), 'cohort_sha256', repeat('c', 64),
      'expected_cohort_sha256', repeat('c', 64), 'exchange_count', 2, 'original_source_unit', 'hr',
      'declared_source_unitgroup', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000002', 'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select source_ug from closure_support))),
      'source_flowproperty', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000012', 'version', '00.00.001',
        'sha256', private.dataset_alias_v2_payload_sha256((select alias_fp from closure_support)))),
    'target_snapshots', jsonb_build_object(
      'flowproperty', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000011', 'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select json_ordered::jsonb from public.flowproperties where id = 'aa000000-0000-4000-8000-000000000011'))),
      'unitgroup', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000001', 'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select target_ug from closure_support)))),
    'dimensions', jsonb_build_array(jsonb_build_object(
      'dimension', 'time', 'factor', private.dataset_alias_v2_factor()::text,
      'declared_source_unitgroup', jsonb_build_object('id', 'aa000000-0000-4000-8000-000000000002', 'version', '01.00.000'),
      'target_unitgroup', jsonb_build_object('id', 'aa000000-0000-4000-8000-000000000001', 'version', '01.00.000'))),
    'text_actions', jsonb_build_array(),
    'expected', jsonb_build_object(
      'action_count', 3, 'batch_count', 1, 'exchange_count', 2, 'amount_field_count', 4,
      'unrelated_exchange_count', 0, 'audit_count', 5, 'flowproperty_count', 0, 'flow_count', 2,
      'process_count', 1, 'derivative_target_count', 3, 'text_action_count', 0),
    'actions', jsonb_build_array(
      jsonb_build_object('action_id', '1', 'table', 'flows',
        'id', 'aa000000-0000-4000-8000-000000000021', 'version', '00.00.001',
        'desired_json_ordered', (select flow21 from closure_support)),
      jsonb_build_object('action_id', '2', 'table', 'flows',
        'id', 'aa000000-0000-4000-8000-000000000022', 'version', '00.00.001',
        'desired_json_ordered', (select flow22 from closure_support)),
      jsonb_build_object('action_id', '3', 'table', 'processes',
        'id', 'aa000000-0000-4000-8000-000000000031', 'version', '00.00.001',
        'desired_json_ordered', (select process31 from closure_support),
        'mutation', jsonb_build_object('exchanges', jsonb_build_array(
          jsonb_build_object('index', 0, 'internal_id', '1', 'direction', 'Output', 'flow_id', 'aa000000-0000-4000-8000-000000000021', 'flow_version', '00.00.001'),
          jsonb_build_object('index', 1, 'internal_id', '2', 'direction', 'Input', 'flow_id', 'aa000000-0000-4000-8000-000000000022', 'flow_version', '00.00.001'))))))
  ) into v_plan;
  return v_plan;
end $$;


insert into public.unitgroups (id, version, user_id, state_code, json_ordered, modified_at) values
('aa000000-0000-4000-8000-000000000001', '01.00.000', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
 to_json($ug${"unitGroupDataSet":{"unitGroupInformation":{"quantitativeReference":{"referenceToReferenceUnit":"1"}},"units":{"unit":[{"@dataSetInternalID":"1","name":"a","meanValue":"1"},{"@dataSetInternalID":"2","name":"hr","meanValue":"0.00011415525114155251"}]},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}$ug$::jsonb),
 timestamptz '2026-09-22 00:00:00+00'),
('aa000000-0000-4000-8000-000000000002', '01.00.000', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
 to_json($ug2${"unitGroupDataSet":{"unitGroupInformation":{"quantitativeReference":{"referenceToReferenceUnit":"1"}},"units":{"unit":[{"@dataSetInternalID":"1","name":"a","meanValue":"1"},{"@dataSetInternalID":"2","name":"hr","meanValue":"0.00011415525114155251"}]},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}$ug2$::jsonb),
 timestamptz '2026-09-22 00:00:00+00');

insert into public.flowproperties (id, version, user_id, state_code, json_ordered, modified_at) values
('aa000000-0000-4000-8000-000000000011', '01.00.000', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
 to_json($tfp${"flowPropertyDataSet":{"flowPropertiesInformation":{"dataSetInformation":{"common:name":{"#text":"Time","@xml:lang":"en"}},"quantitativeReference":{"referenceToReferenceUnitGroup":{"@type":"unit group data set","@refObjectId":"aa000000-0000-4000-8000-000000000001","@version":"01.00.000"}}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}$tfp$::jsonb),
 timestamptz '2026-09-22 00:00:00+00'),
('aa000000-0000-4000-8000-000000000012', '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
 to_json($afp${"flowPropertyDataSet":{"flowPropertiesInformation":{"dataSetInformation":{"common:name":{"#text":"Amount in hr","@xml:lang":"en"}},"quantitativeReference":{"referenceToReferenceUnitGroup":{"@type":"unit group data set","@refObjectId":"aa000000-0000-4000-8000-000000000002","@version":"01.00.000"}}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"00.00.001"}}}}$afp$::jsonb),
 timestamptz '2026-09-22 00:00:00+00');

-- The two converted (claimed) flows, one unrelated canonical flow, and the consuming process.
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select ('aa000000-0000-4000-8000-00000000002' || i::text)::uuid, '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
  jsonb_build_object('flowDataSet', jsonb_build_object(
    'flowInformation', jsonb_build_object(
      'dataSetInformation', jsonb_build_object('common:UUID', 'aa000000-0000-4000-8000-00000000002' || i::text),
      'quantitativeReference', jsonb_build_object('referenceToReferenceFlowProperty', '1')),
    'flowProperties', jsonb_build_object('flowProperty', jsonb_build_array(jsonb_build_object(
      '@dataSetInternalID', '1', 'meanValue', '1',
      'referenceToFlowPropertyDataSet', jsonb_build_object(
        '@type', 'flow property data set', '@refObjectId', 'aa000000-0000-4000-8000-000000000011',
        '@version', '01.00.000', '@uri', '../flowproperties/aa000000-0000-4000-8000-000000000011.json',
        'common:shortDescription', jsonb_build_object('#text', 'Time', '@xml:lang', 'en'))))),
    'modellingAndValidation', jsonb_build_object('LCIMethod', jsonb_build_object('typeOfDataSet', 'Product flow')),
    'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:dataSetVersion', '00.00.001')))),
  timestamptz '2026-09-22 00:00:00+00'
from generate_series(1, 3) as g(i);

insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at) values
('aa000000-0000-4000-8000-000000000031', '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
 to_json($pp${"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"aa000000-0000-4000-8000-000000000031"},"quantitativeReference":{"functionalUnitOrOther":{"@xml:lang":"en","#text":"1 hr"}}},"exchanges":{"exchange":[{"@dataSetInternalID":"1","exchangeDirection":"Output","meanAmount":"14","resultingAmount":"14","referenceToFlowDataSet":{"@refObjectId":"aa000000-0000-4000-8000-000000000021","@version":"00.00.001"}},{"@dataSetInternalID":"2","exchangeDirection":"Input","meanAmount":"8","resultingAmount":"8","referenceToFlowDataSet":{"@refObjectId":"aa000000-0000-4000-8000-000000000022","@version":"00.00.001"}}]},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"00.00.001"}}}}$pp$::jsonb),
 timestamptz '2026-09-22 00:00:00+00');

-- ------------------------------------------------------------------------------------------------
-- The plan document: the frozen support bindings and the exact claimed action/occurrence sets. Only
-- the blocks the closure reads are populated, with digests computed by the reviewed helpers.
-- ------------------------------------------------------------------------------------------------
create temp table closure_support on commit drop as
select
  (select json_ordered::jsonb from public.flowproperties where id = 'aa000000-0000-4000-8000-000000000011') as target_fp,
  (select json_ordered::jsonb from public.flowproperties where id = 'aa000000-0000-4000-8000-000000000012') as alias_fp,
  (select json_ordered::jsonb from public.unitgroups where id = 'aa000000-0000-4000-8000-000000000001') as target_ug,
  (select json_ordered::jsonb from public.unitgroups where id = 'aa000000-0000-4000-8000-000000000002') as source_ug,
  (select json_ordered::jsonb from public.flows where id = 'aa000000-0000-4000-8000-000000000021') as flow21,
  (select json_ordered::jsonb from public.flows where id = 'aa000000-0000-4000-8000-000000000022') as flow22,
  (select json_ordered::jsonb from public.processes where id = 'aa000000-0000-4000-8000-000000000031') as process31;

create temp table closure_plan on commit drop as
select pg_temp.seal_plan(
jsonb_build_object(
    'schema_version', 'dataset-alias-plan.v2',
    'actor_id', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    'target_visibility', 'owner_draft',
    'source_alias', jsonb_build_object(
      'id', 'aa000000-0000-4000-8000-000000000012',
      'version', '00.00.001',
      'sha256', private.dataset_alias_v2_payload_sha256(jsonb_build_object('id', 'aa000000-0000-4000-8000-000000000012', 'version', '00.00.001'))
    ),
    'source_evidence', jsonb_build_object(
      'sha256', repeat('b', 64),
      'cohort_sha256', repeat('c', 64),
      'expected_cohort_sha256', repeat('c', 64),
      'exchange_count', 2,
      'original_source_unit', 'hr',
      'declared_source_unitgroup', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000002',
        'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select source_ug from closure_support))
      ),
      'source_flowproperty', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000012',
        'version', '00.00.001',
        'sha256', private.dataset_alias_v2_payload_sha256((select alias_fp from closure_support))
      )
    ),
    'target_snapshots', jsonb_build_object(
      'flowproperty', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000011',
        'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select target_fp from closure_support))
      ),
      'unitgroup', jsonb_build_object(
        'id', 'aa000000-0000-4000-8000-000000000001',
        'version', '01.00.000',
        'sha256', private.dataset_alias_v2_payload_sha256((select target_ug from closure_support))
      )
    ),
    'dimensions', jsonb_build_array(
      jsonb_build_object(
        'dimension', 'time',
        'factor', private.dataset_alias_v2_factor()::text,
        'declared_source_unitgroup', jsonb_build_object(
          'id', 'aa000000-0000-4000-8000-000000000002',
          'version', '01.00.000'
        ),
        'target_unitgroup', jsonb_build_object(
          'id', 'aa000000-0000-4000-8000-000000000001',
          'version', '01.00.000'
        )
      )
    ),
    'text_actions', jsonb_build_array(),
    'expected', jsonb_build_object(
      'action_count', 3,
      'batch_count', 1,
      'exchange_count', 2,
      'amount_field_count', 4,
      'unrelated_exchange_count', 0,
      'audit_count', 5,
      'flowproperty_count', 0,
      'flow_count', 2,
      'process_count', 1,
      'derivative_target_count', 3,
      'text_action_count', 0
    ),
    'actions', jsonb_build_array(
      jsonb_build_object(
        'action_id', '1',
        'table', 'flows',
        'id', 'aa000000-0000-4000-8000-000000000021',
        'version', '00.00.001',
        'desired_json_ordered', (select flow21 from closure_support)
      ),
      jsonb_build_object(
        'action_id', '2',
        'table', 'flows',
        'id', 'aa000000-0000-4000-8000-000000000022',
        'version', '00.00.001',
        'desired_json_ordered', (select flow22 from closure_support)
      ),
      jsonb_build_object(
        'action_id', '3',
        'table', 'processes',
        'id', 'aa000000-0000-4000-8000-000000000031',
        'version', '00.00.001',
        'desired_json_ordered', (select process31 from closure_support),
        'mutation', jsonb_build_object(
          'exchanges', jsonb_build_array(
            jsonb_build_object(
              'index', 0,
              'internal_id', '1',
              'direction', 'Output',
              'flow_id', 'aa000000-0000-4000-8000-000000000021',
              'flow_version', '00.00.001'
            ),
            jsonb_build_object(
              'index', 1,
              'internal_id', '2',
              'direction', 'Input',
              'flow_id', 'aa000000-0000-4000-8000-000000000022',
              'flow_version', '00.00.001'
            )
          )
        )
      )
    )
  )
) as p;

-- ------------------------------------------------------------------------------------------------
-- 1. The unchanged current snapshot is a genuine pass, and the closure ignores unrelated canonical
--    consumers (the third flow already carries the target property and is outside the plan).
-- ------------------------------------------------------------------------------------------------
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'ok'), 'true',
  'current closure: the unchanged bound support and claimed sets pass');
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'current closure: live_closure_proof is true for the exact applied state');
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'row_count'), '3',
  'current closure: the three claimed rows are observed at their desired images');
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'exchange_count'), '2',
  'current closure: the claimed exchange count is echoed unchanged');
select is(
  (select string_agg(key, ',' order by key)
     from jsonb_object_keys(util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))) as key),
  'claimed_row_count,exchange_count,invalid_action_count,live_closure_proof,ok,proof_sha256,row_count',
  'current closure: the returned receipt key set is unchanged');

-- ------------------------------------------------------------------------------------------------
-- 2. Support drift after the run: the canonical target and the operational source bindings are
--    re-verified on every read. Every case keeps the claimed rows at their desired images, so only
--    the support verification can (and must) turn the closure false.
-- ------------------------------------------------------------------------------------------------
-- The plan's own source-alias identity digest must be the canonical digest of the identity it names.
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    (select p from closure_plan) || jsonb_build_object('source_alias',
      (select p->'source_alias' from closure_plan) || jsonb_build_object('sha256', repeat('d', 64))))->>'live_closure_proof'), 'false',
  'support: a source-alias identity digest that is not the canonical identity digest refuses');

-- The canonical target unit group factor changes after the run (the reproduced root defect).
update public.unitgroups set json_ordered = jsonb_set(json_ordered::jsonb, '{unitGroupDataSet,units,unit,1,meanValue}', to_jsonb('0.0002'::text), false)::json
where id = 'aa000000-0000-4000-8000-000000000001';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'false',
  'support: a changed canonical target unit-group factor turns the current closure false');
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'row_count'), '3',
  'support: the false closure is not a claimed-row count (the rows are still at their desired images)');
update public.unitgroups set json_ordered = jsonb_set(json_ordered::jsonb, '{unitGroupDataSet,units,unit,1,meanValue}', to_jsonb('0.00011415525114155251'::text), false)::json
where id = 'aa000000-0000-4000-8000-000000000001';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'support: restoring the exact snapshot restores the pass');

-- The canonical target flow property payload changes after the run.
update public.flowproperties set json_ordered = jsonb_set(json_ordered::jsonb, '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name,#text}', to_jsonb('TimeX'::text))::json
where id = 'aa000000-0000-4000-8000-000000000011';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'false',
  'support: a changed canonical target flow-property payload turns the current closure false');
update public.flowproperties set json_ordered = jsonb_set(json_ordered::jsonb, '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name,#text}', to_jsonb('Time'::text))::json
where id = 'aa000000-0000-4000-8000-000000000011';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'support: restoring the canonical property restores the pass');

-- The operational source alias flow property changes after the run.
update public.flowproperties set json_ordered = jsonb_set(json_ordered::jsonb, '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name,#text}', to_jsonb('Amount in hr (moved)'::text))::json
where id = 'aa000000-0000-4000-8000-000000000012';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'false',
  'support: a changed source-alias flow-property payload turns the current closure false');
update public.flowproperties set json_ordered = jsonb_set(json_ordered::jsonb, '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name,#text}', to_jsonb('Amount in hr'::text))::json
where id = 'aa000000-0000-4000-8000-000000000012';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'support: restoring the source alias restores the pass');

-- The source alias no longer points at the declared source unit group.
update public.flowproperties set json_ordered = jsonb_set(json_ordered::jsonb, '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}', to_jsonb('99.99.999'::text))::json
where id = 'aa000000-0000-4000-8000-000000000012';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'false',
  'support: a source alias pointing at another unit-group version turns the current closure false');
update public.flowproperties set json_ordered = jsonb_set(json_ordered::jsonb, '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}', to_jsonb('01.00.000'::text))::json
where id = 'aa000000-0000-4000-8000-000000000012';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'support: restoring the alias pointer restores the pass');

-- The declared source unit group payload changes after the run.
update public.unitgroups set json_ordered = jsonb_set(json_ordered::jsonb, '{unitGroupDataSet,units,unit,1,meanValue}', to_jsonb('0.0003'::text), false)::json
where id = 'aa000000-0000-4000-8000-000000000002';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'false',
  'support: a changed declared source unit-group payload turns the current closure false');
update public.unitgroups set json_ordered = jsonb_set(json_ordered::jsonb, '{unitGroupDataSet,units,unit,1,meanValue}', to_jsonb('0.00011415525114155251'::text), false)::json
where id = 'aa000000-0000-4000-8000-000000000002';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'support: restoring the declared source unit group restores the pass');

-- ------------------------------------------------------------------------------------------------
-- 3. Consumer drift: a remaining/new source-alias flow outside the plan and a foreign consumer of a
--    changed flow each refuse, and the diagnostics never carry a foreign payload.
-- ------------------------------------------------------------------------------------------------
insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at) values
('aa000000-0000-4000-8000-000000000029', '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
jsonb_build_object(
    'flowDataSet', jsonb_build_object(
      'flowInformation', jsonb_build_object(
        'dataSetInformation', jsonb_build_object(
          'common:UUID', 'aa000000-0000-4000-8000-000000000029'
        )
      ),
      'flowProperties', jsonb_build_object(
        'flowProperty', jsonb_build_array(
          jsonb_build_object(
            '@dataSetInternalID', '1',
            'meanValue', '1',
            'referenceToFlowPropertyDataSet', jsonb_build_object(
              '@refObjectId', 'aa000000-0000-4000-8000-000000000012',
              '@version', '00.00.001'
            )
          )
        )
      ),
      'administrativeInformation', jsonb_build_object(
        'publicationAndOwnership', jsonb_build_object(
          'common:dataSetVersion', '00.00.001'
        )
      )
    )
  ),
 timestamptz '2026-09-22 00:00:00+00');
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'false',
  'consumers: a remaining source-alias flow outside the completed plan turns the current closure false');
delete from public.flows where id = 'aa000000-0000-4000-8000-000000000029';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'consumers: removing the extra source-alias flow restores the pass');

insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at) values
('aa000000-0000-4000-8000-000000000039', '00.00.001', '11111111-1111-4111-8111-111111111111', 0,
 to_json($fp${"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"aa000000-0000-4000-8000-000000000039","common:other":"FOREIGN-CONSUMER-MARKER"}},"exchanges":{"exchange":[{"@dataSetInternalID":"9","exchangeDirection":"Input","meanAmount":"1","resultingAmount":"1","referenceToFlowDataSet":{"@refObjectId":"aa000000-0000-4000-8000-000000000021","@version":"00.00.001"}}]},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"00.00.001"}}}}$fp$::jsonb),
 timestamptz '2026-09-22 00:00:00+00');

select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'false',
  'consumers: a foreign live occurrence of a changed flow turns the current closure false');
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))::text like '%FOREIGN-CONSUMER-MARKER%'), false,
  'consumers: the closure diagnostics never carry a foreign row payload');
select is(
  (select string_agg(key, ',' order by key)
     from jsonb_object_keys(util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))) as key),
  'claimed_row_count,exchange_count,invalid_action_count,live_closure_proof,ok,proof_sha256,row_count',
  'consumers: the drifted receipt keeps the same key set');
delete from public.processes where id = 'aa000000-0000-4000-8000-000000000039';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from closure_plan))->>'live_closure_proof'), 'true',
  'consumers: removing the foreign consumer restores the pass');

-- A claimed occurrence that is no longer part of the frozen claim set (the plan is the authority).
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    jsonb_set((select p from closure_plan), '{actions,2,mutation,exchanges}',
      ((select p from closure_plan) #> '{actions,2,mutation,exchanges}') - 0))->>'live_closure_proof'), 'false',
  'consumers: a claimed-occurrence set that no longer covers the live occurrences refuses');

-- A shape that cannot be verified fails closed instead of raising.
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    (select p from closure_plan) - 'source_evidence')->>'live_closure_proof'), 'false',
  'shape: a plan without its source evidence fails closed');

-- ------------------------------------------------------------------------------------------------
-- 4. The target flow property's unit-group reference identity is part of the exact bound support: the
--    pointer must name the declared unit group by id, exact version and kind, and the plan is rebuilt
--    from the live rows so every digest is self-hashed and only the pointer can refuse.
-- ------------------------------------------------------------------------------------------------
create temp table closure_target_fp on commit drop as
  select json_ordered::jsonb as payload
  from public.flowproperties
  where id = 'aa000000-0000-4000-8000-000000000011';

update public.flowproperties
set json_ordered = jsonb_set(
      json_ordered::jsonb,
      '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@version}',
      to_jsonb('99.99.999'::text))::json
where id = 'aa000000-0000-4000-8000-000000000011';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    pg_temp.reseal_live_plan())->>'live_closure_proof'), 'false',
  'target identity: a canonical property pointing at another unit-group version turns the current closure false');
update public.flowproperties
set json_ordered = (select payload from closure_target_fp)::json
where id = 'aa000000-0000-4000-8000-000000000011';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    pg_temp.reseal_live_plan())->>'live_closure_proof'), 'true',
  'target identity: restoring the exact pointer restores the pass');

update public.flowproperties
set json_ordered = jsonb_set(
      json_ordered::jsonb,
      '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup,@type}',
      to_jsonb('flow property data set'::text))::json
where id = 'aa000000-0000-4000-8000-000000000011';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    pg_temp.reseal_live_plan())->>'live_closure_proof'), 'false',
  'target identity: a canonical property whose reference kind is not a unit group data set turns the current closure false');
update public.flowproperties
set json_ordered = (select payload from closure_target_fp)::json
where id = 'aa000000-0000-4000-8000-000000000011';

-- An absent kind is the canonical default of the deployed shape and keeps passing.
update public.flowproperties
set json_ordered = jsonb_set(
      json_ordered::jsonb,
      '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup}',
      (json_ordered::jsonb #> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup}') - '@type')::json
where id = 'aa000000-0000-4000-8000-000000000011';
select is((select util.read_dataset_alias_execution_v2_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    pg_temp.reseal_live_plan())->>'live_closure_proof'), 'true',
  'target identity: an absent reference kind is the canonical unit-group default and still passes');
update public.flowproperties
set json_ordered = (select payload from closure_target_fp)::json
where id = 'aa000000-0000-4000-8000-000000000011';

select * from finish();
rollback;
