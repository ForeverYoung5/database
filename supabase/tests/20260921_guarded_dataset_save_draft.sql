begin;

-- Database #670 / workspace #1432: atomic before-content guard for owner-draft saves.
--
-- The guarded facade must lock the exact draft row, re-derive the fresh actor, require
-- owner state-0, compare the complete stored before image with the caller's expected
-- JSON value, and only then delegate to the existing api.cmd_dataset_save_draft writer
-- inside the same transaction. It adds no write, trigger or audit logic and grants no
-- new authority: foreign, reviewed, published, example, nonexistent and malformed
-- inputs fail closed with no primary change and no write audit.
--
-- Cross-session interleaving is proven separately by
-- supabase/tests/regression/20260921_guarded_dataset_save_draft_concurrency.sh.

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;

select plan(53);

-- ---------------------------------------------------------------------------
-- Fixtures. Versions are derived from the dataset JSON by the table's own sync
-- trigger, so every literal carries common:dataSetVersion.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, is_sso_user, is_anonymous
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    '67000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'guard-owner@example.com', 'test-password-hash',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"sub":"67000000-0000-4000-8000-000000000001","email":"guard-owner@example.com"}'::jsonb,
    now(), now(), false, false
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '67000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'guard-outsider@example.com', 'test-password-hash',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"sub":"67000000-0000-4000-8000-000000000002","email":"guard-outsider@example.com"}'::jsonb,
    now(), now(), false, false
  );

insert into public.contacts (id, version, json_ordered, user_id, state_code, team_id, rule_verification)
values
  -- g1: guarded happy path
  ('67000000-0000-4000-8000-0000000000a1', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","tags":["a","b"],"count":1.0}}'::json,
   '67000000-0000-4000-8000-000000000001', 0, null, true),
  -- g2: stale expected before image
  ('67000000-0000-4000-8000-0000000000a2', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","tags":["a","b"],"count":1.0}}'::json,
   '67000000-0000-4000-8000-000000000001', 0, null, true),
  -- g3: array order differs in the expected before image
  ('67000000-0000-4000-8000-0000000000a3', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","tags":["a","b"],"count":1.0}}'::json,
   '67000000-0000-4000-8000-000000000001', 0, null, true),
  -- g4: JSON-value-equivalent before image (numeric scale, object key order, whitespace)
  ('67000000-0000-4000-8000-0000000000a4', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","tags":["a","b"],"count":1.0}}'::json,
   '67000000-0000-4000-8000-000000000001', 0, null, true),
  -- g5: extra key in the expected before image
  ('67000000-0000-4000-8000-0000000000a5', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft"}}'::json,
   '67000000-0000-4000-8000-000000000001', 0, null, true),
  -- g6: under review
  ('67000000-0000-4000-8000-0000000000a6', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-review"}}'::json,
   '67000000-0000-4000-8000-000000000001', 20, null, true),
  -- g7: published
  ('67000000-0000-4000-8000-0000000000a7', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-published"}}'::json,
   '67000000-0000-4000-8000-000000000001', 100, null, true),
  -- g8: example dataset
  ('67000000-0000-4000-8000-0000000000a8', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-example"}}'::json,
   '67000000-0000-4000-8000-000000000001', -1, null, true),
  -- g9: legacy contacts state 3
  ('67000000-0000-4000-8000-0000000000a9', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-state3"}}'::json,
   '67000000-0000-4000-8000-000000000001', 3, null, true),
  -- g10: foreign owner
  ('67000000-0000-4000-8000-0000000000b1', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-foreign"}}'::json,
   '67000000-0000-4000-8000-000000000002', 0, null, true),
  -- g11: legacy compatibility row
  ('67000000-0000-4000-8000-0000000000b2', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-legacy"}}'::json,
   '67000000-0000-4000-8000-000000000001', 0, null, true),
  -- g12: owner draft whose state_code is unknown (NULL); the column is nullable by design,
  -- so the guarded path must refuse it instead of treating it as a draft
  ('67000000-0000-4000-8000-0000000000b3', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-unknown-state"}}'::json,
   '67000000-0000-4000-8000-000000000001', null, null, true),
  -- g13: sentinel for every invalid-input call that must leave the primary row alone
  ('67000000-0000-4000-8000-0000000000b4', '01.00.000',
   '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-sentinel"}}'::json,
   '67000000-0000-4000-8000-000000000001', 0, null, true);

-- ---------------------------------------------------------------------------
-- Contract, ACL and capability-manifest closure.
-- ---------------------------------------------------------------------------

