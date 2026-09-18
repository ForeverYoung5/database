begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, private, api;
select no_plan();
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
create temporary table import_webhooks(name text, body jsonb);
create or replace function util.invoke_edge_function(name text, body jsonb, timeout_milliseconds integer default 300000)
returns void language plpgsql security definer set search_path='' as $$
begin insert into pg_temp.import_webhooks values(name,body); end $$;
insert into auth.users(id) values ('65400000-0000-4000-8000-000000000001');
create temporary table package_context(worker uuid,source uuid,lease uuid);
create function pg_temp.new_package(n integer) returns void language plpgsql as $$
declare w uuid:=md5('package-worker-'||n)::uuid; s uuid:=md5('package-source-'||n)::uuid; l uuid:=md5('package-lease-'||n)::uuid;
begin
  if to_regclass('pg_temp.tidas_import_package_entries_v2') is not null then
    truncate pg_temp.tidas_import_package_entries_v2;
  end if;
  truncate pg_temp.package_context;
  insert into pg_temp.package_context values(w,s,l);
  insert into private.worker_jobs(id,job_kind,worker_queue,requested_by,status,payload_schema_version,payload_json,lease_token,lease_expires_at,subject_type,subject_id)
  values(w,'tidas.import_package','package','65400000-0000-4000-8000-000000000001','running','tidas.import_package.request.v2',
    jsonb_build_object('type','import_package','import_policy','root_closure_v2','source_artifact_id',s),l,clock_timestamp()+interval '5 minutes','lca_package_job',s);
  insert into private.lca_package_artifacts(id,job_id,worker_job_id,artifact_kind,status,artifact_url,artifact_sha256,artifact_format,content_type,metadata)
  values(s,s,w,'import_source','ready','fixture://whole-package',repeat('a',64),'tidas-package-zip:v1','application/zip','{"requested_by":"65400000-0000-4000-8000-000000000001"}');
end $$;
create function pg_temp.stage_package(offset_value integer, entries jsonb) returns void language sql as $$
  select private.tidas_import_package_stage_v2(worker,lease,source,repeat('b',64),offset_value,entries) from pg_temp.package_context
$$;
create function pg_temp.apply_package(n integer) returns jsonb language sql as $$
  select private.tidas_import_package_apply_v2(worker,lease,source,repeat('b',64),n) from pg_temp.package_context
