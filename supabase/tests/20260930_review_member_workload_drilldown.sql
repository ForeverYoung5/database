begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;

select plan(12);

select ok(
  pg_catalog.to_regprocedure('api.qry_review_get_member_workload_items_v1(uuid,text,integer,integer,text,text,text,text,text)') is not null,
  'review member workload detail RPC exists'
);

select is(
  pg_catalog.has_function_privilege(
    'authenticated',
    'private.review_member_workload_classification_v1(uuid)',
    'execute'
  ),
  false,
  'shared workload classification remains private'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
)
values
  ('00000000-0000-0000-0000-000000000000', '19630000-0000-0000-0000-000000000001',
    'authenticated', 'authenticated', 'workload-admin@example.com', 'test', now(),
    '{"provider":"email","providers":["email"]}', '{"email":"workload-admin@example.com"}',
    now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', '19630000-0000-0000-0000-000000000002',
    'authenticated', 'authenticated', 'workload-reviewer-a@example.com', 'test', now(),
    '{"provider":"email","providers":["email"]}', '{"email":"workload-reviewer-a@example.com"}',
    now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', '19630000-0000-0000-0000-000000000003',
    'authenticated', 'authenticated', 'workload-reviewer-b@example.com', 'test', now(),
    '{"provider":"email","providers":["email"]}', '{"email":"workload-reviewer-b@example.com"}',
    now(), now(), false, false);

insert into private.users (id, raw_user_meta_data)
values
  ('19630000-0000-0000-0000-000000000001', '{"email":"workload-admin@example.com"}'),
  ('19630000-0000-0000-0000-000000000002', '{"email":"workload-reviewer-a@example.com"}'),
  ('19630000-0000-0000-0000-000000000003', '{"email":"workload-reviewer-b@example.com"}')
on conflict (id) do update set raw_user_meta_data = excluded.raw_user_meta_data;

insert into private.roles (user_id, team_id, role)
values
  ('19630000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'review-admin'),
  ('19630000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'review-member'),
  ('19630000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'review-member');

insert into private.reviews (
  id, data_id, data_version, state_code, reviewer_id, json,
  review_kind, target_table, submitted_revision_checksum, target_owner_id
)
values
  ('59630000-0000-0000-0000-000000000001', '49630000-0000-0000-0000-000000000001',
    '01.00.000', 1, '["19630000-0000-0000-0000-000000000002"]',
    '{"data":{"id":"49630000-0000-0000-0000-000000000001","version":"01.00.000","table":"processes"},"logs":[]}',
    'root', 'processes', pg_catalog.repeat('1', 64), '19630000-0000-0000-0000-000000000001'),
  ('59630000-0000-0000-0000-000000000002', '49630000-0000-0000-0000-000000000002',
    '01.00.000', 1, '["19630000-0000-0000-0000-000000000002"]',
    '{"data":{"id":"49630000-0000-0000-0000-000000000002","version":"01.00.000","table":"processes"},"logs":[]}',
    'root', 'processes', pg_catalog.repeat('2', 64), '19630000-0000-0000-0000-000000000001'),
  ('59630000-0000-0000-0000-000000000003', '49630000-0000-0000-0000-000000000003',
    '01.00.000', -1, '["19630000-0000-0000-0000-000000000002"]',
    '{"data":{"id":"49630000-0000-0000-0000-000000000003","version":"01.00.000","table":"processes"},"logs":[]}',
    'reference', 'processes', pg_catalog.repeat('3', 64), '19630000-0000-0000-0000-000000000001'),
  ('59630000-0000-0000-0000-000000000004', '49630000-0000-0000-0000-000000000004',
    '01.00.000', 1, '["19630000-0000-0000-0000-000000000003"]',
    '{"data":{"id":"49630000-0000-0000-0000-000000000004","version":"01.00.000","table":"processes"},"logs":[]}',
    'root', 'processes', pg_catalog.repeat('4', 64), '19630000-0000-0000-0000-000000000001'),
  ('59630000-0000-0000-0000-000000000005', '49630000-0000-0000-0000-000000000005',
    '01.00.000', 1, '["19630000-0000-0000-0000-000000000003"]',
    '{"data":{"id":"49630000-0000-0000-0000-000000000005","version":"01.00.000","table":"processes"},"logs":[]}',
    'root', 'processes', pg_catalog.repeat('5', 64), '19630000-0000-0000-0000-000000000001'),
  ('59630000-0000-0000-0000-000000000006', '49630000-0000-0000-0000-000000000006',
    '01.00.000', 2, '["19630000-0000-0000-0000-000000000002"]',
    '{"data":{"id":"49630000-0000-0000-0000-000000000006","version":"01.00.000","table":"processes"},"logs":[]}',
    'root', 'processes', pg_catalog.repeat('6', 64), '19630000-0000-0000-0000-000000000001');

insert into private.comments (review_id, reviewer_id, json, state_code)
values
  ('59630000-0000-0000-0000-000000000001', '19630000-0000-0000-0000-000000000002', '{}', 0),
  ('59630000-0000-0000-0000-000000000002', '19630000-0000-0000-0000-000000000002', '{"decision":"approve"}', 1),
  ('59630000-0000-0000-0000-000000000003', '19630000-0000-0000-0000-000000000002', '{"decision":"reject","reason":"Needs changes"}', -3),
  ('59630000-0000-0000-0000-000000000004', '19630000-0000-0000-0000-000000000003', '{}', 0),
  ('59630000-0000-0000-0000-000000000005', '19630000-0000-0000-0000-000000000002', '{}', 0),
  ('59630000-0000-0000-0000-000000000006', '19630000-0000-0000-0000-000000000002', '{}', -1);

update private.comments
set state_code = -1
where review_id = '59630000-0000-0000-0000-000000000003';

reset role;
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '19630000-0000-0000-0000-000000000001', true);

select is(
  (
    select pg_catalog.format('%s/%s', pending_count, reviewed_count)
    from api.qry_review_get_member_workload(1, 20, 'created_at', 'desc', 'review-member')
    where user_id = '19630000-0000-0000-0000-000000000002'
  ),
  '1/2',
  'summary counts one current draft and two durable submitted decisions'
);

select is(
  (
    select count(*)::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000002', 'pending', 1, 50,
      'modified_at', 'desc', 'all', null, null
    )
  ),
  '1',
  'pending detail has the same count as the summary'
);

select is(
  (
    select id::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000002', 'pending', 1, 50,
      'modified_at', 'desc', 'all', null, null
    )
  ),
  '59630000-0000-0000-0000-000000000001',
  'pending detail excludes a draft after reviewer assignment was removed'
);

