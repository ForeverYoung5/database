-- Database #646 / workspace #1201: Result Process lifecycle protection.
--
-- Rollback-only. Proves the prerequisite slice only:
--   * a state-120 row is immutable except its four derivative columns;
--   * the guard runs after every other BEFORE trigger on public.processes;
--   * withdrawal can no longer downgrade a Result, for the owner and for a manager;
--   * version derivation can no longer source a Result, with or without a receipt;
--   * ordinary 0/20/100/200 rows and support datasets behave exactly as before.
--
-- Scope note: this slice provides no publication admission and creates no state-120
-- row of its own. Fixtures insert state 120 directly as superuser inside this
-- transaction, which is the supported way to reach the protected state until the
-- dedicated Result publication command exists. Every tested guard stays active: no
-- trigger is disabled, no guard is dropped, and no production bypass is added.
--
-- Deliberately outside this test: the raw json_ordered ::text comparison is asserted
-- with a jsonb-equal but byte-different document, which is the case jsonb alone misses.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

-- Outbound extraction webhooks need Vault secrets a disposable database does not have.
-- Redirecting that one egress call to an in-database recorder is the established
-- candidate-closure fixture technique; the guard under test is not disabled.
create temporary table lifecycle_webhook_calls (
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
  insert into pg_temp.lifecycle_webhook_calls(
    edge_function,
    body,
    timeout_milliseconds
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
  '64700000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'lifecycle-owner@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
),
(
  '00000000-0000-0000-0000-000000000000',
  '64700000-0000-4000-8000-000000000002',
  'authenticated', 'authenticated', 'lifecycle-manager@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
);
insert into private.users(id, raw_user_meta_data, contact) values
  ('64700000-0000-4000-8000-000000000001', '{}', null),
  ('64700000-0000-4000-8000-000000000002', '{}', null);
insert into private.teams(id, json, rank, is_public)
values (
  '00000000-0000-0000-0000-000000000000', '{"name":"System"}', 0, false
)
on conflict (id) do nothing;
-- The manager holds only the existing platform role; no role is invented here.
insert into private.roles(user_id, team_id, role)
values (
  '64700000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000000',
  'data_product_manager'
);

-- ---------------------------------------------------------------------- fixtures

-- Two protected Results: one owned by an ordinary owner, one owned by the manager, so
-- the manager-bypass assertion uses a row the manager actually owns.
insert into public.processes(id, version, state_code, user_id, json_ordered, model_id)
values
(
  '64700000-0000-4000-8000-000000000010', '01.00.000', 120,
  '64700000-0000-4000-8000-000000000001',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000010"},"technology":{"referenceToIncludedProcesses":[]}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"},"commissionerAndGoal":{"common:referenceToCommissioner":[]}}}}',
  null
),
(
  '64700000-0000-4000-8000-000000000011', '01.00.000', 120,
  '64700000-0000-4000-8000-000000000002',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000011"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  '64700000-0000-4000-8000-000000000012'
),
(
  '64700000-0000-4000-8000-000000000020', '01.00.000', 100,
  '64700000-0000-4000-8000-000000000001',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000020"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  null
),
(
  '64700000-0000-4000-8000-000000000030', '01.00.000', 200,
  '64700000-0000-4000-8000-000000000001',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000030"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  null
);

-- A support dataset at 100 for the preserved-withdrawal regression.
insert into public.flows(id, version, state_code, user_id, json_ordered)
values (
  '64700000-0000-4000-8000-000000000040', '01.00.000', 100,
  '64700000-0000-4000-8000-000000000001',
  '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000040"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
);
-- A support dataset in a reserved state, and a second Process in a reserved state, so the
-- preserved published-state refusal proofs use rows this suite does not mutate elsewhere.
-- Both stay at state 200 for the remainder of the suite.
insert into public.flows(id, version, state_code, user_id, json_ordered)
values (
  '64700000-0000-4000-8000-000000000041', '01.00.000', 200,
  '64700000-0000-4000-8000-000000000001',
  '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000041"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
);
insert into public.processes(id, version, state_code, user_id, json_ordered)
values (
  '64700000-0000-4000-8000-000000000031', '01.00.000', 200,
  '64700000-0000-4000-8000-000000000001',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000031"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
);

