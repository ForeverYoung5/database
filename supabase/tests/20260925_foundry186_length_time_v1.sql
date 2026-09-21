-- Foundry #186 / Database #674: the closed Length*time kmy->m*a profile.
--
-- Synthetic real-shaped cohort: 13 owner-draft processes, each with three selected kmy exchanges on
-- the canonical Length*time property (39 instances) plus two unrelated exchanges on another flow
-- (26 unrelated occurrences inside the selected processes -> 78 amount leaves written). The canonical
-- unit group declares m*a at factor 1 and kmy at factor 1000; every selected exchange carries the
-- reviewed key set with a relative-uncertainty field and no absolute-uncertainty field.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, private, util;

select plan(53);

-- ------------------------------------------------------------------------------------------------
-- Fixture: canonical unit group, property, 13 claimed flows, 1 unrelated flow, 13 processes.
-- ------------------------------------------------------------------------------------------------
create temp table ids on commit drop as
select ('b20c0de0-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid as process_id,
       ('f10c0de0-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid as flow_id,
       (array['0.014','0.0198','0.0549','0.0772','0.274','0.385','1','2','0.5','0.75','1.25','2.5','4'])[i] as literal,
       i
from generate_series(1, 13) as g(i);

delete from public.processes where id::text like 'b20c0de0-%';
delete from public.flows where id::text like 'f10c0de0-%';
delete from public.flowproperties where id in
  ('fd9d0d42-3655-5f1d-aa2f-e9ae1134fc82'::uuid, 'ad000000-0000-4000-8000-000000000001'::uuid);
delete from public.unitgroups where id = '8a1e27de-c1e7-5049-94bd-6c7ba80f52d1'::uuid;

-- The row triggers the deployed schema installs need branch-local Vault values. This suite is
-- rollback-only, so no queue row can ever reach pg_net; the URL is a synthetic host, never the real
-- project, so even a mistaken commit cannot dispatch anywhere real.
delete from vault.secrets where name in ('project_secret_key', 'project_url');
select vault.create_secret('fixture-service-secret', 'project_secret_key', 'conformance fixture key');
select vault.create_secret('https://length-time-synthetic.invalid', 'project_url', 'conformance fixture url');

insert into public.unitgroups (id, version, user_id, state_code, json_ordered, modified_at) values
('8a1e27de-c1e7-5049-94bd-6c7ba80f52d1', '01.00.000', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0, to_json($ug${"unitGroupDataSet":{"unitGroupInformation":{"quantitativeReference":{"referenceToReferenceUnit":"1"}},"units":{"unit":[{"@dataSetInternalID":"1","name":"m*a","meanValue":"1"},{"@dataSetInternalID":"2","name":"kmy","meanValue":"1000"}]},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}$ug$::jsonb), timestamptz '2026-09-22 00:00:00+00');

insert into public.flowproperties (id, version, user_id, state_code, json_ordered, modified_at) values
('fd9d0d42-3655-5f1d-aa2f-e9ae1134fc82', '01.00.000', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0, to_json($fp${"flowPropertyDataSet":{"flowPropertiesInformation":{"dataSetInformation":{"common:name":{"#text":"Length*time","@xml:lang":"en"}},"quantitativeReference":{"referenceToReferenceUnitGroup":{"@type":"unit group data set","@refObjectId":"8a1e27de-c1e7-5049-94bd-6c7ba80f52d1","@version":"01.00.000"}}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}$fp$::jsonb), timestamptz '2026-09-22 00:00:00+00'),
('ad000000-0000-4000-8000-000000000001', '01.00.000', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0, to_json($fp2${"flowPropertyDataSet":{"flowPropertiesInformation":{"dataSetInformation":{"common:name":{"#text":"Amount","@xml:lang":"en"}},"quantitativeReference":{"referenceToReferenceUnitGroup":{"@type":"unit group data set","@refObjectId":"8a1e27de-c1e7-5049-94bd-6c7ba80f52d1","@version":"01.00.000"}}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}$fp2$::jsonb), timestamptz '2026-09-22 00:00:00+00');

insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at)
select flow_id, '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0,
  jsonb_build_object('flowDataSet', jsonb_build_object(
    'flowInformation', jsonb_build_object(
      'dataSetInformation', jsonb_build_object('common:UUID', flow_id::text),
      'quantitativeReference', jsonb_build_object('referenceToReferenceFlowProperty', '1')),
    'flowProperties', jsonb_build_object('flowProperty', jsonb_build_array(jsonb_build_object(
      '@dataSetInternalID', '1', 'meanValue', '1',
      'referenceToFlowPropertyDataSet', jsonb_build_object(
        '@type', 'flow property data set', '@refObjectId', 'fd9d0d42-3655-5f1d-aa2f-e9ae1134fc82',
        '@version', '01.00.000')))),
    'modellingAndValidation', jsonb_build_object('LCIMethod', jsonb_build_object('typeOfDataSet', 'Product flow')),
    'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:dataSetVersion', '00.00.001')))),
  timestamptz '2026-09-22 00:00:00+00'
from ids;

insert into public.flows (id, version, user_id, state_code, json_ordered, modified_at) values
('f10c0de0-0000-4000-8000-000000000999', '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0, to_json($uf${"flowDataSet":{"flowInformation":{"dataSetInformation":{"common:UUID":"f10c0de0-0000-4000-8000-000000000999"},"quantitativeReference":{"referenceToReferenceFlowProperty":"1"}},"flowProperties":{"flowProperty":[{"@dataSetInternalID":"1","meanValue":"1","referenceToFlowPropertyDataSet":{"@type":"flow property data set","@refObjectId":"ad000000-0000-4000-8000-000000000001","@version":"01.00.000"}}]},"modellingAndValidation":{"LCIMethod":{"typeOfDataSet":"Product flow"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"00.00.001"}}}}$uf$::jsonb), timestamptz '2026-09-22 00:00:00+00');

-- Each process: index 0..2 = selected kmy exchanges on the claimed flow (Output/Input/Input),
-- index 3..4 = unrelated exchanges on the unclaimed flow. The functional-unit text 1 kmy is untouched.
create temp table fixture_rows on commit drop as
select process_id, flow_id, literal, i,
  jsonb_build_object('processDataSet', jsonb_build_object(
    'processInformation', jsonb_build_object(
      'dataSetInformation', jsonb_build_object('common:UUID', process_id::text),
      'quantitativeReference', jsonb_build_object(
        'referenceToReferenceFlow', '1',
        'functionalUnitOrOther', jsonb_build_object('@xml:lang', 'en', '#text', '1 kmy'))),
    'exchanges', jsonb_build_object('exchange', jsonb_build_array(
      jsonb_build_object('@dataSetInternalID', '1', 'dataDerivationTypeStatus', 'Measured',
        'exchangeDirection', 'Output', 'generalComment', 'source 7300' || lpad(i::text, 3, '0'),
        'meanAmount', literal, 'resultingAmount', literal, 'relativeStandardDeviation95In', '0.05',
        'uncertaintyDistributionType', 'lognormal',
        'referenceToFlowDataSet', jsonb_build_object('@refObjectId', flow_id::text, '@version', '00.00.001')),
      jsonb_build_object('@dataSetInternalID', '2', 'dataDerivationTypeStatus', 'Measured',
        'exchangeDirection', 'Input', 'generalComment', 'source 7310' || lpad(i::text, 3, '0'),
        'meanAmount', literal, 'resultingAmount', literal, 'relativeStandardDeviation95In', '0.10',
        'uncertaintyDistributionType', 'lognormal',
        'referenceToFlowDataSet', jsonb_build_object('@refObjectId', flow_id::text, '@version', '00.00.001')),
      jsonb_build_object('@dataSetInternalID', '3', 'dataDerivationTypeStatus', 'Measured',
        'exchangeDirection', 'Input', 'generalComment', 'source 7320' || lpad(i::text, 3, '0'),
        'meanAmount', literal, 'resultingAmount', literal, 'relativeStandardDeviation95In', '0.20',
        'uncertaintyDistributionType', 'lognormal',
        'referenceToFlowDataSet', jsonb_build_object('@refObjectId', flow_id::text, '@version', '00.00.001')),
      jsonb_build_object('@dataSetInternalID', '4', 'dataDerivationTypeStatus', 'Measured',
        'exchangeDirection', 'Input', 'meanAmount', '7', 'resultingAmount', '7',
        'referenceToFlowDataSet', jsonb_build_object('@refObjectId', 'f10c0de0-0000-4000-8000-000000000999', '@version', '00.00.001')),
      jsonb_build_object('@dataSetInternalID', '5', 'dataDerivationTypeStatus', 'Measured',
        'exchangeDirection', 'Input', 'meanAmount', '9', 'resultingAmount', '9',
        'referenceToFlowDataSet', jsonb_build_object('@refObjectId', 'f10c0de0-0000-4000-8000-000000000999', '@version', '00.00.001')))),
    'administrativeInformation', jsonb_build_object('publicationAndOwnership', jsonb_build_object('common:dataSetVersion', '00.00.001')))) as payload
from ids;

insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at)
select process_id, '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0, payload::json, timestamptz '2026-09-22 00:00:00+00'
from fixture_rows;

-- ------------------------------------------------------------------------------------------------
-- Helpers: the plan builder, the sealer (recomputes claimed digests + plan self-hash) and the
-- fixture reset (puts every process back to its before image and clears this suite's ledger rows).
-- ------------------------------------------------------------------------------------------------
create or replace function pg_temp.build_plan(p_factor text default '1000', p_break_literal text default null)
returns jsonb language plpgsql as $$
declare
  v_actions jsonb := '[]'::jsonb;
  v_flows jsonb := '[]'::jsonb;
  v_row record;
  v_before jsonb;
  v_desired jsonb;
  v_instances jsonb;
  v_after text;
  v_lit text;
  v_action_id integer := 0;
  v_i integer;
begin
  for v_row in select * from fixture_rows order by i loop
    v_before := v_row.payload;
    v_desired := v_before;
    v_instances := '[]'::jsonb;
    for v_i in 0..2 loop
      v_lit := v_before #>> array['processDataSet','exchanges','exchange', v_i::text, 'meanAmount'];
      if v_i = 1 and p_break_literal is not null then
        v_lit := p_break_literal;
      end if;
      v_after := private.dataset_length_time_v1_multiply_amount(v_lit);
      v_instances := v_instances || jsonb_build_array(jsonb_build_object(
        'index', v_i, 'internal_id', (v_i + 1)::text,
        'source_exchange_number', (7300000 + v_i * 10000 + v_row.i)::text,
        'direction', case when v_i = 0 then 'Output' else 'Input' end,
        'flow_id', v_row.flow_id::text, 'flow_version', '00.00.001',
        'before_literal', v_lit, 'after_literal', v_after));
      v_desired := jsonb_set(v_desired, array['processDataSet','exchanges','exchange', v_i::text, 'meanAmount'], to_jsonb(v_after), false);
      v_desired := jsonb_set(v_desired, array['processDataSet','exchanges','exchange', v_i::text, 'resultingAmount'], to_jsonb(v_after), false);
    end loop;
    v_action_id := v_action_id + 1;
    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
      'action_id', v_action_id::text, 'table', 'processes',
      'id', v_row.process_id::text, 'version', '00.00.001',
      'expected_state_code', 0,
      'expected_modified_at', to_char((select live.modified_at from public.processes live where live.id = v_row.process_id) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'expected_json_ordered', v_before, 'desired_json_ordered', v_desired,
      'before_sha256', private.dataset_alias_v2_payload_sha256(v_before),
      'desired_sha256', private.dataset_alias_v2_payload_sha256(v_desired),
      'mutation', jsonb_build_object('factor', p_factor, 'exchanges', v_instances)));
    v_flows := v_flows || jsonb_build_array(jsonb_build_object(
      'id', v_row.flow_id::text, 'version', '00.00.001',
      'sha256', private.dataset_alias_v2_payload_sha256((select f.json_ordered::jsonb from public.flows f where f.id = v_row.flow_id))));
  end loop;
  return jsonb_build_object(
    'schema_version', 'dataset-length-time-plan.v1',
    'actor_id', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7',
    'target_visibility', 'owner_draft',
    'flow_snapshots', v_flows,
    'target_flow_property', jsonb_build_object('id', 'fd9d0d42-3655-5f1d-aa2f-e9ae1134fc82', 'version', '01.00.000',
      'sha256', private.dataset_alias_v2_payload_sha256((select json_ordered::jsonb from public.flowproperties where id = 'fd9d0d42-3655-5f1d-aa2f-e9ae1134fc82'))),
    'target_unit_group', jsonb_build_object('id', '8a1e27de-c1e7-5049-94bd-6c7ba80f52d1', 'version', '01.00.000',
      'sha256', private.dataset_alias_v2_payload_sha256((select json_ordered::jsonb from public.unitgroups where id = '8a1e27de-c1e7-5049-94bd-6c7ba80f52d1'))),
    'source_evidence', jsonb_build_object('sha256', repeat('a', 64), 'source_unit', 'kmy', 'reference_unit', 'm*a',
      'factor', p_factor, 'instance_count', 39),
    'expected', jsonb_build_object(
      'action_count', 13, 'batch_count', 1, 'exchange_count', 39, 'amount_field_count', 78,
      'unrelated_exchange_count', 26, 'audit_count', 15, 'flowproperty_count', 0, 'flow_count', 0,
      'process_count', 13, 'derivative_target_count', 13, 'text_action_count', 0),
    'actions', v_actions);
end $$;

create or replace function pg_temp.seal(p_plan jsonb)
returns jsonb language sql immutable as $$
  select (x.plan || jsonb_build_object('plan_sha256', util.dataset_alias_execution_v2_artifact_sha256(x.plan)))
  from (
    select jsonb_set(p_plan, '{actions}',
      coalesce((select jsonb_agg(a.value
          || jsonb_build_object('before_sha256', private.dataset_alias_v2_payload_sha256(a.value->'expected_json_ordered'))
          || jsonb_build_object('desired_sha256', private.dataset_alias_v2_payload_sha256(a.value->'desired_json_ordered')))
        from jsonb_array_elements(p_plan->'actions') as a(value)), '[]'::jsonb), false) as plan) x
$$;

create or replace function pg_temp.reset_fixture()
returns void language plpgsql as $$
begin
  update public.processes p set json_ordered = f.payload::json, modified_at = timestamptz '2026-09-22 00:00:00+00', state_code = 0, user_id = 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7'
  from fixture_rows f where p.id = f.process_id;
  delete from private.command_audit_log where command = 'cmd_dataset_length_time_v1_guarded';
end $$;

create or replace function pg_temp.refresh_plan()
returns void language plpgsql as $$
begin
  delete from plan_doc;
  insert into plan_doc select pg_temp.seal(pg_temp.build_plan());
end $$;

-- Auth as the fixture actor; the executor and closure readers resolve auth.uid() from the claims.
create or replace function pg_temp.as_actor() returns void language sql as $$
  select set_config('request.jwt.claim.role', 'authenticated', true)
      || set_config('request.jwt.claim.sub', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', true)
      || set_config('request.jwt.claim.email', 'fixture-owner@example.invalid', true)
$$;
select pg_temp.as_actor();

-- ------------------------------------------------------------------------------------------------
-- 1. The closed discriminator.
-- ------------------------------------------------------------------------------------------------
select is((select private.dataset_protected_profile(jsonb_build_object('schema_version', 'dataset-length-time-plan.v1'))), 'length_time_v1', 'profile: the length-time schema resolves to its closed profile');
select is((select private.dataset_protected_profile(jsonb_build_object('schema_version', 'dataset-alias-plan.v2'))), 'alias_v2', 'profile: the time schema still resolves to alias_v2');
select is((select private.dataset_protected_profile(jsonb_build_object('schema_version', 'dataset-anything-plan.v9'))), null, 'profile: an unknown schema resolves to null (closed)');
select is((select private.dataset_protected_profile('[]'::jsonb)), null, 'profile: a non-object plan resolves to null');
select is((select private.dataset_length_time_v1_factor()), 1000::numeric, 'math: the reviewed factor is exactly 1000');
select is((select private.dataset_length_time_v1_multiply_amount('0.0198')), '19.8', 'math: exact decimal multiplication renders canonically');
select is((select private.dataset_length_time_v1_multiply_amount('1e999')), null, 'math: an out-of-grammar literal yields null, never a guess');

-- ------------------------------------------------------------------------------------------------
-- 2. The positive run: 13 processes / 39 instances / 78 leaves applied, everything else invariant.
-- ------------------------------------------------------------------------------------------------
create temp table plan_doc on commit drop as select pg_temp.seal(pg_temp.build_plan()) as p;
create temp table run1 on commit drop as select private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)) as r;
select is((select r->>'ok' from run1), 'true', 'apply: the real-shaped cohort applies');
select is((select r->>'code' from run1), 'LENGTH_TIME_PLAN_APPLIED', 'apply: the applied code is the length-time one');
select is((select r->>'idempotent_replay' from run1), 'false', 'apply: a fresh run is not a replay');
select is((select r#>>'{counts,action_count}' from run1), '13', 'apply: 13 process actions');
select is((select r#>>'{counts,process_count}' from run1), '13', 'apply: 13 processes written');
select is((select r#>>'{counts,flow_count}' from run1), '0', 'apply: no flow action exists');
select is((select r#>>'{counts,exchange_count}' from run1), '39', 'apply: 39 exchange instances');
select is((select r#>>'{counts,amount_field_count}' from run1), '78', 'apply: 78 amount leaves');
select is((select r#>>'{counts,unrelated_exchange_count}' from run1), '26', 'apply: 26 unrelated occurrences inside the selected processes');
select is((select r->>'audit_count' from run1), '15', 'apply: the audit topology is 13 row + 1 batch + 1 plan');

select is((select count(*)::text from public.processes p join ids on ids.process_id = p.id
  where p.json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,0,meanAmount}' = private.dataset_length_time_v1_multiply_amount(ids.literal)), '13', 'apply: every process holds the exact x1000 literal on the output exchange');
select is((select count(*)::text from public.processes p join ids on ids.process_id = p.id
  where p.json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,1,resultingAmount}' = private.dataset_length_time_v1_multiply_amount(ids.literal)), '13', 'apply: the resulting amount moved with the mean amount');
select is((select count(distinct p.json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,3,meanAmount}')::text from public.processes p join ids on ids.process_id = p.id), '1', 'apply: unrelated exchanges are untouched');
select is((select count(*)::text from public.processes p join ids on ids.process_id = p.id
  where p.json_ordered::jsonb #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}' = '1 kmy'), '13', 'apply: the functional-unit text 1 kmy is byte-identical');
select is((select count(*)::text from public.flows f join ids on ids.flow_id = f.id
  where f.json_ordered::jsonb #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' = 'Product flow'), '13', 'apply: every claimed flow is still a Product flow (read-only)');
select is((select json_ordered::jsonb #>> '{unitGroupDataSet,units,unit,1,meanValue}' from public.unitgroups where id = '8a1e27de-c1e7-5049-94bd-6c7ba80f52d1'), '1000', 'apply: the canonical unit group is untouched');
select is((select count(*)::text from private.command_audit_log where command = 'cmd_dataset_length_time_v1_guarded' and payload->>'record_type' = 'row'), '13', 'ledger: one row audit per action');
select is((select count(*)::text from private.command_audit_log where command = 'cmd_dataset_length_time_v1_guarded' and payload->>'record_type' = 'plan'), '1', 'ledger: one batch summary');
select is((select count(*)::text from private.command_audit_log where command = 'cmd_dataset_length_time_v1_guarded' and payload->>'record_type' = 'plan_summary'), '1', 'ledger: one plan summary');

-- Fresh readback closure + the strict terminal proof over the committed ledger.
select is((select util.read_dataset_length_time_v1_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from plan_doc))->>'live_closure_proof'), 'true', 'closure: the fresh primary closure passes');
select is((select util.read_dataset_length_time_v1_primary_closure('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from plan_doc))->>'row_count'), '13', 'closure: 13 rows observed at their desired image');
select is((select util.read_dataset_length_time_v1_terminal_proof('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from plan_doc))->>'status'), 'applied', 'proof: the terminal proof reports applied');
select is((select util.read_dataset_length_time_v1_terminal_proof('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from plan_doc))#>>'{audit,row_audit_count}'), '13', 'proof: 13 row audits in the proof');
select is((select util.read_dataset_length_time_v1_terminal_proof('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from plan_doc))#>>'{readback,row_count}'), '13', 'proof: 13 fresh readback rows');
select is((select util.read_dataset_length_time_v1_terminal_proof('c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', (select p from plan_doc))#>>'{readback,rows,0,functional_unit_text}'), '1 kmy', 'proof: the functional-unit expectation is the before image (no text action)');

-- ------------------------------------------------------------------------------------------------
-- 3. Exact replay: 0 writes, no new successful audit, the prior summary returned.
-- ------------------------------------------------------------------------------------------------
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'idempotent_replay'), 'true', 'replay: an exact resubmission replays');
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'code'), 'LENGTH_TIME_PLAN_REPLAYED', 'replay: the replay code is the length-time one');
select is((select count(*)::text from private.command_audit_log where command = 'cmd_dataset_length_time_v1_guarded'), '15', 'replay: no new audit row is written');

-- ------------------------------------------------------------------------------------------------
-- 4. Refusals, each with 0 writes and 0 new audit rows (the fixture is reset to before images).
-- ------------------------------------------------------------------------------------------------
select pg_temp.reset_fixture();
select pg_temp.refresh_plan();

-- every row already at its desired image, but with no committed proof: the replay path must refuse
-- rather than mint a plan summary over unproven state.
update public.processes as target
set json_ordered = (a->'desired_json_ordered')::json
from jsonb_array_elements((select pd.p->'actions' from plan_doc pd)) as a
where target.id = (a->>'id')::uuid;
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'code'), 'LENGTH_TIME_REPLAY_UNPROVEN', 'refuse: a desired-state row without its audit proof');
select pg_temp.reset_fixture();
select pg_temp.refresh_plan();

-- wrong declared factor
select is((select (private.cmd_dataset_length_time_v1_guarded((select pg_temp.seal(pg_temp.build_plan('999')))))->>'code'), 'LENGTH_TIME_FACTOR_MISMATCH', 'refuse: a declared factor other than 1000');
select is((select (private.cmd_dataset_length_time_v1_guarded((select pg_temp.seal(pg_temp.build_plan('999')))))->>'status'), '409', 'refuse: the factor refusal is a 409');

-- before literal spelled differently but numerically equal
select is((select (private.cmd_dataset_length_time_v1_guarded((select pg_temp.seal(pg_temp.build_plan('1000', '0.0140')))))->>'code'), 'LENGTH_TIME_DERIVE_MISMATCH', 'refuse: a before literal that is numerically equal but not byte-equal');

-- an extra edit outside the named leaves (digests recomputed, so only the derivation can catch it)
create temp table plan_extra on commit drop as
  select pg_temp.seal(jsonb_set(pg_temp.build_plan(), '{actions,0,desired_json_ordered,processDataSet,processInformation,dataSetInformation,common:UUID}', to_jsonb('tampered'::text), false)) as p;
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_extra)))->>'code'), 'LENGTH_TIME_DERIVE_MISMATCH', 'refuse: any edit outside the two named amount leaves');

-- an omitted instance (37 listed against the declared 39)
create temp table plan_omit on commit drop as
  select pg_temp.seal(jsonb_set(pg_temp.build_plan(), '{actions,0,mutation,exchanges}', (pg_temp.build_plan() #> '{actions,0,mutation,exchanges}') - 2, false)) as p;
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_omit)))->>'code'), 'LENGTH_TIME_DERIVE_MISMATCH', 'refuse: an omitted instance no longer derives the claimed desired payload');

-- an absolute-uncertainty field on a selected exchange
create temp table plan_unc on commit drop as
  select pg_temp.seal(jsonb_set(pg_temp.build_plan(), '{actions,1,expected_json_ordered,processDataSet,exchanges,exchange,0,standardDeviation95In}', to_jsonb('1'::text), true)) as p;
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_unc)))->>'code'), 'LENGTH_TIME_DERIVE_MISMATCH', 'refuse: absolute uncertainty on a selected exchange');

-- a foreign live consumer of a claimed flow
insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at)
select 'b20c0de0-0000-4000-8000-000000000099', '00.00.001', '11111111-1111-4111-8111-111111111111', 0, payload::json, timestamptz '2026-09-22 00:00:00+00'
from fixture_rows where i = 1;
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'code'), 'LENGTH_TIME_CLOSURE_MISMATCH', 'refuse: a foreign live consumer of a claimed flow');
delete from public.processes where id = 'b20c0de0-0000-4000-8000-000000000099';

-- a claimed row that left the owner-draft set (the published-state guard refuses an in-place
-- promotion, so the row is removed here and the executor must refuse the vanished action)
delete from public.processes where id = 'b20c0de0-0000-4000-8000-000000000002';
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'code'), 'LENGTH_TIME_ACTION_DRIFT', 'refuse: a claimed process that is no longer an owner-draft row of this actor');
insert into public.processes (id, version, user_id, state_code, json_ordered, modified_at)
select process_id, '00.00.001', 'c536ee37-64ab-427b-b7e3-4e2bb4fdffb7', 0, payload::json, timestamptz '2026-09-22 00:00:00+00'
from fixture_rows where i = 2;

-- a drifted modification timestamp
update public.processes set modified_at = timestamptz '2026-09-22 00:00:01+00' where id = 'b20c0de0-0000-4000-8000-000000000003';
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'code'), 'LENGTH_TIME_ACTION_DRIFT', 'refuse: a drifted modification timestamp');
update public.processes set modified_at = timestamptz '2026-09-22 00:00:00+00' where id = 'b20c0de0-0000-4000-8000-000000000003';

-- the canonical unit group rescaled
update public.unitgroups set json_ordered = jsonb_set(json_ordered::jsonb, '{unitGroupDataSet,units,unit,1,meanValue}', to_jsonb('999'::text), false)::json
  where id = '8a1e27de-c1e7-5049-94bd-6c7ba80f52d1';
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'code'), 'LENGTH_TIME_EVIDENCE_MISMATCH', 'refuse: a rescaled canonical unit group breaks the snapshot binding');
update public.unitgroups set json_ordered = jsonb_set(json_ordered::jsonb, '{unitGroupDataSet,units,unit,1,meanValue}', to_jsonb('1000'::text), false)::json
  where id = '8a1e27de-c1e7-5049-94bd-6c7ba80f52d1';

-- the claimed read-only flow payload drifted
update public.flows set json_ordered = jsonb_set(json_ordered::jsonb, '{flowDataSet,flowInformation,dataSetInformation,common:name}', to_jsonb('changed'::text), true)::json
  where id = 'f10c0de0-0000-4000-8000-000000000004';
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_doc)))->>'code'), 'LENGTH_TIME_EVIDENCE_MISMATCH', 'refuse: a claimed read-only flow whose payload drifted');
select pg_temp.reset_fixture();
select pg_temp.refresh_plan();

-- wrong plan schema handed to the wrong executor (closed both ways)
select is((select (private.cmd_dataset_length_time_v1_guarded(jsonb_build_object('schema_version', 'dataset-alias-plan.v2')))->>'code'), 'LENGTH_TIME_PLAN_INVALID', 'closed: the length-time executor refuses a time plan');
select is((select (private.cmd_dataset_alias_plan_v2_guarded((select p from plan_doc)))->>'code'), 'ALIAS_V2_PLAN_INVALID', 'closed: the time executor refuses a length-time plan');
select is((select (private.cmd_dataset_alias_batch_v2_guarded((select p from plan_doc)))->>'code'), 'ALIAS_V2_BATCH_INVALID', 'closed: the time batch executor refuses a length-time plan');

-- all-or-none: a stale last action leaves zero rows and zero audit rows
create temp table audits_before on commit drop as select count(*)::bigint as n from private.command_audit_log;
create temp table plan_late on commit drop as
  select pg_temp.seal(jsonb_set(pg_temp.build_plan(), '{actions,12,expected_modified_at}', to_jsonb('2020-01-01T00:00:00.000Z'::text), false)) as p;
select is((select (private.cmd_dataset_length_time_v1_guarded((select p from plan_late)))->>'code'), 'LENGTH_TIME_ACTION_DRIFT', 'late failure: a stale action in the batch is refused');
select is((select count(*)::text from private.command_audit_log), (select n::text from audits_before), 'late failure: zero audit rows survive');
select is((select count(*)::text from public.processes p join ids on ids.process_id = p.id
  where p.json_ordered::jsonb #>> '{processDataSet,exchanges,exchange,0,meanAmount}' = ids.literal), '13', 'late failure: every process row still holds its byte-exact before literal (zero rows written)');

select * from finish();
rollback;