select has_function(
  'api',
  'cmd_dataset_save_draft_guarded',
  array['text', 'uuid', 'text', 'jsonb', 'jsonb', 'uuid', 'boolean', 'jsonb', 'text'],
  'guarded draft-save facade exists with the exact expected-before signature'
);

select is(
  (
    select count(*)
    from pg_proc as routine
    join pg_namespace as namespace on namespace.oid = routine.pronamespace
    where namespace.nspname = 'api'
      and routine.proname = 'cmd_dataset_save_draft_guarded'
  ),
  1::bigint,
  'the guarded facade has no default-overload ambiguity'
);

select ok(
  (
    select routine.prosecdef
      and routine.proconfig = array['search_path=api, private, public, util, extensions, pg_temp']::text[]
      and pg_get_userbyid(routine.proowner) = 'postgres'
    from pg_proc as routine
    where routine.oid =
      'api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)'::regprocedure
  ),
  'the guarded facade is SECURITY DEFINER, postgres-owned, with the writer''s fixed search path'
);

select is(
  (
    select count(*)
    from pg_proc as routine
    cross join lateral aclexplode(coalesce(routine.proacl, acldefault('f', routine.proowner))) as acl
    where routine.oid =
      'api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)'::regprocedure
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ),
  0::bigint,
  'the guarded facade is not executable through the PostgreSQL PUBLIC role'
);

select ok(
  has_function_privilege(
    'authenticated',
    'api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)',
    'EXECUTE'
  )
    and not has_function_privilege(
      'anon',
      'api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)',
      'EXECUTE'
    )
    and not has_function_privilege(
      'service_role',
      'api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)',
      'EXECUTE'
    ),
  'only the authenticated actor role receives the guarded draft-save ACL'
);

select is(
  (
    select concat_ws(
      ':',
      manifest.capability_id,
      manifest.allow_anon::text,
      manifest.allow_authenticated::text,
      manifest.allow_service_role::text
    )
    from private.api_capability_grants as manifest
    where manifest.routine_identity =
      'api.cmd_dataset_save_draft_guarded(text, uuid, text, jsonb, jsonb, uuid, boolean, jsonb, text)'
  ),
  'DB-CORE-WRITE-01:false:true:false'::text,
  'the guarded facade reuses only the existing owner-draft write capability'
);

select is(
  (
    select format(
      '%I.%I(%s)', namespace.nspname, routine.proname,
      pg_catalog.oidvectortypes(routine.proargtypes)
    )
    from pg_proc as routine
    join pg_namespace as namespace on namespace.oid = routine.pronamespace
    where routine.oid =
      'api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)'::regprocedure
  ),
  'api.cmd_dataset_save_draft_guarded(text, uuid, text, jsonb, jsonb, uuid, boolean, jsonb, text)'::text,
  'the manifest routine identity matches the exact catalog signature'
);

select is(
  (
    select count(*)
    from private.api_capability_grants as manifest
    where manifest.routine_identity like 'api.cmd_dataset_save_draft_guarded%'
  ),
  1::bigint,
  'the guarded facade has exactly one capability manifest entry'
);

-- ---------------------------------------------------------------------------
-- Owner success path.
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"67000000-0000-4000-8000-000000000001"}',
  true
);
select set_config('request.jwt.claim.sub', '67000000-0000-4000-8000-000000000001', true);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a1',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guarded-write"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","tags":["a","b"],"count":1.0}}'::jsonb,
    null,
    false,
    '{"command":"dataset_save_draft","guarded":true}'::jsonb,
    null
  )->>'ok',
  'true'::text,
  'the owner can save exactly matching before content through the guarded facade'
);

reset role;

select is(
  (
    select json_ordered->'payload'->>'name'
    from public.contacts
    where id = '67000000-0000-4000-8000-0000000000a1'
      and version = '01.00.000'
  ),
  'guarded-write'::text,
  'the guarded facade writes the desired content through the existing writer'
);

select is(
  (
    select rule_verification
    from public.contacts
    where id = '67000000-0000-4000-8000-0000000000a1'
      and version = '01.00.000'
  ),
  false,
  'the guarded facade forwards the existing rule-verification field'
);

select is(
  (
    select count(*)
    from private.command_audit_log
    where command = 'cmd_dataset_save_draft'
      and target_id = '67000000-0000-4000-8000-0000000000a1'
  ),
  1::bigint,
  'a guarded save produces exactly one existing writer audit entry'
);