-- ----------------------------------------------------------------- 1. guard shape

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.processes'::regclass
      and tgname = 'zzz_guard_process_result_lifecycle'
      and not tgisinternal
      -- Bit layout: 1 = ROW, 2 = BEFORE, 4 = INSERT, 8 = DELETE, 16 = UPDATE.
      and tgtype = 2 + 8 + 16 + 1
      and tgenabled = 'O'
  ),
  'the lifecycle guard is exactly an enabled row-level BEFORE UPDATE OR DELETE trigger'
);

select is(
  (
    select count(*)
    from pg_trigger
    where tgrelid = 'public.processes'::regclass
      and not tgisinternal
      and (tgtype & 2) = 2
      and tgname > 'zzz_guard_process_result_lifecycle'
  ),
  0::bigint,
  'no other BEFORE trigger on public.processes runs after the guard'
);

select ok(
  position('current_setting' in pg_get_functiondef(
    'private.zzz_guard_process_result_lifecycle()'::regprocedure
  )) = 0,
  'the guard consults no caller-settable setting'
);
select ok(
  position('pg_catalog.current_setting' in pg_get_functiondef(
    'private.zzz_guard_process_result_lifecycle()'::regprocedure
  )) = 0,
  'the guard has no schema-qualified setting read either'
);
select ok(
  position('receipt' in lower(pg_get_functiondef(
    'private.zzz_guard_process_result_lifecycle()'::regprocedure
  ))) = 0,
  'the guard depends on no publication receipt'
);

select is(
  (
    select pg_get_userbyid(proowner)
    from pg_proc
    where oid = 'private.zzz_guard_process_result_lifecycle()'::regprocedure
  ),
  'postgres',
  'the guard helper is owned by postgres'
);
select ok(
  (
    select proconfig = array['search_path=""']::text[]
    from pg_proc
    where oid = 'private.zzz_guard_process_result_lifecycle()'::regprocedure
  ),
  'the guard helper pins an exactly empty fixed search_path'
);
select ok(
  not has_function_privilege(
    'anon', 'private.zzz_guard_process_result_lifecycle()', 'execute'
  )
  and not has_function_privilege(
    'authenticated', 'private.zzz_guard_process_result_lifecycle()', 'execute'
  )
  and not has_function_privilege(
    'service_role', 'private.zzz_guard_process_result_lifecycle()', 'execute'
  ),
  'the guard helper is executable by no browser or service role'
);

-- ------------------------------------- 2. each protected category is blocked

-- state / identity / owner / model / review / authored content, all as superuser.
select throws_ok(
  $sql$ update public.processes set state_code = 0
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'a Result cannot be downgraded to draft state'
);
select throws_ok(
  $sql$ update public.processes set state_code = 100
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'a Result cannot be moved back to numeric-eligible state 100'
);
select throws_ok(
  $sql$ update public.processes set version = '09.00.000'
         where id = '64700000-0000-4000-8000-000000000010' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'a Result version cannot be rewritten'
);
select throws_ok(
  $sql$ update public.processes set user_id = '64700000-0000-4000-8000-000000000002'
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'a Result owner cannot be reassigned'
);
select throws_ok(
  $sql$ update public.processes set model_id = '64700000-0000-4000-8000-000000000099'
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'a Result model binding cannot be changed'
);
select throws_ok(
  $sql$ update public.processes
          set model_version = '02.00.000'
        where id = '64700000-0000-4000-8000-000000000011'
          and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'a Result model version cannot be changed'
);
select throws_ok(
  $sql$ update public.processes set rule_verification = false
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'Result review verification cannot be changed'
);
select throws_ok(
  $sql$ update public.processes
          set team_id = '00000000-0000-0000-0000-000000000000'
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'Result review team assignment cannot be changed'
);
select throws_ok(
  $sql$ update public.processes
          set review_id = '64700000-0000-4000-8000-000000000098'
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'Result review binding cannot be changed'
);
select throws_ok(
  $sql$ update public.processes set reviews = '{"log":[]}'::jsonb
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'Result review payload cannot be changed'
);
select throws_ok(
  $sql$ update public.processes
          set json_ordered = jsonb_set(
                json_ordered::jsonb,
                '{processDataSet,processInformation,dataSetInformation,technology}',
                '{"referenceToIncludedProcesses":[1]}'::jsonb,
                true
              )::json
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'Result authored content cannot be changed'
);

