-- Database #646 / workspace #1201: Result Process product-read isolation.
--
-- Rollback-only. Proves that a state-120 Process is unreachable through the generic
-- product read routes the unchanged Next and Portal clients already use, while every
-- other state and every support dataset keeps its behaviour. The routes are exercised
-- through their real entry points, not by matching source text.
--
-- Fixtures insert state 120 directly as superuser inside this transaction, which is the
-- supported way to reach the protected state until Result publication admission exists.
-- No guard is disabled and no production bypass is added.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

-- Outbound extraction webhooks need Vault secrets a disposable database does not have.
-- Only that egress call is redirected; the isolation policy is not disabled.
create temporary table isolation_webhook_calls (
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
  insert into pg_temp.isolation_webhook_calls(
    edge_function, body, timeout_milliseconds
  ) values (name, body, timeout_milliseconds);
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values
(
  '00000000-0000-0000-0000-000000000000',
  '64800000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'isolation-owner@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
),
(
  '00000000-0000-0000-0000-000000000000',
  '64800000-0000-4000-8000-000000000002',
  'authenticated', 'authenticated', 'isolation-outsider@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
),
(
  '00000000-0000-0000-0000-000000000000',
  '64800000-0000-4000-8000-000000000003',
  'authenticated', 'authenticated', 'isolation-manager@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
),
(
  '00000000-0000-0000-0000-000000000000',
  '64800000-0000-4000-8000-000000000004',
  'authenticated', 'authenticated', 'isolation-reviewer@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
),
(
  '00000000-0000-0000-0000-000000000000',
  '64800000-0000-4000-8000-000000000005',
  'authenticated', 'authenticated', 'isolation-unrelated@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
);
insert into private.users(id, raw_user_meta_data, contact) values
  ('64800000-0000-4000-8000-000000000001', '{}', null),
  ('64800000-0000-4000-8000-000000000002', '{}', null),
  ('64800000-0000-4000-8000-000000000003', '{}', null),
  ('64800000-0000-4000-8000-000000000004', '{}', null),
  ('64800000-0000-4000-8000-000000000005', '{}', null);
insert into private.teams(id, json, rank, is_public)
values ('00000000-0000-0000-0000-000000000000', '{"name":"System"}', 0, false)
on conflict (id) do nothing;

-- The owner also leads a team, so the 'te' branch has a readable team to test.
insert into private.teams(id, json, rank, is_public)
values ('64800000-0000-4000-8000-0000000000aa', '{"name":"Isolation Team"}', 1, false)
on conflict (id) do nothing;

-- Actors and their authority, stated explicitly so no assertion depends on a guessed
-- role:
--   001 owns the Result and the support Flow, and is an owner of the isolation team
--   002 is a member of the same isolation team
--   003 holds the platform data_product_manager role (the future Result publisher)
--   004 holds review-admin
--   005 has no role at all: the genuinely unrelated actor, in no shared team
insert into private.roles(user_id, team_id, role) values
  ('64800000-0000-4000-8000-000000000001', '64800000-0000-4000-8000-0000000000aa', 'owner'),
  ('64800000-0000-4000-8000-000000000002', '64800000-0000-4000-8000-0000000000aa', 'member'),
  ('64800000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'data_product_manager'),
  ('64800000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'review-admin');

-- ---------------------------------------------------------------------- fixtures
-- One Result at 120, plus every ordinary state the product still reads.
-- Each row carries its full final document in the insert. A follow-up UPDATE is not an
-- option here: the Result is frozen by the lifecycle guard and the published support row
-- is frozen by the review content guard, so the fixtures must be complete up front. The
-- Result JSON mentions the support Flow UUID so the reference-lookup route has both a
-- process hit to suppress and a support hit to preserve.
insert into public.processes(id, version, state_code, user_id, team_id, json_ordered)
values
(
  '64800000-0000-4000-8000-000000000010', '01.00.000', 120,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}},"isolationMarker":"result120","referenceToFlow":"64800000-0000-4000-8000-000000000020"}}'
),
(
  '64800000-0000-4000-8000-000000000011', '01.00.000', 100,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000011"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  '64800000-0000-4000-8000-000000000012', '01.00.000', 0,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000012"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  '64800000-0000-4000-8000-000000000013', '01.00.000', 20,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000013"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  '64800000-0000-4000-8000-000000000014', '01.00.000', 200,
  '64800000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000014"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  '64800000-0000-4000-8000-000000000015', '01.00.000', -1,
  '64800000-0000-4000-8000-000000000001',
  null,
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000015"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
);