select is(
  (
    select payload->>'guarded'
    from private.command_audit_log
    where command = 'cmd_dataset_save_draft'
      and target_id = '67000000-0000-4000-8000-0000000000a1'
  ),
  'true'::text,
  'the guarded save forwards the caller audit payload unchanged'
);

-- ---------------------------------------------------------------------------
-- Before-image drift is rejected without any write.
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '67000000-0000-4000-8000-000000000001', true);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"stale-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"something-else","tags":["a","b"],"count":1.0}}'::jsonb
  )->>'code',
  'DATASET_BEFORE_CONTENT_CHANGED'::text,
  'a stale before image is refused with a stable conflict code'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"payload":{"name":"stale-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"something-else"}}'::jsonb
  )->>'status',
  '409'::text,
  'the stale before image conflict reports HTTP 409'
);

select ok(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"payload":{"name":"stale-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"something-else"}}'::jsonb
  ) ? 'details' = false,
  'the conflict response discloses no stored payload details'
);

reset role;

select is(
  (
    select json_ordered->'payload'->>'name'
    from public.contacts
    where id = '67000000-0000-4000-8000-0000000000a2'
      and version = '01.00.000'
  ),
  'guard-draft'::text,
  'a refused stale before image leaves the primary row unchanged'
);

select is(
  (
    select count(*)
    from private.command_audit_log
    where command = 'cmd_dataset_save_draft'
      and target_id = '67000000-0000-4000-8000-0000000000a2'
  ),
  0::bigint,
  'a refused stale before image writes no successful write audit'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '67000000-0000-4000-8000-000000000001', true);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a3',
    '01.00.000',
    '{"payload":{"name":"array-order-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","tags":["b","a"],"count":1.0}}'::jsonb
  )->>'code',
  'DATASET_BEFORE_CONTENT_CHANGED'::text,
  'a reordered JSON array is not an equal before image under PostgreSQL JSON semantics'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a5',
    '01.00.000',
    '{"payload":{"name":"extra-key-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","extra":true}}'::jsonb
  )->>'code',
  'DATASET_BEFORE_CONTENT_CHANGED'::text,
  'an expected before image with an extra key is not equal and is refused'
);

-- JSON value equality: numeric scale, object key order and whitespace are equal.
select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a4',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"equivalent-write"}}'::jsonb,
    '{
       "payload": {"count": 1.00, "tags": ["a", "b"], "name": "guard-draft"},
       "contactDataSet": {"administrativeInformation": {"publicationAndOwnership": {"common:dataSetVersion": "01.00.000"}}}
     }'::jsonb
  )->>'ok',
  'true'::text,
  'numeric scale, object key order and whitespace do not change JSON value equality'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a5',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"missing-key-overwrite"}}'::jsonb,
    '{"payload":{"name":"guard-draft"}}'::jsonb
  )->>'code',
  'DATASET_BEFORE_CONTENT_CHANGED'::text,
  'a before image that is a strict subset of the stored content stays unequal'
);

-- ---------------------------------------------------------------------------
-- No new authority: ownership, review/publication, example and state guards.
-- ---------------------------------------------------------------------------

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000b1',
    '01.00.000',
    '{"payload":{"name":"foreign-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-foreign"}}'::jsonb
  )->>'code',
  'DATASET_OWNER_REQUIRED'::text,
  'a non-owner cannot use the guard even with an exactly matching before image'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000b1',
    '01.00.000',
    '{"payload":{"name":"foreign-overwrite"}}'::jsonb,
    '{"payload":{"name":"wrong-before"}}'::jsonb
  )->>'code',
  'DATASET_OWNER_REQUIRED'::text,
  'ownership is decided before any before-image comparison'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a6',
    '01.00.000',
    '{"payload":{"name":"review-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-review"}}'::jsonb
  )->>'code',
  'DATA_UNDER_REVIEW'::text,
  'a review-state draft stays closed to the guarded path'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a7',
    '01.00.000',
    '{"payload":{"name":"published-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-published"}}'::jsonb
  )->>'code',
  'DATA_ALREADY_PUBLISHED'::text,
  'a published draft stays closed to the guarded path'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a8',
    '01.00.000',
    '{"payload":{"name":"example-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-example"}}'::jsonb
  )->>'code',
  'DATASET_STATE_NOT_DRAFT'::text,
  'an example dataset is refused as a non-editable owner draft'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a9',
    '01.00.000',
    '{"payload":{"name":"state3-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-state3"}}'::jsonb
  )->>'code',
  'DATASET_STATE_NOT_DRAFT'::text,
  'the guarded path is strictly owner state-0'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000ff',
    '01.00.000',
    '{"payload":{"name":"missing-overwrite"}}'::jsonb,
    '{"payload":{"name":"missing"}}'::jsonb
  )->>'code',
  'DATASET_NOT_FOUND'::text,
  'a nonexistent target fails closed without a write'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'teams',
    '67000000-0000-4000-8000-0000000000a1',
    '01.00.000',
    '{"payload":{"name":"invalid-table"}}'::jsonb,
    '{"payload":{"name":"guard-draft"}}'::jsonb
  )->>'code',
  'INVALID_DATASET_TABLE'::text,
  'an unsupported table name is refused before any row access'
);