-- The decisive case for the raw ::text comparison. A whitespace variant of the stored
-- document is jsonb-equal, so a jsonb-only comparison would accept it; the guard must
-- reject it because the ordered bytes differ. The premise is asserted first so the
-- rejection cannot pass for an unrelated reason.
select is(
  (
    select (' ' || json_ordered::text)::json::jsonb = json_ordered::jsonb
    from public.processes
    where id = '64700000-0000-4000-8000-000000000010'
      and version = '01.00.000'
  ),
  true,
  'the whitespace-variant document is jsonb-equal to the stored document'
);
select isnt(
  (
    select (' ' || json_ordered::text)::json::text
    from public.processes
    where id = '64700000-0000-4000-8000-000000000010'
      and version = '01.00.000'
  ),
  (
    select json_ordered::text
    from public.processes
    where id = '64700000-0000-4000-8000-000000000010'
      and version = '01.00.000'
  ),
  'the whitespace-variant document differs from the stored document byte-wise'
);
select throws_ok(
  $sql$ update public.processes
          set json_ordered = (' ' || json_ordered::text)::json
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'a jsonb-equal but byte-different ordered document is still rejected'
);

-- ------------------------------------------------------ 3. service-context DML

set local role service_role;
-- Premise: the Result row must be reachable in this context, otherwise a blocked
-- statement would affect zero rows and the assertion below could pass for the wrong
-- reason. service_role reaches it either by bypassing RLS or through a qualifying
-- policy; if it does not, this premise fails loudly instead of hiding the problem.
select is(
  (
    select count(*)
    from public.processes
    where id = '64700000-0000-4000-8000-000000000010'
      and version = '01.00.000'
  ),
  1::bigint,
  'the Result row is reachable in the service context under test'
);
select throws_ok(
  $sql$ update public.processes set state_code = 0
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'service_role direct UPDATE of a Result is refused'
);
select throws_ok(
  $sql$ delete from public.processes
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'service_role direct DELETE of a Result is refused'
);
reset role;

select is(
  (
    select count(*)
    from public.processes
    where id in (
      '64700000-0000-4000-8000-000000000010',
      '64700000-0000-4000-8000-000000000011'
    )
      and state_code = 120
  ),
  2::bigint,
  'both Results are intact immediately after the service-context attempts'
);

-- A caller who sets the existing review-controlled write context still cannot modify a
-- Result. That context is the guarded-command escape used by cmd_review_submit and
-- cmd_review_finalize_approve; it is deliberately not a Result bypass, and this proves
-- the new guard is not fooled by it. The attempt is labelled separately from the
-- ordinary write paths above.
create temporary table lifecycle_control_write_before on commit drop as
select id, version, state_code, user_id, modified_at, json_ordered::text as document
from public.processes
where id = '64700000-0000-4000-8000-000000000010';

select set_config('app.review_controlled_write', 'on', true);
select throws_ok(
  $sql$ update public.processes set state_code = 0
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'the review-controlled write context does not bypass Result protection'
);
select throws_ok(
  $sql$ update public.processes
          set json_ordered = jsonb_set(
                json_ordered::jsonb,
                '{processDataSet,lifecycleMarker}',
                '"control-write"'::jsonb,
                true
              )::json
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'the review-controlled write context cannot edit Result authored content'
);
select throws_ok(
  $sql$ delete from public.processes
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'the review-controlled write context cannot delete a Result'
);
select set_config('app.review_controlled_write', 'off', true);

select is(
  (
    select count(*)
    from public.processes as current_row
    join lifecycle_control_write_before as before
      on before.id = current_row.id
     and before.version = current_row.version
    where current_row.state_code = before.state_code
      and current_row.user_id = before.user_id
      and current_row.modified_at = before.modified_at
      and current_row.json_ordered::text = before.document
  ),
  1::bigint,
  'the Result is byte-for-byte unchanged after the controlled-write attempts'
);

select throws_ok(
  $sql$ delete from public.processes
         where id = '64700000-0000-4000-8000-000000000011'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'even a superuser DELETE of a Result is refused by the guard'
);

select is(
  (
    select count(*)
    from public.processes
    where id in (
      '64700000-0000-4000-8000-000000000010',
      '64700000-0000-4000-8000-000000000011'
    )
      and state_code = 120
  ),
  2::bigint,
  'both Results survived every blocked attempt unchanged'
);

-- ------------------------------------------- 4. permitted derivative writes

create temporary table lifecycle_before on commit drop as
select id, version, modified_at, json_ordered::text as document, state_code, user_id
from public.processes
where id = '64700000-0000-4000-8000-000000000010';

