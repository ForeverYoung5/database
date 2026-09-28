begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;

select plan(20);

select ok(
  pg_catalog.to_regprocedure('api.qry_review_get_rejection_details_v1(uuid)') is not null,
  'permission-scoped rejection details RPC exists'
);
select ok(
  pg_catalog.to_regprocedure('api.qry_review_get_admin_queue_items_v6(text,integer,integer,text,text,text,text,text)') is not null,
  'admin queue V6 exists'
);
select ok(
  pg_catalog.to_regprocedure('api.qry_review_get_member_queue_items_v6(text,integer,integer,text,text,text,text,text)') is not null,
  'member queue V6 exists'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
)
values
  ('00000000-0000-0000-0000-000000000000', '19628000-0000-0000-0000-000000000001',
    'authenticated', 'authenticated', 'rejection-admin@example.com', 'test', now(),
    '{"provider":"email","providers":["email"]}', '{"email":"rejection-admin@example.com"}',
    now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', '19628000-0000-0000-0000-000000000002',
    'authenticated', 'authenticated', 'rejection-reviewer-a@example.com', 'test', now(),
    '{"provider":"email","providers":["email"]}', '{"email":"rejection-reviewer-a@example.com"}',
    now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', '19628000-0000-0000-0000-000000000003',
    'authenticated', 'authenticated', 'rejection-reviewer-b@example.com', 'test', now(),
    '{"provider":"email","providers":["email"]}', '{"email":"rejection-reviewer-b@example.com"}',
    now(), now(), false, false);

insert into private.users (id, raw_user_meta_data)
values
  ('19628000-0000-0000-0000-000000000001', '{"email":"rejection-admin@example.com"}'),
  ('19628000-0000-0000-0000-000000000002', '{"email":"rejection-reviewer-a@example.com"}'),
  ('19628000-0000-0000-0000-000000000003', '{"email":"rejection-reviewer-b@example.com"}')
on conflict (id) do update set raw_user_meta_data = excluded.raw_user_meta_data;