-- ---------------------------------------------------------------------------
-- Expected-before input shape and delegation of writer validation.
-- ---------------------------------------------------------------------------

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"payload":{"name":"null-before"}}'::jsonb,
    null
  )->>'code',
  'DATASET_BEFORE_CONTENT_REQUIRED'::text,
  'a null expected before image is refused'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"payload":{"name":"array-before"}}'::jsonb,
    '["payload"]'::jsonb
  )->>'code',
  'DATASET_BEFORE_CONTENT_REQUIRED'::text,
  'a non-object expected before image is refused'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"payload":{"name":"scalar-before"}}'::jsonb,
    '"payload"'::jsonb
  )->>'code',
  'DATASET_BEFORE_CONTENT_REQUIRED'::text,
  'a scalar expected before image is refused'
);

select throws_ok(
  $sql$
    select api.cmd_dataset_save_draft_guarded(
      p_table := 'contacts',
      p_id := '67000000-0000-4000-8000-0000000000a2',
      p_version := '01.00.000',
      p_json_ordered := '{"payload":{"name":"omitted-before"}}'::jsonb
    )
  $sql$,
  '42883',
  null,
  'an omitted expected before image cannot resolve the guarded facade at all'
);

reset role;

select is(
  (
    select count(*)
    from private.command_audit_log
    where target_id in (
      '67000000-0000-4000-8000-0000000000a2',
      '67000000-0000-4000-8000-0000000000a3',
      '67000000-0000-4000-8000-0000000000a5',
      '67000000-0000-4000-8000-0000000000a6',
      '67000000-0000-4000-8000-0000000000a7',
      '67000000-0000-4000-8000-0000000000a8',
      '67000000-0000-4000-8000-0000000000a9',
      '67000000-0000-4000-8000-0000000000b1'
    )
  ),
  0::bigint,
  'no rejected guarded call produced a write audit'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '67000000-0000-4000-8000-000000000001', true);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"model-id-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-draft","tags":["a","b"],"count":1.0}}'::jsonb,
    '33333333-3333-4333-8333-333333333333'
  )->>'code',
  'MODEL_ID_NOT_ALLOWED'::text,
  'the guarded facade delegates existing writer validation instead of copying it'
);

-- Unauthenticated sessions cannot reach the guarded path at all.
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '', true);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000a2',
    '01.00.000',
    '{"payload":{"name":"anonymous-overwrite"}}'::jsonb,
    '{"payload":{"name":"guard-draft","tags":["a","b"],"count":1.0}}'::jsonb
  )->>'code',
  'AUTH_REQUIRED'::text,
  'a session without a verified actor fails closed'
);

-- ---------------------------------------------------------------------------
-- Invalid target shapes, unknown draft state and capability closure.
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"67000000-0000-4000-8000-000000000001"}',
  true
);
select set_config('request.jwt.claim.sub', '67000000-0000-4000-8000-000000000001', true);

