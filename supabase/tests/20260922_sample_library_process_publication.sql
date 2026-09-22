-- Database #684 / workspace #1464: sample-library query and Process publication proof.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

-- Dataset inserts normally enqueue extraction webhooks. A disposable database has no Vault
-- secret, so capture only that outbound call without disabling any source-table trigger.
create temporary table sample_library_webhook_calls (
  edge_function text not null,
  body jsonb not null,
  timeout_milliseconds integer not null
) on commit drop;

create or replace function util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds integer default ((5 * 60) * 1000)
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into pg_temp.sample_library_webhook_calls(
    edge_function, body, timeout_milliseconds
  ) values (name, body, timeout_milliseconds);
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
) values
  ('00000000-0000-0000-0000-000000000000','68400000-0000-4000-8000-000000000001',
   'authenticated','authenticated','sample-manager@example.invalid','x',now(),'{}','{}',now(),now(),false,false),
  ('00000000-0000-0000-0000-000000000000','68400000-0000-4000-8000-000000000002',
   'authenticated','authenticated','sample-owner@example.invalid','x',now(),'{}','{}',now(),now(),false,false);

insert into private.users(id, raw_user_meta_data, contact) values
  ('68400000-0000-4000-8000-000000000001','{}',null),
  ('68400000-0000-4000-8000-000000000002','{}',null);
insert into private.teams(id, json, rank, is_public)
values ('00000000-0000-0000-0000-000000000000','{"name":"System"}',0,false)
on conflict (id) do nothing;
insert into private.roles(user_id, team_id, role) values
  ('68400000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','data_product_manager');

-- Two published-state versions of one literature Process prove latest-per-id selection.
insert into public.processes(id, version, state_code, user_id, json, modified_at) values
  ('68400000-0000-4000-8000-000000000010','01.00.000',100,null,
   '{"name":"literature-old"}',now() - interval '2 days'),
  ('68400000-0000-4000-8000-000000000010','02.00.000',100,null,
   '{"name":"literature-latest"}',now() - interval '1 day'),
  ('68400000-0000-4000-8000-000000000011','01.00.000',100,
   '68400000-0000-4000-8000-000000000002','{"name":"enterprise"}',now()),
  ('68400000-0000-4000-8000-000000000012','01.00.000',0,null,
   '{"name":"draft"}',now()),
  ('68400000-0000-4000-8000-000000000013','01.00.000',100,null,
   '{"name":"atomic-valid"}',now());

insert into public.lifecyclemodels(id, version, state_code, user_id, json)
values ('68400000-0000-4000-8000-000000000020','01.00.000',100,null,'{"name":"model"}');
insert into public.flows(id, version, state_code, user_id, json)
values ('68400000-0000-4000-8000-000000000021','01.00.000',100,null,'{"name":"flow"}');
insert into public.flowproperties(id, version, state_code, user_id, json)
values ('68400000-0000-4000-8000-000000000022','01.00.000',100,null,'{"name":"property"}');
insert into public.unitgroups(id, version, state_code, user_id, json)
values ('68400000-0000-4000-8000-000000000023','01.00.000',100,null,'{"name":"unit"}');
insert into public.sources(id, version, state_code, user_id, json)
values ('68400000-0000-4000-8000-000000000024','01.00.000',100,null,'{"name":"source"}');
insert into public.contacts(id, version, state_code, user_id, json)
values ('68400000-0000-4000-8000-000000000025','01.00.000',100,null,'{"name":"contact"}');

