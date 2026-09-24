begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;

select plan(13);

select ok(
  has_function_privilege('authenticated', 'api.qry_review_get_my_contact_status()', 'EXECUTE')
    and has_function_privilege('authenticated', 'api.cmd_review_contact_activate(text,uuid,jsonb,uuid,text,boolean,jsonb,jsonb)', 'EXECUTE'),
  'authenticated reviewer can use reviewer profile RPCs'
);

select ok(
  not has_function_privilege('anon', 'api.qry_review_get_my_contact_status()', 'EXECUTE')
    and not has_function_privilege('anon', 'api.cmd_review_contact_activate(text,uuid,jsonb,uuid,text,boolean,jsonb,jsonb)', 'EXECUTE'),
  'anonymous callers cannot use reviewer profile RPCs'
);

insert into auth.users(
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  '72400000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
  'reviewer-profile@example.com', 'test', now(), '{}', '{}', now(), now(), false, false
);

insert into private.users(id, raw_user_meta_data, contact)
values ('72400000-0000-4000-8000-000000000001', '{}', null);

insert into private.roles(user_id, team_id, role)
values (
  '72400000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'review-member'
);

insert into public.sources(id, json_ordered, user_id, state_code, rule_verification)
values (
  'a97a0155-0234-4b87-b4ce-a45da52f2a40',
  '{"sourceDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"03.00.003"}}}}'::json,
  '72400000-0000-4000-8000-000000000001',
  100,
  true
);

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '72400000-0000-4000-8000-000000000001', true);

select is(api.qry_review_get_my_contact_status() #>> '{data,status}', 'missing',
  'new reviewer starts with a missing profile');

create temporary table reviewer_profile_result as
select api.cmd_review_contact_activate(
  'create',
  '72400000-0000-4000-8000-000000000101',
  '{
    "contactDataSet": {
      "contactInformation": {"dataSetInformation": {
        "common:UUID": "72400000-0000-4000-8000-000000000101",
        "common:shortName": [{"@xml:lang":"en","#text":"Reviewer"}],
        "common:name": [{"@xml:lang":"en","#text":"Reviewer Profile"}],
        "classificationInformation": {"common:classification": {"common:class": {"@level":"0","@classId":"1","#text":"Organisation"}}}
      }},
      "administrativeInformation": {"dataEntryBy": {
        "common:timeStamp":"2026-09-24T00:00:00Z",
        "common:referenceToDataSetFormat":{"@refObjectId":"a97a0155-0234-4b87-b4ce-a45da52f2a40","@type":"source data set","@version":"03.00.003"}
      }, "publicationAndOwnership": {
        "common:dataSetVersion": "01.00.000"
      }}
    }
  }'::jsonb,
  '72400000-0000-4000-8000-000000000201',
  null, true, null, '{}'
) as result;

select is((select result->>'ok' from reviewer_profile_result), 'true',
  'initial reviewer profile activation succeeds');
select is((select result #>> '{data,dataset,state_code}' from reviewer_profile_result), '100',
  'initial reviewer profile is opened atomically');
select is((select result #>> '{data,dataset,rule_verification}' from reviewer_profile_result), 'true',
  'initial reviewer profile records successful validation');
select is(api.qry_review_get_my_contact_status() #>> '{data,status}', 'ready',
  'activated reviewer profile is ready');
select is(
  (select json_ordered::jsonb #>> '{contactDataSet,administrativeInformation,publicationAndOwnership,common:referenceToOwnershipOfDataSet,@refObjectId}'
   from public.contacts where id = '72400000-0000-4000-8000-000000000101'),
  '72400000-0000-4000-8000-000000000101',
  'data-set owner is forced to the created contact'
);

select is(
  api.cmd_review_contact_activate(
    'create', '72400000-0000-4000-8000-000000000101', '{}'::jsonb,
    '72400000-0000-4000-8000-000000000201', null, true, null, '{}'
  )->>'idempotent_replay',
  'true',
  'operation replay is idempotent'
);

create temporary table reviewer_profile_version_result as
select api.cmd_review_contact_activate(
  'createVersion',
  '72400000-0000-4000-8000-000000000101',
  '{
    "contactDataSet": {
      "contactInformation": {"dataSetInformation": {
        "common:UUID": "72400000-0000-4000-8000-000000000101",
        "common:shortName": [{"@xml:lang":"en","#text":"Reviewer v2"}],
        "common:name": [{"@xml:lang":"en","#text":"Reviewer Profile v2"}],
        "classificationInformation": {"common:classification": {"common:class": {"@level":"0","@classId":"1","#text":"Organisation"}}}
      }},
      "administrativeInformation": {"dataEntryBy": {
        "common:timeStamp":"2026-09-24T00:00:00Z",
        "common:referenceToDataSetFormat":{"@refObjectId":"a97a0155-0234-4b87-b4ce-a45da52f2a40","@type":"source data set","@version":"03.00.003"}
      }, "publicationAndOwnership": {
        "common:dataSetVersion": "01.00.000"
      }}
    }
  }'::jsonb,
  '72400000-0000-4000-8000-000000000202',
  (select contact->>'@version' from private.users where id = '72400000-0000-4000-8000-000000000001'),
  false,
  (select contact from private.users where id = '72400000-0000-4000-8000-000000000001'),
  '{}'
) as result;

select is((select result #>> '{data,bound}' from reviewer_profile_version_result), 'false',
  'new version can be published without rebinding');
select is(
  (select count(*)::text from public.contacts
   where id = '72400000-0000-4000-8000-000000000101' and state_code = 100),
  '2',
  'both reviewer profile versions are open data'
);
select is(
  (select contact->>'@version' from private.users where id = '72400000-0000-4000-8000-000000000001'),
  (select result #>> '{data,contact,@version}' from reviewer_profile_result),
  'publish-only keeps the previous reviewer profile bound'
);
select is(
  api.cmd_review_contact_activate(
    'createVersion', '72400000-0000-4000-8000-000000000101',
    (select json_ordered::jsonb from public.contacts
     where id = '72400000-0000-4000-8000-000000000101'
       and version = (select contact->>'@version' from private.users
                      where id = '72400000-0000-4000-8000-000000000001')),
    '72400000-0000-4000-8000-000000000203', '99.99.999', true,
    (select contact from private.users where id = '72400000-0000-4000-8000-000000000001'), '{}'
  )->>'code',
  'REVIEWER_CONTACT_SOURCE_INVALID',
  'version creation is fenced to the currently bound source'
);

select * from finish();
rollback;