-- A NULL table name must fail closed with the stable invalid-input code instead of
-- raising while the dynamic statement is formatted.
select is(
  api.cmd_dataset_save_draft_guarded(
    null,
    '67000000-0000-4000-8000-0000000000b4',
    '01.00.000',
    '{"payload":{"name":"null-table-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-sentinel"}}'::jsonb
  )->>'code',
  'INVALID_DATASET_TABLE'::text,
  'a NULL table name is refused with the stable invalid-table code'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    null,
    '67000000-0000-4000-8000-0000000000b4',
    '01.00.000',
    '{"payload":{"name":"null-table-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-sentinel"}}'::jsonb
  )->>'status',
  '400'::text,
  'a NULL table name reports HTTP 400'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    null,
    '01.00.000',
    '{"payload":{"name":"null-id-overwrite"}}'::jsonb,
    '{"payload":{"name":"guard-sentinel"}}'::jsonb
  )->>'code',
  'DATASET_NOT_FOUND'::text,
  'a NULL target id fails closed as not found'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000b4',
    null,
    '{"payload":{"name":"null-version-overwrite"}}'::jsonb,
    '{"payload":{"name":"guard-sentinel"}}'::jsonb
  )->>'code',
  'DATASET_NOT_FOUND'::text,
  'a NULL target version fails closed as not found'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000b4',
    '',
    '{"payload":{"name":"empty-version-overwrite"}}'::jsonb,
    '{"payload":{"name":"guard-sentinel"}}'::jsonb
  )->>'code',
  'DATASET_NOT_FOUND'::text,
  'an empty target version fails closed as not found'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000b3',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"unknown-state-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-unknown-state"}}'::jsonb
  )->>'code',
  'DATASET_STATE_NOT_DRAFT'::text,
  'a row whose state_code is unknown is refused instead of being treated as a draft'
);

select is(
  api.cmd_dataset_save_draft_guarded(
    'contacts',
    '67000000-0000-4000-8000-0000000000b3',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"unknown-state-overwrite"}}'::jsonb,
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"guard-unknown-state"}}'::jsonb
  )->>'status',
  '403'::text,
  'an unknown draft state reports HTTP 403'
);

reset role;

-- The capability manifest identity must resolve to this exact signature for the
-- PostgREST pre-request hook, with no overload or typo standing in for it.
select is(
  (
    select to_regprocedure(manifest.routine_identity)
    from private.api_capability_grants as manifest
    where manifest.routine_identity =
      'api.cmd_dataset_save_draft_guarded(text, uuid, text, jsonb, jsonb, uuid, boolean, jsonb, text)'
  ),
  'api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)'::regprocedure,
  'the guarded capability manifest identity resolves to the exact catalog signature'
);

select is(
  (
    select json_ordered->'payload'->>'name'
    from public.contacts
    where id = '67000000-0000-4000-8000-0000000000b4'
      and version = '01.00.000'
  ),
  'guard-sentinel'::text,
  'invalid-input calls leave the primary row untouched'
);

select is(
  (
    select count(*)
    from private.command_audit_log
    where target_id = '67000000-0000-4000-8000-0000000000b4'
  ),
  0::bigint,
  'invalid-input calls write no audit entry'
);

select is(
  (
    select json_ordered->'payload'->>'name'
    from public.contacts
    where id = '67000000-0000-4000-8000-0000000000b3'
      and version = '01.00.000'
  ),
  'guard-unknown-state'::text,
  'an unknown-state row keeps its original content'
);

select is(
  (
    select count(*)
    from private.command_audit_log
    where target_id = '67000000-0000-4000-8000-0000000000b3'
  ),
  0::bigint,
  'an unknown-state refusal writes no audit entry'
);

set local role authenticated;

-- ---------------------------------------------------------------------------
-- Legacy contract is preserved unchanged.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claim.sub', '67000000-0000-4000-8000-000000000001', true);
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"67000000-0000-4000-8000-000000000001"}',
  true
);

select is(
  api.cmd_dataset_save_draft(
    'contacts',
    '67000000-0000-4000-8000-0000000000b2',
    '01.00.000',
    '{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"legacy-write"}}'::jsonb,
    null,
    true,
    '{"command":"dataset_save_draft"}'::jsonb
  )->>'ok',
  'true'::text,
  'the legacy unguarded save keeps its compatibility contract'
);

reset role;

select has_function(
  'api',
  'cmd_dataset_save_draft',
  array['text', 'uuid', 'text', 'jsonb', 'uuid', 'boolean', 'jsonb', 'text'],
  'the legacy writer keeps its exact existing signature'
);

select is(
  (
    select concat_ws(':', manifest.capability_id, manifest.allow_authenticated::text)
    from private.api_capability_grants as manifest
    where manifest.routine_identity =
      'api.cmd_dataset_save_draft(text, uuid, text, jsonb, uuid, boolean, jsonb, text)'
  ),
  'DB-CORE-WRITE-01:true'::text,
  'the legacy writer keeps its existing capability registration'
);

select is(
  (
    select count(*)
    from private.command_audit_log
    where command = 'cmd_dataset_save_draft'
      and target_id = '67000000-0000-4000-8000-0000000000b2'
  ),
  1::bigint,
  'the legacy unguarded save still writes exactly one audit entry'
);

select * from finish();

rollback;
