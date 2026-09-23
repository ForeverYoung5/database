-- Database #712: Open Data catalog filters and exact-version Process publication.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

create temporary table open_data_webhook_calls (
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
  insert into pg_temp.open_data_webhook_calls(edge_function, body, timeout_milliseconds)
  values (name, body, timeout_milliseconds);
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
) values
  ('00000000-0000-0000-0000-000000000000','71200000-0000-4000-8000-000000000001',
   'authenticated','authenticated','open-data-manager@example.invalid','x',now(),'{}','{}',now(),now(),false,false),
  ('00000000-0000-0000-0000-000000000000','71200000-0000-4000-8000-000000000002',
   'authenticated','authenticated','open-data-owner@example.invalid','x',now(),'{}','{}',now(),now(),false,false);

insert into private.users(id, raw_user_meta_data, contact) values
  ('71200000-0000-4000-8000-000000000001','{}',null),
  ('71200000-0000-4000-8000-000000000002','{}',null);
insert into private.teams(id, json, rank, is_public)
values ('00000000-0000-0000-0000-000000000000','{"name":"System"}',0,false)
on conflict (id) do nothing;
insert into private.roles(user_id, team_id, role) values
  ('71200000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','data_product_manager');

insert into public.processes(
  id, version, state_code, user_id, json, search_text, embedding_ft, modified_at
) values
  ('71200000-0000-4000-8000-000000000010','01.00.000',100,null,
   '{"testScope":"open-data-712","label":"catalogtoken old","mention":"71200000-0000-4000-8000-000000000099"}',
   array['catalogtoken old'], array_fill(0.10::real,array[1024])::extensions.vector, now() - interval '2 days'),
  ('71200000-0000-4000-8000-000000000010','02.00.000',100,null,
   '{"testScope":"open-data-712","label":"catalogtoken latest","mention":"71200000-0000-4000-8000-000000000099"}',
   array['catalogtoken latest'], array_fill(0.10::real,array[1024])::extensions.vector, now() - interval '1 day'),
  ('71200000-0000-4000-8000-000000000011','01.00.000',100,
   '71200000-0000-4000-8000-000000000002',
   '{"testScope":"open-data-712","label":"catalogtoken enterprise"}',
   array['catalogtoken enterprise'], array_fill(0.20::real,array[1024])::extensions.vector, now()),
  ('71200000-0000-4000-8000-000000000012','01.00.000',0,null,
   '{"testScope":"open-data-712","label":"catalogtoken draft"}',
   array['catalogtoken draft'], null, now());

insert into public.contacts(id, version, state_code, user_id, json, search_text)
values
  ('71200000-0000-4000-8000-000000000020','01.00.000',100,null,
   '{"testScope":"open-data-712","label":"catalogtoken literature"}',array['catalogtoken literature']),
  ('71200000-0000-4000-8000-000000000021','01.00.000',100,
   '71200000-0000-4000-8000-000000000002',
   '{"testScope":"open-data-712","label":"catalogtoken enterprise"}',array['catalogtoken enterprise']);

select ok(
  not has_table_privilege('authenticated','private.open_data_process_publications','select')
  and not has_table_privilege('authenticated','private.open_data_process_publications','insert'),
  'the Open Data publication relation remains inaccessible to browser DML'
);
select ok(
  has_function_privilege('authenticated','api.cmd_open_data_process_publish_batch(jsonb)','execute')
  and not has_function_privilege('anon','api.cmd_open_data_process_publish_batch(jsonb)','execute')
  and not has_function_privilege('service_role','api.cmd_open_data_process_publish_batch(jsonb)','execute'),
  'only authenticated actor sessions can enter the Open Data publish command'
);
select ok(
  has_function_privilege(
    'anon',
    'api.search_open_data_catalog(text,text,text,text[],jsonb,text,text,integer,integer,text,text)',
    'execute'
  ),
  'Open Data catalog queries remain public'
);

