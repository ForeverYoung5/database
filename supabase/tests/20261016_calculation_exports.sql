begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  '81300000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'semantic-downloads@example.com',
  'test-password-hash', now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"sub":"81300000-0000-4000-8000-000000000001"}'::jsonb,
  now(), now(), false, false
);

insert into private.users (id, raw_user_meta_data, contact)
values (
  '81300000-0000-4000-8000-000000000001',
  '{"email":"semantic-downloads@example.com"}'::jsonb,
  null
);
insert into private.teams (id, json, rank, is_public)
values ('00000000-0000-0000-0000-000000000000', '{"name":"System Team"}', 0, false)
on conflict (id) do nothing;
insert into private.roles (user_id, team_id, role)
values (
  '81300000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'data_product_manager'
);

insert into private.lca_network_snapshots (id, scope, status, created_by)
values (
  '81300000-0000-4000-8000-000000000010',
  'full_library', 'ready', '81300000-0000-4000-8000-000000000001'
);
insert into private.worker_jobs (
  id, job_kind, worker_queue, requester_type, requested_by,
  status, payload_schema_version, payload_json
) values
  (
    '81300000-0000-4000-8000-000000000020',
    'lca.solve_all_unit', 'solver', 'user',
    '81300000-0000-4000-8000-000000000001', 'completed',
    'lca.solve_all_unit.request.v1', '{}'
  ),
  (
    '81300000-0000-4000-8000-000000000021',
    'lca.solve_all_unit', 'solver', 'user',
    '81300000-0000-4000-8000-000000000001', 'completed',
    'lca.solve_all_unit.request.v1', '{}'
  ),
  (
    '81300000-0000-4000-8000-000000000022',
    'lca.solve_all_unit', 'solver', 'user',
    '81300000-0000-4000-8000-000000000001', 'completed',
    'lca.solve_all_unit.request.v1', '{}'
  ),
  (
    '81300000-0000-4000-8000-000000000023',
    'lca.solve_all_unit', 'solver', 'user',
    '81300000-0000-4000-8000-000000000001', 'completed',
    'lca.solve_all_unit.request.v1', '{}'
  );
insert into private.lca_results (
  id, job_id, snapshot_id, diagnostics, worker_job_id
) values
  (
    '81300000-0000-4000-8000-000000000030',
    '81300000-0000-4000-8000-000000000020',
    '81300000-0000-4000-8000-000000000010', '{}',
    '81300000-0000-4000-8000-000000000020'
  ),
  (
    '81300000-0000-4000-8000-000000000031',
    '81300000-0000-4000-8000-000000000021',
    '81300000-0000-4000-8000-000000000010', '{}',
    '81300000-0000-4000-8000-000000000021'
  ),
  (
    '81300000-0000-4000-8000-000000000032',
    '81300000-0000-4000-8000-000000000022',
    '81300000-0000-4000-8000-000000000010', '{}',
    '81300000-0000-4000-8000-000000000022'
  ),
  (
    '81300000-0000-4000-8000-000000000033',
    '81300000-0000-4000-8000-000000000023',
    '81300000-0000-4000-8000-000000000010', '{}',
    '81300000-0000-4000-8000-000000000023'
  );