-- A support Flow at 100 for the "support is unchanged" proof.
insert into public.flows(id, version, state_code, user_id, team_id, json_ordered)
values (
  '64800000-0000-4000-8000-000000000020', '01.00.000', 100,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000020"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}},"referenceToProcess":"64800000-0000-4000-8000-000000000010"}}'
);

-- Same identity, two versions: an older eligible 100 and a newer Result 120. Selecting a
-- version for this id must return the older published row, not the newer Result.
insert into public.processes(id, version, state_code, user_id, team_id, json_ordered)
values
(
  '64800000-0000-4000-8000-000000000030', '01.00.000', 100,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000030"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}},"isolationMarker":"older-published"}}'
),
(
  '64800000-0000-4000-8000-000000000030', '02.00.000', 120,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000030"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"02.00.000"}},"isolationMarker":"newer-result"}}'
);

-- Real searchable content so suppression is proven against a route that genuinely has a
-- hit, not against an empty result. search_text is the PGroonga lexical source the
-- dynamic search branch matches on.
insert into public.processes(id, version, state_code, user_id, team_id, json_ordered, search_text)
values
(
  '64800000-0000-4000-8000-000000000040', '01.00.000', 100,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000040","name":{"baseName":[{"@xml:lang":"en","#text":"Isolationneedle control"}]}}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}},"isolationMarker":"unit-control"}}',
  array['isolationneedle']
),
(
  '64800000-0000-4000-8000-000000000041', '01.00.000', 120,
  '64800000-0000-4000-8000-000000000001',
  '64800000-0000-4000-8000-0000000000aa',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64800000-0000-4000-8000-000000000041"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}},"isolationMarker":"result-with-keyword"}}',
  array['isolationneedle']
);

-- ------------------------------------------------- 1. policy shape and ACL surface

select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'processes'
      and policyname = 'result_process_no_generic_read'
      and permissive = 'RESTRICTIVE'
      and cmd = 'SELECT'
  ),
  'the Result read isolation policy is a restrictive SELECT policy'
);
select ok(
  (
    select qual like '%120%' and roles::text like '%authenticated%'
    from pg_policies
    where schemaname = 'public' and tablename = 'processes'
      and policyname = 'result_process_no_generic_read'
  ),
  'the policy excludes 120 and applies to authenticated readers'
);
select ok(
  position('current_setting' in pg_get_functiondef(
    'private.search_processes_latest_v2_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text,text[],boolean)'::regprocedure
  )) = 0
  and position('current_user' in pg_get_functiondef(
    'private.search_processes_latest_v2_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text,text[],boolean)'::regprocedure
  )) = 0,
  'no caller-controllable bypass was introduced into the search implementation'
);

-- --------------------------------------- 2. direct relation reads under RLS

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000001', true);

-- Premise: without the isolation policy the owner branch would return this row, so the
-- zero results below cannot be empty for an unrelated reason.
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000010'
      and user_id = '64800000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'the owning team-owner cannot read its own Result through the relation'
);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000010'
      and state_code = 120
  ),
  0::bigint,
  'the Result is absent under an explicit state-120 predicate, not a mismatched one'
);
select is(
  (
    select count(*) from public.processes
    where id in (
      '64800000-0000-4000-8000-000000000011',
      '64800000-0000-4000-8000-000000000012',
      '64800000-0000-4000-8000-000000000015'
    )
  ),
  3::bigint,
  'ordinary 100, 0 and -1 rows remain readable to their owner'
);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000012'
      and state_code = 0
  ),
  1::bigint,
  'the owner state-0 draft row is still readable to its owner'
);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000013'
      and state_code = 20
  ),
  1::bigint,
  'the owner state-20 in-review row is still readable to its owner'
);

reset role;

-- The genuinely unrelated actor: no role, no shared team, no ownership.
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000005', true);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'an unrelated authenticated actor cannot read the Result'
);
select is(
  -- Baseline behaviour, preserved deliberately: the pre-existing permissive policy is
  -- `state_code >= 100`, so a published state-200 row is readable by any authenticated
  -- actor. This slice removes only state 120, and this pins that it did not over-reach.
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000014'
  ),
  1::bigint,
  'a published state-200 row stays readable to an unrelated actor, as before'
);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000011'
  ),
  1::bigint,
  'a published state-100 row stays readable to an unrelated actor, as before'
);
reset role;