select is(
  (select total_count::text from api.search_open_data_catalog(
    'process','list','',null,'{"testScope":"open-data-712"}','all','all',10,1
  ) limit 1),
  '2',
  'the list returns latest state-100 Process identities from both origins'
);
select is(
  (select total_count::text from api.search_open_data_catalog(
    'process','list','',null,'{"testScope":"open-data-712"}','literature','all',10,1
  ) limit 1),
  '1',
  'the literature filter selects null user_id before count and page'
);
select is(
  (select total_count::text from api.search_open_data_catalog(
    'process','list','',null,'{"testScope":"open-data-712"}','enterprise','all',10,1
  ) limit 1),
  '1',
  'the enterprise filter selects non-null user_id before count and page'
);
select is(
  (select version::text from api.search_open_data_catalog(
    'process','list','',null,'{"testScope":"open-data-712"}','literature','all',10,1
  ) limit 1),
  '02.00.000',
  'the latest eligible Process version is selected after source filtering'
);
select is(
  (select total_count::text from api.search_open_data_catalog(
    'contact','list','',null,'{"testScope":"open-data-712"}','enterprise','all',10,1
  ) limit 1),
  '1',
  'the shared source filter applies to non-Process Open Data types'
);
select is(
  (select total_count::text from api.search_open_data_catalog(
    'process','lexical','catalogtoken',array['catalogtoken'],
    '{"testScope":"open-data-712"}','literature','all',10,1
  ) limit 1),
  '1',
  'lexical candidates are source-filtered before count and page'
);
select is(
  (select total_count::text from api.search_open_data_catalog(
    'process','uuid','71200000-0000-4000-8000-000000000099',null,
    '{"testScope":"open-data-712"}','literature','all',10,1
  ) limit 1),
  '1',
  'UUID mention candidates are source-filtered before count and page'
);

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','71200000-0000-4000-8000-000000000002',true);
select throws_ok(
  $$select api.cmd_open_data_process_publish_batch(
    '[{"id":"71200000-0000-4000-8000-000000000010","version":"02.00.000"}]'
  )$$,
  '42501',
  'data_product_manager role required',
  'a non-manager cannot publish Open Data Processes'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','71200000-0000-4000-8000-000000000001',true);
create temporary table publish_result on commit drop as
select api.cmd_open_data_process_publish_batch(
  '[{"id":"71200000-0000-4000-8000-000000000010","version":"02.00.000"},
    {"id":"71200000-0000-4000-8000-000000000010","version":"02.00.000"}]'
) as response;
select is((select response #>> '{data,inputCount}' from publish_result), '2',
  'the command reports the original input count');
select is((select response #>> '{data,requestedCount}' from publish_result), '1',
  'the command deduplicates exact identities');
select is((select response #>> '{data,publishedCount}' from publish_result), '1',
  'the command inserts one exact publication');
select is(
  api.cmd_open_data_process_publish_batch(
    '[{"id":"71200000-0000-4000-8000-000000000010","version":"02.00.000"}]'
  ) #>> '{data,alreadyPublishedCount}',
  '1',
  'an exact retry is idempotent'
);
reset role;

select is(
  (select state_code::text from public.processes
   where id='71200000-0000-4000-8000-000000000010' and version='02.00.000'),
  '100',
  'publication does not change state_code'
);
select is(
  (select published_by::text from private.open_data_process_publications
   where process_id='71200000-0000-4000-8000-000000000010'
     and process_version='02.00.000'),
  '71200000-0000-4000-8000-000000000001',
  'the server-derived manager identity is retained for audit'
);
select throws_ok(
  $$delete from private.open_data_process_publications
    where process_id='71200000-0000-4000-8000-000000000010'
      and process_version='02.00.000'$$,
  '55000',
  'Open Data Process publications are append-only',
  'publication rows cannot be withdrawn by mutation'
);
select is(
  (select total_count::text from api.search_open_data_catalog(
    'process','list','',null,'{"testScope":"open-data-712"}','all','published',10,1
  ) limit 1),
  '1',
  'the published filter sees the new exact publication'
);
select is(
  (select total_count::text from api.search_open_data_catalog(
    'process','list','',null,'{"testScope":"open-data-712"}','all','unpublished',10,1
  ) limit 1),
  '1',
  'the unpublished filter retains the other Process'
);
select is(
  (select total_count::text from api.hybrid_search_open_data_catalog(
    'process','catalogtoken',array_fill(0.10::real,array[1024])::extensions.vector::text,
    '{"testScope":"open-data-712"}',0,20,0.5,0.5,10,10,1,
    array['catalogtoken'],'literature','published'
  ) limit 1),
  '1',
  'hybrid lexical and semantic candidates honor source and publication filters'
);

select throws_ok(
  $$select api.search_open_data_catalog(
    'contact','list','',null,'{}','all','published',10,1
  )$$,
  '22023',
  'publication filter is supported only for Process data',
  'publication status cannot be applied to non-Process types'
);

select * from finish();
rollback;