-- A true no-op touching only a derivative column is permitted.
select lives_ok(
  $sql$ update public.processes set extracted_md = extracted_md
         where id = '64700000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  'a no-op derivative update is permitted'
);

-- All four derivative columns are permitted, including the vector column.
select lives_ok(
  $sql$ update public.processes
          set extracted_md = 'lifecycle derivative markdown'
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  'extracted_md may change on a Result'
);
select lives_ok(
  $sql$ update public.processes
          set search_text = array['lifecycle derivative term']
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  'search_text may change on a Result'
);
select lives_ok(
  $sql$ update public.processes
          set embedding_ft = (
                '[' || array_to_string(
                  array_prepend('1', array_fill('0'::text, array[1023])), ','
                ) || ']'
              )::extensions.vector
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  'embedding_ft may change on a Result'
);
select lives_ok(
  $sql$ update public.processes
          set embedding_ft_at = now()
        where id = '64700000-0000-4000-8000-000000000010'
          and version = '01.00.000' $sql$,
  'embedding_ft_at may change on a Result'
);

select is(
  (
    select count(*)
    from public.processes as current_row
    join lifecycle_before as before
      on before.id = current_row.id
     and before.version = current_row.version
    where current_row.id = '64700000-0000-4000-8000-000000000010'
      and current_row.modified_at = before.modified_at
      and current_row.json_ordered::text = before.document
      and current_row.state_code = before.state_code
      and current_row.user_id = before.user_id
  ),
  1::bigint,
  'permitted derivative writes leave authored modified_at and content at parity'
);
select isnt(
  (
    select extracted_md
    from public.processes
    where id = '64700000-0000-4000-8000-000000000010'
      and version = '01.00.000'
  ),
  null,
  'the derivative write actually landed'
);

-- ---------------------------------------- 5. withdrawal: no result downgrade

select is(
  (
    select count(*)
    from private.lca_release_publications
    where is_current = true and status = 'current'
  ),
  0::bigint,
  'the fixture has no current release'
);
select is(
  (
    select count(*)
    from pg_class as relation
    join pg_namespace as namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in ('private', 'public')
      and relation.relname like '%result_publication_receipt%'
  ),
  0::bigint,
  'no publication receipt relation exists, so protection cannot depend on one'
);

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claim.sub', '64700000-0000-4000-8000-000000000001', true
);

select is(
  api.cmd_dataset_withdraw(
    'processes',
    '64700000-0000-4000-8000-000000000010',
    '01.00.000',
    'lifecycle protection probe'
  )->>'code',
  'RESULT_WITHDRAW_REQUIRES_MIGRATION_PATH',
  'the owner cannot withdraw a Result, even with no publication receipt present'
);
select is(
  api.cmd_dataset_withdraw(
    'processes',
    '64700000-0000-4000-8000-000000000010',
    '01.00.000',
    'lifecycle protection probe'
  )->>'status',
  '403',
  'the Result withdrawal rejection is a 403'
);

-- Baseline behaviour, asserted as-is rather than assumed. A state-100 row is immutable
-- to review_dataset_content_guard_v1 outside the review-controlled write context, so
-- withdrawing one already raises before this migration existed. This is unchanged
-- pre-existing behaviour and is recorded here as baseline evidence; it is NOT a defect
-- introduced by this slice and is NOT fixed here.
select throws_ok(
  $sql$ select api.cmd_dataset_withdraw(
          'processes',
          '64700000-0000-4000-8000-000000000020',
          '01.00.000',
          'baseline state-100 withdrawal probe'
        ) $sql$,
  '55000',
  'APPROVED_DATASET_IMMUTABLE',
  'baseline: withdrawing a state-100 process already raises the existing immutability guard'
);
select throws_ok(
  $sql$ select api.cmd_dataset_withdraw(
          'flows',
          '64700000-0000-4000-8000-000000000040',
          '01.00.000',
          'baseline support withdrawal probe'
        ) $sql$,
  '55000',
  'APPROVED_DATASET_IMMUTABLE',
  'baseline: withdrawing a state-100 support flow already raises the same guard'
);