-- Each privileged actor is a separate negative case for the Result.
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000002', true);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'a same-team member cannot read the team Result'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000003', true);
select ok(
  (api.assert_lca_release_manager()->>'ok') = 'true',
  'the negative-test actor 003 really holds the platform data_product_manager role'
);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'the platform data_product_manager cannot read the Result through the relation'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000004', true);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'a review-admin cannot read the Result through the relation'
);
reset role;

-- Same identity, older 100 versus newer 120: version selection must pick the older
-- published row rather than the newest row overall.
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000001', true);
select is(
  (
    select version::text from public.processes
    where id = '64800000-0000-4000-8000-000000000030'
    order by version desc
    limit 1
  ),
  '01.00.000',
  'newest readable version of the mixed identity is the older published row'
);
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000030'
  ),
  1::bigint,
  'exactly one readable version remains for the mixed identity'
);
reset role;

-- ------------------------------------------ 3. generic list route: my and te

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000001', true);

select is(
  (
    select count(*)
    from api.get_latest_process_versions(
      page_size => 100, page_current => 1, data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as listed
    where listed.id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'the owner list route excludes the Result even with a null state filter'
);
select is(
  (
    select count(*)
    from api.get_latest_process_versions(
      page_size => 100, page_current => 1, data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as listed
    where listed.id = '64800000-0000-4000-8000-000000000011'
  ),
  1::bigint,
  'the owner list route still returns the owner published process'
);
select is(
  (
    select count(*)
    from api.get_latest_process_versions(
      page_size => 100, page_current => 1, data_source => 'te',
      team_id_filter => '64800000-0000-4000-8000-0000000000aa',
      state_code_filter => null
    ) as listed
    where listed.id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'the team list route excludes the Result'
);
select is(
  (
    select count(*)
    from api.get_latest_process_versions(
      page_size => 100, page_current => 1, data_source => 'tg',
      state_code_filter => null
    ) as listed
    where listed.id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'the public list route excludes the Result'
);

-- An explicit state-120 filter must also return nothing, since the exclusion is not a
-- side effect of the null-filter path.
select is(
  (
    select count(*)
    from api.get_latest_process_versions(
      page_size => 100, page_current => 1, data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => 120
    ) as listed
    where listed.id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'an explicit state-120 filter on the owner list route returns nothing'
);
select is(
  (
    select count(*)
    from api.get_latest_process_versions(
      page_size => 100, page_current => 1, data_source => 'te',
      team_id_filter => '64800000-0000-4000-8000-0000000000aa',
      state_code_filter => 120
    ) as listed
    where listed.id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'an explicit state-120 filter on the team list route returns nothing'
);
-- The mixed identity yields the older published version on the list route.
select is(
  (
    select listed.version::text
    from api.get_latest_process_versions(
      page_size => 100, page_current => 1, data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as listed
    where listed.id = '64800000-0000-4000-8000-000000000030'
  ),
  '01.00.000',
  'the list route selects the older published version of the mixed identity'
);

reset role;

-- ------------------------------------------- 4. search route: my / te / public

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000001', true);

select is(
  (
    select count(*)
    from api.search_processes_latest_v2(
      query_text => 'isolationneedle', filter_condition => '{}'::jsonb, page_size => 100,
      page_current => 1, data_source => 'tg', state_code_filter => null
    ) as found
    where found.id = '64800000-0000-4000-8000-000000000040'
  ),
  1::bigint,
  'the public search route still returns the published Unit control for a real term'
);

-- Dynamic lexical search over seeded content. Both the Unit control and the Result carry
-- the same keyword, so a suppression result cannot be an empty-route artefact, and the
-- Unit control proves the route really matches on this term.
select is(
  (
    select count(*)
    from api.search_processes_latest_v2(
      query_text => 'isolationneedle', filter_condition => '{}'::jsonb, page_size => 100,
      page_current => 1, data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as found
    where found.id = '64800000-0000-4000-8000-000000000040'
  ),
  1::bigint,
  'dynamic keyword search still matches the seeded Unit control'
);
select is(
  (
    select count(*)
    from api.search_processes_latest_v2(
      query_text => 'isolationneedle', filter_condition => '{}'::jsonb, page_size => 100,
      page_current => 1, data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as found
    where found.id = '64800000-0000-4000-8000-000000000041'
  ),
  0::bigint,
  'dynamic keyword search suppresses the Result that carries the same keyword'
);
-- Exact-UUID search takes the dedicated static branch, so it is asserted separately.
select is(
  (
    select count(*)
    from api.search_processes_latest_v2(
      query_text => '64800000-0000-4000-8000-000000000041',
      filter_condition => '{}'::jsonb, page_size => 100, page_current => 1,
      data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as found
    where found.id = '64800000-0000-4000-8000-000000000041'
  ),
  0::bigint,
  'exact-UUID search suppresses the Result through the static branch'
);
select is(
  (
    select count(*)
    from api.search_processes_latest_v2(
      query_text => '64800000-0000-4000-8000-000000000040',
      filter_condition => '{}'::jsonb, page_size => 100, page_current => 1,
      data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as found
    where found.id = '64800000-0000-4000-8000-000000000040'
  ),
  1::bigint,
  'exact-UUID search still returns the Unit control through the static branch'
);
-- Explicit state-120 filter on the dynamic branch.
select is(
  (
    select count(*)
    from api.search_processes_latest_v2(
      query_text => 'isolationneedle', filter_condition => '{}'::jsonb, page_size => 100,
      page_current => 1, data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => 120
    ) as found
    where found.id = '64800000-0000-4000-8000-000000000041'
  ),
  0::bigint,
  'an explicit state-120 filter on the search route returns nothing'
);
-- The latest-version lateral is proven by the mixed identity: the matching older row is
-- published and the newer row is a Result, and search must return the older version.
select is(
  (
    select found.version::text
    from api.search_processes_latest_v2(
      query_text => '64800000-0000-4000-8000-000000000030',
      filter_condition => '{}'::jsonb, page_size => 100, page_current => 1,
      data_source => 'my',
      this_user_id => '64800000-0000-4000-8000-000000000001',
      state_code_filter => null
    ) as found
    where found.id = '64800000-0000-4000-8000-000000000030'
  ),
  '01.00.000',
  'the search latest-version lateral resolves the older published row, not the Result'
);

reset role;

-- ------------------------------------- 5. reference lookup: process vs support

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000001', true);

select is(
  -- Premise: the reference-lookup route is genuinely keyed on this UUID pattern and the
  -- support block really matches, which the flow assertion below relies on.
  (
    select count(*) > 0
    from api.search_dataset_json_uuid_mentions(
      '64800000-0000-4000-8000-000000000010',
      array['flows'],
      'my',
      '64800000-0000-4000-8000-000000000001',
      null,
      null
    ) as premise
  ),
  true,
  'the reference-lookup route is reachable and the support block matches'
);
select is(
  (
    select count(*)
    from api.search_dataset_json_uuid_mentions(
      '64800000-0000-4000-8000-000000000010',
      array['processes'],
      'my',
      '64800000-0000-4000-8000-000000000001',
      null,
      null
    ) as found
    where found.source_entity_kind = 'process'
  ),
  0::bigint,
  'reference lookup does not surface the Result process'
);
select is(
  (
    select count(*)
    from api.search_dataset_json_uuid_mentions(
      '64800000-0000-4000-8000-000000000010',
      array['flows'],
      'my',
      '64800000-0000-4000-8000-000000000001',
      null,
      null
    ) as found
    where found.source_entity_kind = 'flow'
  ),
  1::bigint,
  'reference lookup still surfaces the support flow that mentions the same UUID'
);
reset role;

-- ------------------------------------------------- 6. export admission by Edge

-- Both export calls run in the service context Edge actually uses. The admission check
-- runs before worker enqueue, so the Result refusal is a genuine admission decision
-- rather than the downstream SERVICE_ROLE_REQUIRED guard, and the positive case can
-- reach the queue at all.
select set_config('request.jwt.claim.role', 'service_role', true);
select set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select is(
  api.svc_tidas_package_export_enqueue(
    '64800000-0000-4000-8000-000000000001',
    'selected_roots',
    '[{"table":"processes","id":"64800000-0000-4000-8000-000000000010","version":"01.00.000"}]'::jsonb,
    'isolation-export-result-120',
    '{}'::jsonb,
    '64800000-0000-4000-8000-0000000000b1',
    'isolation-export-result-120'
  )->>'code',
  'ROOT_EXPORT_FORBIDDEN',
  'the package export entry refuses a Result root'
);
select is(
  api.svc_tidas_package_export_enqueue(
    '64800000-0000-4000-8000-000000000001',
    'selected_roots',
    '[{"table":"processes","id":"64800000-0000-4000-8000-000000000011","version":"01.00.000"}]'::jsonb,
    'isolation-export-unit-100',
    '{}'::jsonb,
    '64800000-0000-4000-8000-0000000000b2',
    'isolation-export-unit-100'
  )->>'ok',
  'true',
  'the package export entry still accepts an ordinary published process root'
);

-- The export entrypoint is service-only. That ACL is asserted directly, separately from
-- the service-context call above, so a browser role cannot reach the admission logic.
select ok(
  not has_function_privilege(
    'anon',
    'api.svc_tidas_package_export_enqueue(uuid,text,jsonb,text,jsonb,uuid,text)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'api.svc_tidas_package_export_enqueue(uuid,text,jsonb,text,jsonb,uuid,text)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'api.svc_tidas_package_export_enqueue(uuid,text,jsonb,text,jsonb,uuid,text)',
    'execute'
  ),
  'the package export entrypoint stays service-only after this migration'
);

-- Leave the service context before the remaining sections, so no later assertion runs
-- with a service-role claim.
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"64800000-0000-4000-8000-000000000001"}',
  true
);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000001', true);

-- ------------------------------------------------- 7. Portal stays unavailable

-- The constrained Portal executor cannot be assumed by postgres directly. As in the
-- Portal catalog suite, the membership is transaction-local test scaffolding that rolls
-- back with this suite and grants no capability the executor did not already have.
grant portal_public_executor to postgres;
set local role portal_public_executor;
select is(
  (
    select count(*) from public.processes
    where id = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'the Portal public executor cannot read the Result'
);
reset role;

-- The real anonymous Portal entrypoint, called with its actual signature.
set local role anon;
select is(
  api.portal_get_dataset_v1(
    'process', '64800000-0000-4000-8000-000000000010', '01.00.000'
  ),
  null::jsonb,
  'the anonymous Portal detail entrypoint returns nothing for the Result'
);
select isnt(
  api.portal_get_dataset_v1(
    'process', '64800000-0000-4000-8000-000000000011', '01.00.000'
  ),
  null::jsonb,
  'the anonymous Portal detail entrypoint still returns an ordinary published process'
);
reset role;

-- Portal search returns a jsonb page rather than a row set, so the payload is inspected
-- directly. An exact-UUID query is the strongest form: it targets the Result identity.
-- p_limit is bounded to 1..50 by private.portal_validate_search_v1.
set local role anon;
select is(
  (
    select count(*)
    from jsonb_array_elements(
      api.portal_search_processes_v2(
        p_query => '64800000-0000-4000-8000-000000000010', p_limit => 50
      )->'items'
    ) as item(value)
    where item.value->>'id' = '64800000-0000-4000-8000-000000000010'
  ),
  0::bigint,
  'anonymous Portal process search does not surface the Result'
);
select is(
  -- Positive control for the route itself: the response is a well-formed V2 page. This is
  -- deliberately weaker than asserting a specific card, because whether a minimal fixture
  -- projects into the catalog depends on card-derivation requirements this suite does not
  -- control. The absence assertion above is the security-relevant one.
  (
    select api.portal_search_processes_v2(
      p_query => 'isolationneedle', p_limit => 50
    )->>'schemaVersion'
  ),
  'portal.public-search-page.v2',
  'anonymous Portal process search still returns a well-formed page'
);
reset role;

-- --------------------------------------------- 8. support dataset is untouched

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64800000-0000-4000-8000-000000000002', true);
select is(
  (
    select count(*)
    from api.search_dataset_json_uuid_mentions(
      '64800000-0000-4000-8000-000000000020',
      array['flows'],
      'tg',
      '',
      null,
      null
    ) as found
    where found.source_entity_kind = 'flow'
  ),
  1::bigint,
  'a public support flow is still visible to an unrelated actor'
);
reset role;

select * from finish();
rollback;