$$;
create temporary table package_results(name text primary key,receipt jsonb);
select pg_temp.new_package(1);
select pg_temp.stage_package(0,'[{"table":"contacts","id":"65400000-0000-4000-8000-000000000010","version":"01.00.000","json_ordered":{}}]');
select pg_temp.stage_package(1,'[{"table":"sources","id":"65400000-0000-4000-8000-000000000011","version":"01.00.000","json_ordered":{}}]');
select is((select count(*) from public.contacts where id='65400000-0000-4000-8000-000000000010'),0::bigint,'staging never writes domain data');
select throws_ok('select pg_temp.apply_package(3)','22023','TIDAS_IMPORT_PACKAGE_STAGE_MISMATCH','missing chunk cannot commit');
insert into package_results values('first',pg_temp.apply_package(2));
select is((select receipt->>'inserted_count' from package_results where name='first'),'2','orphan-only package imports all records without a root');
select is((select receipt->>'import_mode' from package_results where name='first'),'whole_package','receipt identifies whole-package mode');
select is(pg_temp.apply_package(2),(select receipt from package_results where name='first'),'exact replay returns original receipt');
select is((select count(*) from private.tidas_import_packages_v2 where worker_job_id=(select worker from package_context)),1::bigint,'one atomic receipt per package');
update pg_temp.tidas_import_package_entries_v2 set entry=jsonb_set(entry,'{json_ordered}','{"changed":true}') where ordinal=0;
select throws_ok('select pg_temp.apply_package(2)','55000','TIDAS_IMPORT_PACKAGE_REPLAY_MISMATCH','replay with changed records is rejected');
select is(api.svc_tidas_package_read_v2('65400000-0000-4000-8000-000000000001',(select worker from package_context))#>>'{data,importProgress,imported_count}','2','owner readback recovers whole-package committed count');
select is(api.svc_tidas_package_read_v2('65400000-0000-4000-8000-000000000099',(select worker from package_context))->'data','null'::jsonb,'foreign actor cannot read receipt summary');

select pg_temp.new_package(2);
select pg_temp.stage_package(0,'[{"table":"contacts","id":"65400000-0000-4000-8000-000000000010","version":"01.00.000","json_ordered":{"different":true}},{"table":"sources","id":"65400000-0000-4000-8000-000000000011","version":"01.00.000","json_ordered":{}}]');
insert into package_results values('existing',pg_temp.apply_package(2));
select is((select receipt->>'existing_count' from package_results where name='existing'),'2','all-existing package skips every record');
select is((select receipt->>'status' from package_results where name='existing'),'reused','all-existing package is a successful reused execution');
select is((select count(*) from package_results, jsonb_array_elements(receipt->'items') item where name='existing' and item->>'disposition'='existing'),2::bigint,'every skip is present in receipt for report generation');
select is((select json_ordered::jsonb from public.contacts where id='65400000-0000-4000-8000-000000000010'),'{}'::jsonb,'skipping never overwrites existing content');

select pg_temp.new_package(3);
select pg_temp.stage_package(0,'[{"table":"contacts","id":"65400000-0000-4000-8000-000000000020","version":"01.00.000","json_ordered":{}}]');
select pg_temp.stage_package(1,'[{"table":"processes","id":"65400000-0000-4000-8000-000000000021","version":"01.00.000","json_ordered":null}]');
select throws_ok('select pg_temp.apply_package(2)','22023','TIDAS_IMPORT_ENTRY_INVALID','late invalid record fails whole package');
select is((select count(*) from public.contacts where id='65400000-0000-4000-8000-000000000020'),0::bigint,'late failure rolls back earlier insert from another chunk');
select is((select count(*) from private.tidas_import_packages_v2 where worker_job_id=(select worker from package_context)),0::bigint,'failed package has no committed receipt');
select is((select count(*) from private.tidas_import_plans_v2 where worker_job_id=(select worker from package_context)),0::bigint,'failed package rolls back plan binding');
select is((select count(*) from public.contacts where id='65400000-0000-4000-8000-000000000010'),1::bigint,'unrelated earlier committed package remains intact');

select pg_temp.new_package(4);
select throws_ok('select pg_temp.apply_package(0)','22023','TIDAS_IMPORT_PACKAGE_INVALID','empty package cannot succeed');
select pg_temp.stage_package(0,'[{"table":"contacts","id":"65400000-0000-4000-8000-000000000030","version":"01.00.000","json_ordered":{}}]');
update private.worker_jobs set lease_expires_at=clock_timestamp()-interval '1 second' where id=(select worker from package_context);
select throws_ok('select pg_temp.apply_package(1)','55000','TIDAS_IMPORT_LEASE_OR_SOURCE_INVALID','expired lease cannot commit staged package');
select is((select count(*) from public.contacts where id='65400000-0000-4000-8000-000000000030'),0::bigint,'expired lease leaves no writes');
select ok(not has_function_privilege('authenticated','private.tidas_import_package_stage_v2(uuid,uuid,uuid,text,integer,jsonb)','EXECUTE'),'browser cannot stage a package');
select ok(not has_function_privilege('anon','private.tidas_import_package_apply_v2(uuid,uuid,uuid,text,integer)','EXECUTE'),'anonymous caller cannot apply a package');
select ok(not has_table_privilege('service_role','private.tidas_import_packages_v2','SELECT'),'receipt table is ACL closed');
select pg_temp.new_package(5);
select pg_temp.stage_package(0,'[{"table":"contacts","id":"65400000-0000-4000-8000-000000000010","version":"01.00.000","json_ordered":{}},{"table":"sources","id":"65400000-0000-4000-8000-000000000010","version":"01.00.000","json_ordered":{}}]');
insert into package_results values('types',pg_temp.apply_package(2));
select is((select receipt->>'inserted_count' from package_results where name='types'),'1','same id/version in a different type is inserted');
select is((select receipt->>'existing_count' from package_results where name='types'),'1','skip identity includes the data type');

select pg_temp.new_package(6);
create function pg_temp.expire_import_lease() returns trigger language plpgsql as $$
begin
  update private.worker_jobs set lease_expires_at=clock_timestamp()-interval '1 second' where id=(select worker from pg_temp.package_context);
  return new;
end $$;
create trigger test_package_lease_loss after insert on public.contacts for each row
  when (new.id='65400000-0000-4000-8000-000000000040') execute function pg_temp.expire_import_lease();
select pg_temp.stage_package(0,'[{"table":"contacts","id":"65400000-0000-4000-8000-000000000040","version":"01.00.000","json_ordered":{}}]');
select throws_ok('select pg_temp.apply_package(1)','55000','TIDAS_IMPORT_LEASE_OR_SOURCE_INVALID','final fence rejects lease lost during domain inserts');
select is((select count(*) from public.contacts where id='65400000-0000-4000-8000-000000000040'),0::bigint,'final fence rolls back all domain writes');
select is((select count(*) from private.tidas_import_packages_v2 where worker_job_id=(select worker from package_context)),0::bigint,'final fence rolls back receipt publication');
select pg_temp.new_package(7);
select pg_temp.stage_package(0,'[{"table":"processes","id":"65400000-0000-4000-8000-000000000050","version":"01.00.000","json_ordered":{}},{"table":"lifecyclemodels","id":"65400000-0000-4000-8000-000000000051","version":"01.00.000","json_ordered":{"lifeCycleModelDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}}]');
insert into package_results values('roots',pg_temp.apply_package(2));
select is((select receipt->>'root_count' from package_results where name='roots'),'2','whole package receipt records real roots without requiring them');
select is(api.svc_tidas_package_read_v2('65400000-0000-4000-8000-000000000001',(select worker from package_context))#>>'{data,importProgress,successful_root_count}','2','recovered whole-package root counts remain accurate');
select * from finish();
rollback;