-- A reserved-state row is rejected by the unchanged command condition
-- `v_state_code < 100 or v_state_code >= 200`, which is evaluated after the new 120
-- check. This is preserved pre-existing behaviour, asserted as-is so the 120 branch is
-- proven not to have altered it. No eligible state other than 100 exists in the table
-- CHECK, and neither the command nor the constraint is changed here.
select is(
  api.cmd_dataset_withdraw(
    'processes',
    '64700000-0000-4000-8000-000000000030',
    '01.00.000',
    'reserved state withdrawal probe'
  )->>'code',
  'DATASET_WITHDRAW_REQUIRES_PUBLISHED_STATE',
  'a state-200 process is still refused by the preserved published-state condition'
);
select is(
  api.cmd_dataset_withdraw(
    'processes',
    '64700000-0000-4000-8000-000000000030',
    '01.00.000',
    'reserved state withdrawal probe'
  )->>'status',
  '403',
  'the state-200 process withdrawal refusal keeps its 403 status'
);
select is(
  api.cmd_dataset_withdraw(
    'flows',
    '64700000-0000-4000-8000-000000000041',
    '01.00.000',
    'reserved state support withdrawal probe'
  )->>'code',
  'DATASET_WITHDRAW_REQUIRES_PUBLISHED_STATE',
  'a state-200 support flow is still refused by the preserved published-state condition'
);
select is(
  api.cmd_dataset_withdraw(
    'flows',
    '64700000-0000-4000-8000-000000000041',
    '01.00.000',
    'reserved state support withdrawal probe'
  )->>'status',
  '403',
  'the state-200 support flow withdrawal refusal keeps its 403 status'
);

reset role;

-- The manager owns a Result and holds the platform role; that is still not authority
-- to downgrade it.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub', '64700000-0000-4000-8000-000000000002', true
);
select ok(
  (api.assert_lca_release_manager()->>'ok') = 'true',
  'the manager fixture holds the live platform role'
);
select is(
  api.cmd_dataset_withdraw(
    'processes',
    '64700000-0000-4000-8000-000000000011',
    '01.00.000',
    'manager withdrawal probe'
  )->>'code',
  'RESULT_WITHDRAW_REQUIRES_MIGRATION_PATH',
  'the Data Product Manager cannot withdraw even a Result it owns'
);
reset role;

select is(
  (
    select count(*)
    from public.processes
    where id in (
      '64700000-0000-4000-8000-000000000010',
      '64700000-0000-4000-8000-000000000011'
    )
      and state_code = 120
  ),
  2::bigint,
  'no withdrawal attempt changed a Result state'
);

-- ------------------------------------ 6. version derivation: no Result source

set local role authenticated;
select set_config(
  'request.jwt.claim.sub', '64700000-0000-4000-8000-000000000001', true
);

select is(
  api.cmd_dataset_create_version(
    'processes',
    '64700000-0000-4000-8000-000000000010',
    '01.00.000',
    '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'::jsonb,
    null, true, '{}'::jsonb, null
  )->>'code',
  'RESULT_VERSION_DERIVATION_BLOCKED',
  'a Result cannot be used as a version source'
);
select is(
  api.cmd_dataset_create_version(
    'processes',
    '64700000-0000-4000-8000-000000000010',
    '01.00.000',
    '{}'::jsonb, null, true, '{}'::jsonb, null
  )->>'status',
  '403',
  'the Result version-derivation rejection is a 403'
);
-- Internal census as a privileged test observer. The API calls above stay under the
-- authentic actor role; a direct read of a state-120 row as that actor is hidden by the
-- Result read-isolation policy, which is a separate, later slice. Reading it directly here
-- would measure isolation rather than whether the blocked derivation created a draft.
reset role;
select is(
  (
    select count(*)
    from public.processes
    where id = '64700000-0000-4000-8000-000000000010'
  ),
  1::bigint,
  'the blocked derivation created no draft row'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub', '64700000-0000-4000-8000-000000000001', true
);

-- An ordinary draft is still a valid version source, and the new row is state 0.
select is(
  api.cmd_dataset_create_version(
    'processes',
    '64700000-0000-4000-8000-000000000020',
    '01.00.000',
    '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000020"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'::jsonb,
    null, true, '{}'::jsonb, null
  )->>'ok',
  'true',
  'an ordinary process is still a valid version source'
);
select is(
  (
    select state_code
    from public.processes
    where id = '64700000-0000-4000-8000-000000000020'
      and version = '01.00.001'
  ),
  0,
  'the derived version is created as an ordinary state-0 draft'
);

-- Support datasets are unaffected by the Process-only check.
select is(
  api.cmd_dataset_create_version(
    'flows',
    '64700000-0000-4000-8000-000000000040',
    '01.00.000',
    '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000040"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'::jsonb,
    null, true, '{}'::jsonb, null
  )->>'ok',
  'true',
  'a support flow still supports version derivation'
);
reset role;