create or replace function pg_temp.semantic_downloads()
returns jsonb
language sql
immutable
as $$
  select jsonb_agg(jsonb_build_object(
    'role', item.role,
    'group', item.group_name,
    'fileName', item.file_name,
    'schemaVersion', 'tiangong.calculation-download.v1',
    'mediaType', item.media_type,
    'artifactUrl', 's3://lca_results/downloads/' || item.file_name,
    'sha256', repeat('a', 64),
    'byteSize', 100,
    'recordCount', 10
  ) order by item.ordinal)
  from (values
    (1, 'lcia_results_xlsx', 'results', 'lcia-results.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
    (2, 'lcia_results_csv_zip', 'results', 'lcia-results.csv.zip', 'application/zip'),
    (3, 'lci_inventory_parquet', 'advanced_data', 'lci-inventory.parquet', 'application/vnd.apache.parquet'),
    (4, 'lci_inventory_csv_zip', 'advanced_data', 'lci-inventory-csv.zip', 'application/zip'),
    (5, 'calculation_evidence_bundle', 'audit_evidence', 'calculation-evidence-bundle.zip', 'application/zip')
  ) as item(ordinal, role, group_name, file_name, media_type)
$$;

insert into private.lcia_result_packages (
  id, build_id, build_worker_job_id, package_version, coverage_mode,
  eligibility_resolved_at, eligible_input_count, included_input_count,
  input_manifest_hash, input_manifest, snapshot_id, result_id,
  artifact_manifest, created_by
) values
  (
    '81300000-0000-4000-8000-000000000040',
    '81300000-0000-4000-8000-000000000050',
    '81300000-0000-4000-8000-000000000020',
    '01.00.000', 'global_eligible', now(), 1, 1, repeat('b', 64), '{}',
    '81300000-0000-4000-8000-000000000010',
    '81300000-0000-4000-8000-000000000030',
    jsonb_build_object(
      'calculationBundle', jsonb_build_object(
        'schemaVersion', 'tiangong.calculation-bundle.v2',
        'calculationId','81300000-0000-4000-8000-000000000020',
        'bundleContentHash',repeat('a',64),'manifestSha256',repeat('b',64),'manifestByteSize',200,'artifactCount',3,
        'manifestUrl', 's3://lca_results/calculation-bundle.json',
        'downloads', pg_temp.semantic_downloads()
      )
    ),
    '81300000-0000-4000-8000-000000000001'
  ),
  (
    '81300000-0000-4000-8000-000000000041',
    '81300000-0000-4000-8000-000000000051',
    '81300000-0000-4000-8000-000000000021',
    '01.00.001', 'global_eligible', now(), 1, 1, repeat('c', 64), '{}',
    '81300000-0000-4000-8000-000000000010',
    '81300000-0000-4000-8000-000000000031',
    jsonb_build_object(
      'calculationBundle', jsonb_build_object(
        'schemaVersion', 'tiangong.calculation-bundle.v2',
        'manifestUrl', 's3://lca_results/legacy-calculation-bundle.json'
      )
    ),
    '81300000-0000-4000-8000-000000000001'
  ),
  (
    '81300000-0000-4000-8000-000000000042',
    '81300000-0000-4000-8000-000000000052',
    '81300000-0000-4000-8000-000000000022',
    '01.00.002', 'global_eligible', now(), 1, 1, repeat('d', 64), '{}',
    '81300000-0000-4000-8000-000000000010',
    '81300000-0000-4000-8000-000000000032',
    jsonb_build_object(
      'calculationBundle', jsonb_build_object(
        'schemaVersion', 'tiangong.calculation-bundle.v2',
        'manifestUrl', 's3://lca_results/invalid-media-calculation-bundle.json',
        'downloads', jsonb_set(
          pg_temp.semantic_downloads(), '{0,mediaType}', '"text/plain"'::jsonb
        )
      )
    ),
    '81300000-0000-4000-8000-000000000001'
  ),
  (
    '81300000-0000-4000-8000-000000000043',
    '81300000-0000-4000-8000-000000000053',
    '81300000-0000-4000-8000-000000000023',
    '01.00.003', 'global_eligible', now(), 1, 1, repeat('e', 64), '{}',
    '81300000-0000-4000-8000-000000000010',
    '81300000-0000-4000-8000-000000000033',
    jsonb_build_object(
      'calculationBundle', jsonb_build_object(
        'schemaVersion', 'tiangong.calculation-bundle.v2',
        'manifestUrl', 's3://lca_results/duplicate-role-calculation-bundle.json',
        'downloads', jsonb_set(
          pg_temp.semantic_downloads(), '{1}', pg_temp.semantic_downloads()->0
        )
      )
    ),
    '81300000-0000-4000-8000-000000000001'
  );

grant execute on function pg_temp.semantic_downloads() to authenticated;
reset role;

select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
create function pg_temp.export_request(enqueue boolean default false, format text default 'parquet') returns jsonb language sql as $$
  select api.svc_lca_calculation_export('81300000-0000-4000-8000-000000000001','81300000-0000-4000-8000-000000000040',format,enqueue)
$$;
select is(pg_temp.export_request()#>>'{data,status}','not_requested','status read does not enqueue default Parquet');
select is((select count(*) from private.worker_jobs where job_kind='lca.calculation_export'),0::bigint,'read creates no jobs');
select is(pg_temp.export_request(true)#>>'{data,status}','queued','explicit export queues');
select is(pg_temp.export_request(true)#>>'{data,format}','parquet','omitted format defaults to Parquet');
select is((select count(*) from private.worker_jobs where job_kind='lca.calculation_export'),1::bigint,'duplicate explicit export reuses job');
select is((select payload_json#>>'{bundle,manifestSha256}' from private.worker_jobs where job_kind='lca.calculation_export'),repeat('b',64),'worker receives frozen source hash');
update private.worker_jobs set status='failed',retryable=null,error_code='artifact_too_large' where job_kind='lca.calculation_export';
select is(pg_temp.export_request(true)#>>'{data,status}','failed','explicit duplicate preserves terminal result until retry');
select ok(bool_and(pg_temp.export_request()#>>'{data,status}'='failed'),'status polls retain failure') from generate_series(1,20);
select is((select count(*) from private.worker_jobs where job_kind='lca.calculation_export'),1::bigint,'no export failure successors');
select is((select status from private.lcia_result_packages where id='81300000-0000-4000-8000-000000000040'),'preview_ready','export failure preserves calculation readiness');
select is(pg_temp.export_request(true,'csv')#>>'{data,status}','queued','CSV is a separately bound explicit job');
create temporary table export_claim as select private.worker_claim_jobs('solver','export-test',1,300) as value;
select is((select value#>>'{data,0,jobKind}' from export_claim),'lca.calculation_export','export uses native solver queue lease');
select is(private.worker_record_job_result(
 p_job_id=>(select (value#>>'{data,0,id}')::uuid from export_claim),
 p_lease_token=>'00000000-0000-0000-0000-000000000000',p_status=>'completed')->>'code',
 'WORKER_JOB_LEASE_TOKEN_MISMATCH','stale export completion cannot publish');
select is(private.worker_record_job_result(
 p_job_id=>(select (value#>>'{data,0,id}')::uuid from export_claim),
 p_lease_token=>(select (value#>>'{data,0,leaseToken}')::uuid from export_claim),p_status=>'completed',
 p_result_json=>'{"schemaVersion":"lca.calculation_export.result.v1"}',
 p_result_schema_version=>'lca.calculation_export.result.v1')#>>'{data,status}',
 'completed','current export lease publishes independently');
select is(pg_temp.export_request(false,'csv')#>>'{data,status}','completed','read sees completed independent export');
select is((select status from private.lcia_result_packages where id='81300000-0000-4000-8000-000000000040'),'preview_ready','completion preserves calculation readiness');
select is(pg_temp.export_request(true,'zip')->>'code','invalid_export_format','unbounded arbitrary format rejected');
select is(api.svc_lca_calculation_export('81300000-0000-4000-8000-000000000099','81300000-0000-4000-8000-000000000040')->>'status','403','nonmanager denied even through service');
delete from private.roles where user_id='81300000-0000-4000-8000-000000000001';
select is(pg_temp.export_request()->>'status','403','revoked manager cannot read cached exports');
select ok(not has_function_privilege('authenticated','api.svc_lca_calculation_export(uuid,uuid,text,boolean)','execute'),'browser cannot enqueue directly');
select ok(has_function_privilege('service_role','api.svc_lca_calculation_export(uuid,uuid,text,boolean)','execute'),'service facade is admitted');
select * from finish();
rollback;