select is(
  (
    select count(*)::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000002', 'reviewed', 1, 50,
      'modified_at', 'desc', 'all', null, null
    )
  ),
  '2',
  'reviewed detail has the same count as the summary'
);

select results_eq(
  $$
    select id::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000002', 'reviewed', 1, 50,
      'created_at', 'asc', 'all', null, null
    )
    order by id
  $$,
  $$values
    ('59630000-0000-0000-0000-000000000002'::text),
    ('59630000-0000-0000-0000-000000000003'::text)
  $$,
  'reviewed detail includes active and terminal submitted work but not an unsubmitted terminal row'
);

select is(
  (
    select actor_has_rejection_info::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000002', 'reviewed', 1, 50,
      'modified_at', 'desc', 'all', null, null
    )
    where id = '59630000-0000-0000-0000-000000000003'
  ),
  'true',
  'administrator drill-down reports rejection information for the selected reviewer'
);

select set_config('request.jwt.claim.sub', '19630000-0000-0000-0000-000000000002', true);

select is(
  (
    select count(*)::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000003', 'pending', 1, 50,
      'modified_at', 'desc', 'all', null, null
    )
  ),
  '0',
  'review members cannot inspect another reviewer workload'
);

select set_config('request.jwt.claim.sub', '19630000-0000-0000-0000-000000000001', true);

select is(
  (
    select count(*)::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000099', 'pending', 1, 50,
      'modified_at', 'desc', 'all', null, null
    )
  ),
  '0',
  'unknown reviewer workload remains hidden'
);

select is(
  (
    select count(*)::text
    from api.qry_review_get_member_workload_items_v1(
      '19630000-0000-0000-0000-000000000002', 'invalid', 1, 50,
      'modified_at', 'desc', 'all', null, null
    )
  ),
  '0',
  'unknown workload status fails closed'
);

reset role;

select is(
  (
    select capability_id
    from private.api_capability_grants
    where routine_identity = 'api.qry_review_get_member_workload_items_v1(uuid, text, integer, integer, text, text, text, text, text)'
  ),
  'NX-REV-01',
  'workload detail RPC is registered under the review capability'
);

select * from finish();
rollback;