select ok(
  not has_table_privilege('authenticated','private.sample_library_process_publications','select')
  and not has_table_privilege('service_role','private.sample_library_process_publications','insert'),
  'the private publication relation has no browser or service write access'
);
select ok(
  has_function_privilege('authenticated',
    'api.qry_sample_library_process_publications_v1(jsonb)','execute')
  and has_function_privilege('authenticated',
    'api.cmd_sample_library_publish_processes_v1(jsonb)','execute')
  and not has_function_privilege('anon',
    'api.cmd_sample_library_publish_processes_v1(jsonb)','execute'),
  'only authenticated callers can execute the sample-library RPCs'
);
select ok(
  exists (
    select 1 from private.api_capability_grants
    where routine_identity = 'api.qry_sample_library_process_publications_v1(jsonb)'
      and capability_id = 'NX-CORE-02' and allow_authenticated
      and not allow_anon and not allow_service_role
  ) and exists (
    select 1 from private.api_capability_grants
    where routine_identity = 'api.cmd_sample_library_publish_processes_v1(jsonb)'
      and capability_id = 'CLI-RPC-01' and allow_authenticated
      and not allow_anon and not allow_service_role
  ),
  'both exact signatures are classified in the API capability manifest'
);

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','68400000-0000-4000-8000-000000000002',true);
select is(
  (select count(*)::text from api.get_latest_process_versions(
    data_source => 'sl', sample_origin_filter => 'all')),
  '0',
  'an ordinary authenticated owner cannot read the manager sample library'
);
select is(
  api.cmd_sample_library_publish_processes_v1(
    '[{"id":"68400000-0000-4000-8000-000000000010","version":"02.00.000"}]'
  ) ->> 'code',
  'not_data_product_manager',
  'an ordinary authenticated owner cannot publish a Process'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','68400000-0000-4000-8000-000000000001',true);

select is(
  (select count(*)::text from api.get_latest_process_versions(
    data_source => 'sl', sample_origin_filter => 'all')),
  '3',
  'the Process catalog returns only latest state-100 identities'
);
select is(
  (select count(*)::text from api.get_latest_process_versions(
    data_source => 'sl', sample_origin_filter => 'literature')),
  '2',
  'the literature origin filter selects rows without user_id'
);
select is(
  (select count(*)::text from api.get_latest_process_versions(
    data_source => 'sl', sample_origin_filter => 'enterprise')),
  '1',
  'the enterprise origin filter selects rows with user_id'
);
select is(
  (select version::text from api.get_latest_process_versions(
    page_size => 100, data_source => 'sl', sample_origin_filter => 'all')
   where id = '68400000-0000-4000-8000-000000000010'),
  '02.00.000',
  'the catalog exposes the latest eligible version for a Process identity'
);
select is(
  (select count(*)::text from api.get_latest_process_versions(
    data_source => 'sl', sample_publication_status_filter => 'published')),
  '0',
  'no Process is initially published'
);

select is(
  (select count(*)::text from api.get_latest_contact_versions(data_source => 'sl')), '1',
  'Contacts are exposed through the shared state-100 contract'
);
select is(
  (select count(*)::text from api.get_latest_source_versions(data_source => 'sl')), '1',
  'Sources are exposed through the shared state-100 contract'
);
select is(
  (select count(*)::text from api.get_latest_unitgroup_versions(data_source => 'sl')), '1',
  'Unit Groups are exposed through the shared state-100 contract'
);
select is(
  (select count(*)::text from api.get_latest_flowproperty_versions(data_source => 'sl')), '1',
  'Flow Properties are exposed through the shared state-100 contract'
);
select is(
  (select count(*)::text from api.get_latest_flow_versions(data_source => 'sl')), '1',
  'Flows are exposed through the shared state-100 contract'
);
select is(
  (select count(*)::text from api.get_latest_lifecyclemodel_versions(data_source => 'sl')), '1',
  'Lifecycle Models are exposed through the shared state-100 contract'
);
-- A mixed valid/invalid batch fails before writing any publication rows.
select is(
  api.cmd_sample_library_publish_processes_v1(jsonb_build_array(
    jsonb_build_object('id','68400000-0000-4000-8000-000000000013','version','01.00.000'),
    jsonb_build_object('id','68400000-0000-4000-8000-000000000012','version','01.00.000')
  )) ->> 'code',
  'process_not_publishable',
  'a batch containing a non-state-100 Process is rejected'
);
reset role;
select is(
  (select count(*)::text from private.sample_library_process_publications),
  '0',
  'the rejected batch is all-or-nothing'
);

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','68400000-0000-4000-8000-000000000001',true);
create temporary table first_publish on commit drop as
select api.cmd_sample_library_publish_processes_v1(jsonb_build_array(
  jsonb_build_object('id','68400000-0000-4000-8000-000000000010','version','02.00.000'),
  jsonb_build_object('id','68400000-0000-4000-8000-000000000011','version','01.00.000')
)) as response;
select is((select response #>> '{data,requestedCount}' from first_publish), '2',
  'the command reports the requested Process count');
select is((select response #>> '{data,publishedCount}' from first_publish), '2',
  'the command publishes both selected Process versions');
select is(
  (select count(*)::text from api.get_latest_process_versions(
    data_source => 'sl', sample_publication_status_filter => 'published')),
  '2',
  'the published filter reflects the exact-version publication relation'
);
select is(
  (select count(*)::text from api.get_latest_process_versions(
    data_source => 'sl', sample_publication_status_filter => 'unpublished')),
  '1',
  'the unpublished filter retains the remaining eligible Process'
);

create temporary table retry_publish on commit drop as
select api.cmd_sample_library_publish_processes_v1(
  '[{"id":"68400000-0000-4000-8000-000000000010","version":"02.00.000"}]'
) as response;
select is((select response #>> '{data,publishedCount}' from retry_publish), '0',
  'an exact publication retry inserts no duplicate receipt');
select is((select response #>> '{data,alreadyPublishedCount}' from retry_publish), '1',
  'an exact publication retry reports the existing receipt');
reset role;

select is(
  (select count(*)::text from private.sample_library_process_publications),
  '2',
  'the relation stores one receipt per exact Process version'
);
select is(
  (select state_code::text from public.processes
    where id='68400000-0000-4000-8000-000000000010' and version='02.00.000'),
  '100',
  'publishing does not change the Process state_code'
);
select is(
  (select published_by::text from private.sample_library_process_publications
    where process_id='68400000-0000-4000-8000-000000000010'
      and process_version='02.00.000'),
  '68400000-0000-4000-8000-000000000001',
  'the server-derived manager identity is recorded'
);
select throws_ok(
  $$update private.sample_library_process_publications
    set published_at = now()
    where process_id='68400000-0000-4000-8000-000000000010'$$,
  '55000',
  'SAMPLE_LIBRARY_PUBLICATION_IMMUTABLE',
  'publication receipts are append-only'
);

select * from finish();
rollback;