insert into private.roles (user_id, team_id, role)
values
  ('19628000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'review-admin'),
  ('19628000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'review-member'),
  ('19628000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'review-member');

insert into private.reviews (
  id, data_id, data_version, state_code, reviewer_id, json,
  review_kind, target_table, submitted_revision_checksum, target_owner_id
)
values
  (
    '59628000-0000-0000-0000-000000000001', '49628000-0000-0000-0000-000000000001',
    '01.00.000', 1,
    '["19628000-0000-0000-0000-000000000002","19628000-0000-0000-0000-000000000003"]',
    '{"data":{"id":"49628000-0000-0000-0000-000000000001","version":"01.00.000","table":"processes"},"logs":[]}',
    'root', 'processes', pg_catalog.repeat('1', 64), '19628000-0000-0000-0000-000000000001'
  ),
  (
    '59628000-0000-0000-0000-000000000002', '49628000-0000-0000-0000-000000000002',
    '01.00.000', -1,
    '["19628000-0000-0000-0000-000000000002","19628000-0000-0000-0000-000000000003"]',
    '{"data":{"id":"49628000-0000-0000-0000-000000000002","version":"01.00.000","table":"processes"},"comment":{"message":"Admin final reason"},"logs":[{"action":"rejected","time":"2026-09-28T10:00:00Z","user":{"id":"19628000-0000-0000-0000-000000000001"}}]}',
    'root', 'processes', pg_catalog.repeat('2', 64), '19628000-0000-0000-0000-000000000001'
  ),
  (
    '59628000-0000-0000-0000-000000000003', '49628000-0000-0000-0000-000000000003',
    '01.00.000', 2,
    '["19628000-0000-0000-0000-000000000002"]',
    '{"data":{"id":"49628000-0000-0000-0000-000000000003","version":"01.00.000","table":"processes"},"logs":[]}',
    'root', 'processes', pg_catalog.repeat('3', 64), '19628000-0000-0000-0000-000000000001'
  );

insert into private.comments (review_id, reviewer_id, json, state_code)
values
  ('59628000-0000-0000-0000-000000000001', '19628000-0000-0000-0000-000000000002', '{"comment":{"message":"Active reviewer reason"}}', -3),
  ('59628000-0000-0000-0000-000000000001', '19628000-0000-0000-0000-000000000003', '{"comment":{"message":"Looks good"}}', 1),
  ('59628000-0000-0000-0000-000000000002', '19628000-0000-0000-0000-000000000002', '{"reason":"Terminal reviewer reason","decision":"reject"}', -3),
  ('59628000-0000-0000-0000-000000000002', '19628000-0000-0000-0000-000000000003', '{"decision":"approve"}', 1),
  ('59628000-0000-0000-0000-000000000003', '19628000-0000-0000-0000-000000000002', '{"comment":{"message":"Rejected before final approval"}}', -3);

-- Reproduce the retained Dev shape that blocked the original migration: a
-- legacy review has review_kind = null and its submitted decision must be
-- backfilled only through the explicit migration context.
select set_config('app.review_legacy_migration', 'on', true);

insert into private.reviews (
  id, data_id, data_version, state_code, reviewer_id, json,
  review_kind, target_table, submitted_revision_checksum, target_owner_id
)
values (
  '59628000-0000-0000-0000-000000000004', '49628000-0000-0000-0000-000000000004',
  '01.00.000', 1,
  '["19628000-0000-0000-0000-000000000002"]',
  '{"data":{"id":"49628000-0000-0000-0000-000000000004","version":"01.00.000","table":"processes"},"logs":[]}',
  null, 'processes', pg_catalog.repeat('4', 64), '19628000-0000-0000-0000-000000000001'
);

insert into private.comments (review_id, reviewer_id, json, state_code)
values (
  '59628000-0000-0000-0000-000000000004',
  '19628000-0000-0000-0000-000000000002',
  '{"comment":{"message":"Legacy reviewer reason"}}',
  0
);

update private.comments
set state_code = -3
where review_id = '59628000-0000-0000-0000-000000000004';

update private.comments
set submitted_decision = null,
    submitted_decision_at = null
where review_id = '59628000-0000-0000-0000-000000000004';

select set_config('app.review_legacy_migration', 'off', true);

select throws_ok(
  $test$
    update private.comments
    set submitted_decision = 'reject',
        submitted_decision_at = modified_at
    where review_id = '59628000-0000-0000-0000-000000000004'
  $test$,
  '55000',
  'LEGACY_REVIEW_READ_ONLY',
  'legacy review comments remain read-only outside migration context'
);

select set_config('app.review_legacy_migration', 'on', true);

update private.comments
set submitted_decision = 'reject',
    submitted_decision_at = modified_at
where review_id = '59628000-0000-0000-0000-000000000004';

select set_config('app.review_legacy_migration', 'off', true);

select is(
  (select submitted_decision from private.comments where review_id = '59628000-0000-0000-0000-000000000004'),
  'reject',
  'migration context backfills a legacy reviewer decision'
);

select ok(
  pg_catalog.current_setting('app.review_legacy_migration', true) is distinct from 'on',
  'legacy migration bypass is disabled after the backfill'
);

select throws_ok(
  $test$
    update private.comments
    set json = '{"comment":{"message":"Mutation must stay blocked"}}'
    where review_id = '59628000-0000-0000-0000-000000000004'
  $test$,
  '55000',
  'LEGACY_REVIEW_READ_ONLY',
  'legacy review protection is restored after the backfill'
);

update private.comments set state_code = -1 where review_id = '59628000-0000-0000-0000-000000000002';
update private.comments set state_code = 2 where review_id = '59628000-0000-0000-0000-000000000003';

select is(
  (select submitted_decision from private.comments where review_id = '59628000-0000-0000-0000-000000000001' and reviewer_id = '19628000-0000-0000-0000-000000000002'),
  'reject',
  'rejection submission stores its stable decision'
);
select is(
  (select submitted_decision from private.comments where review_id = '59628000-0000-0000-0000-000000000002' and reviewer_id = '19628000-0000-0000-0000-000000000002'),
  'reject',
  'admin finalization state preserves the reviewer decision'
);
select is(
  (select submitted_decision from private.comments where review_id = '59628000-0000-0000-0000-000000000003' and reviewer_id = '19628000-0000-0000-0000-000000000002'),
  'reject',
  'final approval also preserves a reviewer rejection'
);

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '19628000-0000-0000-0000-000000000001', true);

select is(
  (select has_rejection_info::text from api.qry_review_get_admin_queue_items_v6('in-progress', 1, 50, 'modified_at', 'desc') where id = '59628000-0000-0000-0000-000000000001'),
  'true',
  'admin in-progress queue exposes rejection availability'
);
select is(
  (select has_rejection_info::text from api.qry_review_get_admin_queue_items_v6('completed', 1, 50, 'modified_at', 'desc') where id = '59628000-0000-0000-0000-000000000003'),
  'true',
  'admin completed queue exposes reviewer rejection even after final approval'
);
select is(
  (select count(*)::text from api.qry_review_get_rejection_details_v1('59628000-0000-0000-0000-000000000002')),
  '2',
  'admin sees the final admin reason and reviewer rejection'
);
select is(
  (select reason from api.qry_review_get_rejection_details_v1('59628000-0000-0000-0000-000000000002') where source = 'review-admin'),
  'Admin final reason',
  'admin final reason is returned'
);

select set_config('request.jwt.claim.sub', '19628000-0000-0000-0000-000000000002', true);

select is(
  (select actor_has_rejection_info::text from api.qry_review_get_member_queue_items_v6('submitted', 1, 50, 'modified_at', 'desc') where id = '59628000-0000-0000-0000-000000000001'),
  'true',
  'rejecting reviewer submitted queue exposes own rejection availability'
);
select is(
  (select count(*)::text from api.qry_review_get_rejection_details_v1('59628000-0000-0000-0000-000000000002')),
  '1',
  'reviewer sees only their own terminal rejection reason'
);
select is(
  (select reason from api.qry_review_get_rejection_details_v1('59628000-0000-0000-0000-000000000002')),
  'Terminal reviewer reason',
  'reviewer terminal reason remains readable'
);

select set_config('request.jwt.claim.sub', '19628000-0000-0000-0000-000000000003', true);

select is(
  (select actor_has_rejection_info::text from api.qry_review_get_member_queue_items_v6('completed', 1, 50, 'modified_at', 'desc') where id = '59628000-0000-0000-0000-000000000002'),
  'false',
  'approving reviewer does not get a rejection icon for another reviewer or admin'
);
select is(
  (select count(*)::text from api.qry_review_get_rejection_details_v1('59628000-0000-0000-0000-000000000002')),
  '0',
  'approving reviewer cannot read another reviewer or admin rejection reason'
);

update private.comments
set state_code = 0
where review_id = '59628000-0000-0000-0000-000000000001'
  and reviewer_id = '19628000-0000-0000-0000-000000000002';
select is(
  (select submitted_decision from private.comments where review_id = '59628000-0000-0000-0000-000000000001' and reviewer_id = '19628000-0000-0000-0000-000000000002'),
  null,
  'reopening a submitted opinion as draft clears stable decision metadata'
);

select * from finish();
rollback;