-- --------------------------------------------- 7. unrelated rows are untouched

select lives_ok(
  $sql$ update public.processes
          set json_ordered = '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000031"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}},"lifecycleMarker":"state200"}}'::json
        where id = '64700000-0000-4000-8000-000000000031'
          and version = '01.00.000' $sql$,
  'a state-200 row is still freely editable'
);
select lives_ok(
  $sql$ delete from public.processes
         where id = '64700000-0000-4000-8000-000000000020'
           and version = '01.00.001' $sql$,
  'an ordinary state-0 row is still deletable'
);
-- The support edit proof uses the draft this suite created in step 6, not the still
-- public source row, which the baseline immutability guard protects.
select lives_ok(
  $sql$ update public.flows
          set json_ordered = '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"common:UUID":"64700000-0000-4000-8000-000000000040"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.001"}},"lifecycleMarker":"support-draft"}}'::json
        where id = '64700000-0000-4000-8000-000000000040'
          and version = '01.00.001' $sql$,
  'the newly created support draft is still freely editable'
);

-- ------------------------------------------------------- 8. contracts preserved

select ok(
  (
    select pg_get_userbyid(proowner)
    from pg_proc
    where oid = 'api.cmd_dataset_withdraw(text,uuid,text,text,jsonb)'::regprocedure
  ) = 'postgres',
  'withdraw keeps its owner'
);
select ok(
  (
    select pg_get_userbyid(proowner)
    from pg_proc
    where oid = 'api.cmd_dataset_create_version(text,uuid,text,jsonb,uuid,boolean,jsonb,text)'::regprocedure
  ) = 'postgres',
  'create_version keeps its owner'
);
select ok(
  (
    select proconfig = array[
      'search_path=api, private, public, util, extensions, pg_temp'
    ]::text[]
    from pg_proc
    where oid = 'api.cmd_dataset_withdraw(text,uuid,text,text,jsonb)'::regprocedure
  ),
  'withdraw keeps its exact fixed search_path'
);
select ok(
  (
    select proconfig = array[
      'search_path=api, private, public, util, extensions, pg_temp'
    ]::text[]
    from pg_proc
    where oid = 'api.cmd_dataset_create_version(text,uuid,text,jsonb,uuid,boolean,jsonb,text)'::regprocedure
  ),
  'create_version keeps its exact fixed search_path'
);
select ok(
  has_function_privilege('authenticated', 'api.cmd_dataset_withdraw(text,uuid,text,text,jsonb)', 'execute')
  and has_function_privilege('api_internal_executor', 'api.cmd_dataset_withdraw(text,uuid,text,text,jsonb)', 'execute')
  and not has_function_privilege('anon', 'api.cmd_dataset_withdraw(text,uuid,text,text,jsonb)', 'execute')
  and not has_function_privilege('service_role', 'api.cmd_dataset_withdraw(text,uuid,text,text,jsonb)', 'execute'),
  'withdraw keeps its exact ACL set'
);
select ok(
  has_function_privilege('authenticated', 'api.cmd_dataset_create_version(text,uuid,text,jsonb,uuid,boolean,jsonb,text)', 'execute')
  and has_function_privilege('api_internal_executor', 'api.cmd_dataset_create_version(text,uuid,text,jsonb,uuid,boolean,jsonb,text)', 'execute')
  and not has_function_privilege('anon', 'api.cmd_dataset_create_version(text,uuid,text,jsonb,uuid,boolean,jsonb,text)', 'execute')
  and not has_function_privilege('service_role', 'api.cmd_dataset_create_version(text,uuid,text,jsonb,uuid,boolean,jsonb,text)', 'execute'),
  'create_version keeps its exact ACL set'
);
select ok(
  not has_table_privilege('anon', 'public.processes', 'update')
  and not has_table_privilege('anon', 'public.processes', 'insert')
  and not has_table_privilege('authenticated', 'public.processes', 'update')
  and not has_table_privilege('authenticated', 'public.processes', 'insert'),
  'no raw table write privilege was widened for browser roles'
);
select ok(
  has_table_privilege('service_role', 'public.processes', 'update')
  and has_table_privilege('service_role', 'public.processes', 'delete'),
  'service_role table privileges are unchanged'
);

select * from finish();
rollback;
