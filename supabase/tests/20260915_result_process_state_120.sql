-- Database #646 / workspace #1201: Result Process state 120 foundation.
--
-- Rollback-only. Proves exactly what this foundation slice changes:
--   * public.processes accepts 120 and keeps every pre-existing value;
--   * no-current-release global/subset numeric eligibility is exactly state 100;
--   * the current eligible input manifest is exactly state 100 latest-per-id and
--     publishes a fully consistent predicate / status filter / manifest hash;
--   * the processes row of the numeric candidate hash cache holds only state-100
--     rows: 100 -> 120 removes the exact candidate, a 120 insert never enters, and
--     every other dataset type keeps its previous support eligibility predicate;
--   * a formal current release keeps its exact authoritative unit_process axis;
--   * the guarded package-publication consumer rejects a package whose recorded
--     eligibility binding belongs to the retired 100..199 predicate.
--
-- Scope boundary: this suite does not prove that every calculation entrance
-- excludes state 120, and it does not establish Result role proof. Owner-draft and
-- demand paths, provider discovery/expansion, snapshot builder filters, existing
-- release live-state handling, and the remaining Worker/Edge surfaces are
-- coordinated follow-up scope. Public read permission is unchanged by this slice.
--
-- Fixture note: every inserted document carries the same
-- administrativeInformation.publicationAndOwnership.common:dataSetVersion that the
-- production json_ordered -> json/version sync triggers derive, and every process
-- document carries a processDataSet object. No production guard, trigger, policy,
-- or capability grant is disabled or reassigned by this suite.
--
-- Transition note: a state-100 row is immutable by contract, and this slice ships
-- no Result publishing or migration path, so the 100 -> 120 scenario is driven by
-- the suite-owned pg_temp.state120_transition_to_result helper. It sets only the
-- existing review-controlled write GUC that cmd_review_submit and
-- cmd_review_finalize_approve already use. The resulting cache behaviour is
-- therefore proven for a real state transition, while the publishing path that will
-- own it remains coordinated follow-up scope.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

-- Every state this suite inserts is accepted by the table CHECK today, so no
-- unrepresentable-state fixture is smuggled past the constraint.
select is(
  (
    select pg_get_constraintdef(oid)
    from pg_constraint
    where conrelid = 'public.processes'::regclass
      and conname = 'processes_state_code_check'
  ),
  'CHECK ((state_code = ANY (ARRAY[''-1''::integer, 0, 20, 100, 120, 200])))',
  'processes state CHECK accepts exactly the pre-existing values plus 120'
);

-- Outbound webhooks are redirected to an in-database recorder so no network egress
-- is attempted. This is the established candidate-closure fixture technique.
create temporary table state120_webhook_calls (
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
  insert into pg_temp.state120_webhook_calls(
    edge_function,
    body,
    timeout_milliseconds
  ) values (name, body, timeout_milliseconds);
end;
$$;

-- A published (state 100) row is immutable by contract: private.review_dataset_content_guard_v1
-- raises APPROVED_DATASET_IMMUTABLE for any content or state change outside the
-- review-controlled write context. No Result publishing or migration path exists in
-- this slice, so the suite owns the scenario hook that simulates the 100 -> 120
-- transition those future paths must perform. It sets only the existing
-- review-controlled write GUC, exactly like cmd_review_submit/_finalize_approve.
-- No production guard is disabled, dropped, or reassigned.
create or replace function pg_temp.state120_transition_to_result(
  p_id uuid,
  p_version text
) returns integer
language plpgsql
as $$
declare
  v_changed integer;
begin
  perform set_config('app.review_controlled_write', 'on', true);
  update public.processes
  set state_code = 120
  where id = p_id
    and version = p_version::character(9)
    and state_code = 100;
  get diagnostics v_changed = row_count;
  perform set_config('app.review_controlled_write', 'off', true);
  return v_changed;
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  '64600000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'state120-owner@example.invalid', 'x',
  now(), '{}', '{}', now(), now(), false, false
);
insert into private.users(id, raw_user_meta_data, contact)
values ('64600000-0000-4000-8000-000000000001', '{}', null);
insert into private.teams(id, json, rank, is_public)
values (
  '00000000-0000-0000-0000-000000000000',
  '{"name":"System"}', 0, false
)
on conflict (id) do nothing;
insert into private.roles(user_id, team_id, role)
values (
  '64600000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'data_product_manager'
);

-- ------------------------------------------------------------------- processes

-- A helper keeps each document self-consistent with the production version sync
-- trigger, which rewrites version from common:dataSetVersion.
create temporary table state120_documents(label text primary key, document jsonb) on commit drop;
insert into state120_documents(label, document) values
(
  'p100_v1',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  'p100_v2',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"02.00.000"}},"versionMarker":"latest"}}'
),
(
  'p100_single',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000011"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  'p0_draft',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000012"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  'p200_reserved',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000013"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  'p0_team_draft',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000014"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
),
(
  'p120_result',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000015"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}},"LCIAResults":{"aggregated":true}}}'
);

insert into public.processes(id, version, state_code, json_ordered, user_id)
select
  case documents.label
    when 'p100_v1' then '64600000-0000-4000-8000-000000000010'::uuid
    when 'p100_v2' then '64600000-0000-4000-8000-000000000010'::uuid
    when 'p100_single' then '64600000-0000-4000-8000-000000000011'::uuid
    when 'p0_draft' then '64600000-0000-4000-8000-000000000012'::uuid
    when 'p200_reserved' then '64600000-0000-4000-8000-000000000013'::uuid
    when 'p0_team_draft' then '64600000-0000-4000-8000-000000000014'::uuid
    when 'p120_result' then '64600000-0000-4000-8000-000000000015'::uuid
  end,
  case documents.label
    when 'p100_v1' then '01.00.000'
    when 'p100_v2' then '02.00.000'
    else '01.00.000'
  end,
  case documents.label
    when 'p100_v1' then 100
    when 'p100_v2' then 100
    when 'p100_single' then 100
    when 'p0_draft' then 0
    when 'p200_reserved' then 200
    when 'p0_team_draft' then 0
    when 'p120_result' then 120
  end,
  documents.document,
  '64600000-0000-4000-8000-000000000001'
from state120_documents as documents;

update public.processes
set team_id = '00000000-0000-0000-0000-000000000000'
where id = '64600000-0000-4000-8000-000000000014';

-- --------------------------------------------------------------- support data

-- UnitGroup is a support dataset with no Portal projection trigger, so its minimal
-- document only needs the version field the sync trigger reads. A support row in a
-- reserved state stays outside the candidate universe exactly as before, because
-- the retained support predicate is 100..199 and 200 is not in that range. This is
-- a regression pin, not a behaviour this slice introduces. The state-100 row below
-- proves support caching itself still works.
insert into public.unitgroups(id, version, state_code, json_ordered, user_id)
values
(
  '64600000-0000-4000-8000-000000000020', '01.00.000', 200,
  '{"unitGroupDataSet":{"unitGroupInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000020"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  '64600000-0000-4000-8000-000000000001'
),
(
  '64600000-0000-4000-8000-000000000022', '01.00.000', 100,
  '{"unitGroupDataSet":{"unitGroupInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-000000000022"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  '64600000-0000-4000-8000-000000000001'
);

-- Reviewed LCIA static bundle method: state 0 by design, support role, and the
-- exact canonical/artifact alias the allowlist maps.
insert into public.lciamethods(id, version, state_code, json_ordered, user_id)
values (
  '9ec743ea-6b00-400d-a53b-61547a3fc03c', '01.01.000', 0,
  '{"LCIAMethodDataSet":{"LCIAMethodInformation":{"dataSetInformation":{"common:UUID":"503699e0-eca9-4089-8bf8-e0f49c93e578"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.01.000"}}}}',
  '64600000-0000-4000-8000-000000000001'
);

select ok(
  not exists (
    select 1 from private.lca_release_publications
    where is_current = true and status = 'current'
  ),
  'fixture starts with no current formal release'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'lciamethods'
      and dataset_id = '503699e0-eca9-4089-8bf8-e0f49c93e578'
      and source_locator_id = '9ec743ea-6b00-400d-a53b-61547a3fc03c'
      and role = 'support'
  ),
  1::bigint,
  'the reviewed state-zero LCIA static bundle keeps its support rule'
);

-- ---------------------------------------------------------- candidate cache

select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000010'
  ),
  2::bigint,
  'both exact state-100 process versions are cached while numerically eligible'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000011'
  ),
  1::bigint,
  'a state-100 process is cached exactly once'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id in (
        '64600000-0000-4000-8000-000000000012',
        '64600000-0000-4000-8000-000000000014'
      )
  ),
  0::bigint,
  'neither owner draft is a numeric candidate'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000013'
  ),
  0::bigint,
  'the state-200 process is never cached as a numeric unit process'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000015'
  ),
  0::bigint,
  'a state-120 Result insert never enters the numeric candidate cache'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'unitgroups'
      and dataset_id = '64600000-0000-4000-8000-000000000020'
      and role = 'support'
  ),
  0::bigint,
  'a state-200 support row stays outside the retained 100..199 support predicate'
);
select is(
  (
    select role
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'unitgroups'
      and dataset_id = '64600000-0000-4000-8000-000000000022'
  ),
  'support',
  'a state-100 support row is still cached under the support role'
);
select ok(
  position(
    'when tg_table_name = ''processes'' then new.state_code = 100'
    in pg_get_functiondef(
      'private.lcia_scope_closure_refresh_candidate_document_hash()'::regprocedure
    )
  ) > 0
  and position(
    'else new.state_code between 100 and 199'
    in pg_get_functiondef(
      'private.lcia_scope_closure_refresh_candidate_document_hash()'::regprocedure
    )
  ) > 0,
  'only the processes branch is narrowed; the support predicate is retained'
);
select is(
  (
    select count(distinct role)
    from private.lcia_scope_closure_candidate_document_hashes
  ),
  2::bigint,
  'the numeric cache stores only unit_process and support roles'
);

-- A published Result Process leaves the numeric candidate surface immediately.
select is(
  pg_temp.state120_transition_to_result(
    '64600000-0000-4000-8000-000000000010', '01.00.000'
  ),
  1,
  'the scenario hook moves exactly one published version to state 120'
);

select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000010'
      and dataset_version = '01.00.000'
  ),
  0::bigint,
  'state 100 -> 120 removes the exact numeric candidate'
);
select is(
  (
    select role
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000010'
      and dataset_version = '02.00.000'
  ),
  'unit_process',
  'the untouched sibling version keeps its cached unit_process role'
);

-- The Worker-facing candidate manifest is a JSON array, not a single value.
select is(
  jsonb_typeof(private.lcia_scope_closure_candidate_dataset_manifest()),
  'array',
  'the Worker-facing candidate manifest is a JSON array'
);
select is(
  jsonb_array_length(private.lcia_scope_closure_candidate_dataset_manifest()),
  (
    select count(*)::integer
    from private.lcia_scope_closure_candidate_document_hashes
  ),
  'the Worker-facing candidate manifest has exactly one entry per numeric cache row'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      private.lcia_scope_closure_candidate_dataset_manifest()
    ) as entry(value)
    where entry.value->>'datasetId' in (
      '64600000-0000-4000-8000-000000000012',
      '64600000-0000-4000-8000-000000000014',
      '64600000-0000-4000-8000-000000000013',
      '64600000-0000-4000-8000-000000000015'
    )
  ),
  0::bigint,
  'the frozen candidate manifest exposes no Result, draft, or reserved-state process'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      private.lcia_scope_closure_candidate_dataset_manifest()
    ) as entry(value)
    where entry.value->>'datasetId' = '64600000-0000-4000-8000-000000000010'
      and entry.value->>'datasetVersion' = '01.00.000'
  ),
  0::bigint,
  'the migrated exact version is absent from the frozen candidate manifest'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      private.lcia_scope_closure_candidate_dataset_manifest()
    ) as entry(value)
    where entry.value->>'datasetId' = '64600000-0000-4000-8000-000000000010'
      and entry.value->>'datasetVersion' = '02.00.000'
      and entry.value->>'role' = 'unit_process'
  ),
  1::bigint,
  'the sibling eligible version stays in the frozen candidate manifest'
);
select is(
  (
    select count(distinct entry.value->>'role')
    from jsonb_array_elements(
      private.lcia_scope_closure_candidate_dataset_manifest()
    ) as entry(value)
  ),
  2::bigint,
  'the frozen candidate manifest uses only unit_process and support roles'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes as cache
    where cache.dataset_type = 'processes'
      and not exists (
        select 1
        from public.processes as process_row
        where process_row.id = cache.source_locator_id
          and btrim(process_row.version::text) = cache.dataset_version
          and process_row.state_code = 100
          and process_row.json_ordered is not null
      )
  ),
  0::bigint,
  'every cached process row still has an exact state-100 source row'
);

-- --------------------------------------------------- bounded cache maintenance

-- A stale cache row can only exist on a database that recorded it under the old
-- 100..199 rule; the fixture plants one as postgres to prove the separately named
-- maintenance operation drains it in bounded batches.
create temporary table state120_support_cache_before on commit drop as
select dataset_type, dataset_id, dataset_version, role
from private.lcia_scope_closure_candidate_document_hashes
where dataset_type <> 'processes';

insert into private.lcia_scope_closure_candidate_document_hashes(
  dataset_type, dataset_id, dataset_version, source_locator_id, role,
  canonical_content_hash, source_modified_at, refreshed_at
) values
(
  'processes', '64600000-0000-4000-8000-000000000016', '01.00.000',
  '64600000-0000-4000-8000-000000000016', 'unit_process',
  repeat('7', 64), now(), now()
),
(
  'processes', '64600000-0000-4000-8000-000000000017', '01.00.000',
  '64600000-0000-4000-8000-000000000017', 'unit_process',
  repeat('8', 64), now(), now()
);

-- Fail-closed gate: while a stale row exists the frozen numeric universe refuses
-- to be served, so an unmaintained cache can never be silently consumed.
select throws_ok(
  $sql$ select private.lcia_scope_closure_candidate_dataset_manifest() $sql$,
  '55000',
  'candidate_cache_not_current',
  'the candidate manifest refuses to serve while an invalid cache row exists'
);

-- Each intended batch runs exactly once and its own response is inspected, so the
-- assertions describe observed behaviour instead of consuming extra work.
create temporary table state120_maintenance_responses(
  step integer primary key,
  response jsonb not null
) on commit drop;

insert into state120_maintenance_responses(step, response)
values (1, private.maintain_lcia_scope_closure_candidate_cache(1, 5000));
insert into state120_maintenance_responses(step, response)
values (2, private.maintain_lcia_scope_closure_candidate_cache(1, 5000));
insert into state120_maintenance_responses(step, response)
values (3, private.maintain_lcia_scope_closure_candidate_cache());

select is(
  (
    select response->>'removedCount'
    from state120_maintenance_responses
    where step = 1
  ),
  '1',
  'the first batch removes exactly the one row its batch limit allows'
);
select is(
  (
    select response->>'batchLimit'
    from state120_maintenance_responses
    where step = 1
  ),
  '1',
  'the first batch reports the caller-supplied batch limit'
);
select is(
  (
    select response->>'remainingCount'
    from state120_maintenance_responses
    where step = 1
  ),
  '1',
  'the first batch reports the exact residual it measured'
);
select is(
  (
    select response->>'moreRemaining'
    from state120_maintenance_responses
    where step = 1
  ),
  'true',
  'a batch that leaves work behind reports it instead of claiming completion'
);
select is(
  (
    select response->>'removedCount'
    from state120_maintenance_responses
    where step = 2
  ),
  '1',
  'the retry removes the next stale candidate with deterministic forward progress'
);
select is(
  (
    select response->>'moreRemaining'
    from state120_maintenance_responses
    where step = 2
  ),
  'false',
  'the batch that reaches zero reports no remaining work'
);
select is(
  (
    select response->>'removedCount'
    from state120_maintenance_responses
    where step = 3
  ),
  '0',
  'repeating maintenance on a drained cache is an idempotent no-op'
);
select is(
  (
    select response->>'moreRemaining'
    from state120_maintenance_responses
    where step = 3
  ),
  'false',
  'an idempotent no-op also reports no remaining work'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_id in (
      '64600000-0000-4000-8000-000000000016',
      '64600000-0000-4000-8000-000000000017'
    )
  ),
  0::bigint,
  'both planted stale candidates are gone after bounded retries'
);
select is(
  jsonb_array_length(private.lcia_scope_closure_candidate_dataset_manifest()),
  (
    select count(*)::integer
    from private.lcia_scope_closure_candidate_document_hashes
  ),
  'the candidate manifest serves again once maintenance has drained the cache'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000010'
      and dataset_version = '02.00.000'
  ),
  1::bigint,
  'bounded maintenance never removes an eligible row'
);
select is(
  (
    select count(*)
    from (
      select dataset_type, dataset_id, dataset_version, role
      from private.lcia_scope_closure_candidate_document_hashes
      where dataset_type <> 'processes'
      except
      select dataset_type, dataset_id, dataset_version, role
      from state120_support_cache_before
    ) as support_drift
  ),
  0::bigint,
  'every non-process candidate row survives maintenance with an identical role'
);
select throws_ok(
  $sql$ select private.maintain_lcia_scope_closure_candidate_cache(0) $sql$,
  '22023',
  'invalid_candidate_cache_maintenance_batch',
  'a zero batch limit is refused'
);
select throws_ok(
  $sql$ select private.maintain_lcia_scope_closure_candidate_cache(10001) $sql$,
  '22023',
  'invalid_candidate_cache_maintenance_batch',
  'a batch limit above the supported maximum is refused'
);
select throws_ok(
  $sql$ select private.maintain_lcia_scope_closure_candidate_cache(10, 0) $sql$,
  '22023',
  'invalid_candidate_cache_maintenance_lock_timeout',
  'a zero lock timeout is refused'
);
select throws_ok(
  $sql$ select private.maintain_lcia_scope_closure_candidate_cache(10, 60001) $sql$,
  '22023',
  'invalid_candidate_cache_maintenance_lock_timeout',
  'a lock timeout above the supported maximum is refused'
);
select is(
  (
    select response->>'status'
    from state120_maintenance_responses
    where step = 3
  ),
  'ok',
  'uncontended maintenance reports an ok status'
);

-- Sequential lifecycle coverage around maintenance. This is deliberately NOT
-- concurrency proof: a genuine interleaving is not constructible here because the
-- proof would need an out-of-band session (dblink needs a password in this
-- instance) or two-phase commit (max_prepared_transactions is 0), and this suite is
-- rollback-only. What it does prove is that maintenance is a no-op while every
-- cached process is eligible, and that a later 100 -> 120 transition is still
-- removed by the trigger. The concurrent case is covered by the guard assertion
-- below and documented in the owning contract.
select is(
  private.maintain_lcia_scope_closure_candidate_cache(1, 5000)->>'removedCount',
  '0',
  'maintenance finds nothing to remove while every cached process remains eligible'
);
select is(
  pg_temp.state120_transition_to_result(
    '64600000-0000-4000-8000-000000000011', '01.00.000'
  ),
  1,
  'a second published version moves to state 120 after maintenance ran'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = 'processes'
      and dataset_id = '64600000-0000-4000-8000-000000000011'
  ),
  0::bigint,
  'a post-maintenance 100 -> 120 transition is still removed by the trigger'
);
-- The removal does not try to win a race against a source writer; it removes the
-- race with one consistent lock order. These assertions pin that protocol and the
-- caller-setting preservation in the stored definition; the interleaving itself is
-- proven by the multi-session regression harness
-- supabase/tests/regression/20260915_result_process_state_120_concurrency.sh,
-- because a rollback-only single-session suite cannot establish it.
select ok(
  position(
    'lock table public.processes in share row exclusive mode'
    in pg_get_functiondef(
      'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
    )
  ) > 0,
  'candidate cache maintenance fences the source table before deciding'
);
select ok(
  position(
    'when lock_not_available then'
    in pg_get_functiondef(
      'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
    )
  ) > 0
  and position(
    '''status'', ''lock_timeout'''
    in pg_get_functiondef(
      'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
    )
  ) > 0,
  'a contended fence reports lock timeout instead of deleting anything'
);
select ok(
  position(
    'set_config(''lock_timeout'', v_previous_lock_timeout, true)'
    in pg_get_functiondef(
      'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
    )
  ) > 0,
  'candidate cache maintenance restores the caller lock timeout'
);
select ok(
  pg_catalog.length(
    pg_get_functiondef(
      'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
    )
  ) > 0
  and (
    pg_catalog.length(
      pg_get_functiondef(
        'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
      )
    ) - pg_catalog.length(
      pg_catalog.replace(
        pg_get_functiondef(
          'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
        ),
        'set_config(''lock_timeout'', v_previous_lock_timeout, true)',
        ''
      )
    )
  ) / pg_catalog.length('set_config(''lock_timeout'', v_previous_lock_timeout, true)') >= 3,
  'every maintenance return path restores the caller lock timeout'
);
select ok(
  position(
    'set_config(''application_name'''
    in pg_get_functiondef(
      'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)'::regprocedure
    )
  ) = 0,
  'maintenance never renames the caller session'
);
-- Caller-setting preservation is behavioural, not merely textual: a successful call
-- leaves the caller's own lock_timeout in place.
select set_config('lock_timeout', '4321ms', true);
select is(
  private.maintain_lcia_scope_closure_candidate_cache(1, 5000)->>'status',
  'ok',
  'the preservation probe runs a real successful maintenance batch'
);
select is(
  current_setting('lock_timeout'),
  '4321ms',
  'a successful maintenance call preserves the caller lock timeout setting'
);
select set_config('lock_timeout', '0', true);

-- ------------------------------------------------------------ candidate scoping

create temporary table state120_reviewed_method(method_id uuid, method_version text) on commit drop;
insert into state120_reviewed_method values
  ('503699e0-eca9-4089-8bf8-e0f49c93e578', '01.01.000');

select is(
  private.lcia_scope_closure_normalize_request(
    jsonb_build_object(
      'coverageMode', 'global_eligible',
      'lciaMethods', jsonb_build_array(jsonb_build_object(
        'id', '503699e0-eca9-4089-8bf8-e0f49c93e578',
        'version', '01.01.000'
      ))
    )
  )->>'eligibilityPredicateVersion',
  'candidate-public-state-code-100:v2',
  'no-release global eligibility uses the frozen candidate predicate literal'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      private.lcia_scope_closure_normalize_request(
        jsonb_build_object(
          'coverageMode', 'global_eligible',
          'lciaMethods', jsonb_build_array(jsonb_build_object(
            'id', '503699e0-eca9-4089-8bf8-e0f49c93e578',
            'version', '01.01.000'
          ))
        )
      )->'processes'
    ) as entry(value)
    where entry.value->>'id' in (
      '64600000-0000-4000-8000-000000000012',
      '64600000-0000-4000-8000-000000000014',
      '64600000-0000-4000-8000-000000000013',
      '64600000-0000-4000-8000-000000000015'
    )
  ),
  0::bigint,
  'no-release global eligible selects no Result, draft, or reserved-state process'
);
select is(
  (
    select entry.value->>'version'
    from jsonb_array_elements(
      private.lcia_scope_closure_normalize_request(
        jsonb_build_object(
          'coverageMode', 'global_eligible',
          'lciaMethods', jsonb_build_array(jsonb_build_object(
            'id', '503699e0-eca9-4089-8bf8-e0f49c93e578',
            'version', '01.01.000'
          ))
        )
      )->'processes'
    ) as entry(value)
    where entry.value->>'id' = '64600000-0000-4000-8000-000000000010'
  ),
  '02.00.000',
  'latest-per-id picks the highest eligible version, not the migrated Result version'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      private.lcia_scope_closure_normalize_request(
        jsonb_build_object(
          'coverageMode', 'global_eligible',
          'lciaMethods', jsonb_build_array(jsonb_build_object(
            'id', '503699e0-eca9-4089-8bf8-e0f49c93e578',
            'version', '01.01.000'
          ))
        )
      )->'processes'
    ) as entry(value)
    where entry.value->>'id' = '64600000-0000-4000-8000-000000000010'
  ),
  1::bigint,
  'a partially migrated identity contributes exactly its one eligible version'
);

select throws_ok(
  $sql$
    select private.lcia_scope_closure_normalize_request(
      '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000012","version":"01.00.000"}],"lciaMethods":[{"id":"503699e0-eca9-4089-8bf8-e0f49c93e578","version":"01.01.000"}]}'::jsonb
    )
  $sql$,
  '22023',
  'invalid_or_ineligible_process_selection',
  'an explicit subset of an owner draft is rejected'
);
select throws_ok(
  $sql$
    select private.lcia_scope_closure_normalize_request(
      '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000015","version":"01.00.000"}],"lciaMethods":[{"id":"503699e0-eca9-4089-8bf8-e0f49c93e578","version":"01.01.000"}]}'::jsonb
    )
  $sql$,
  '22023',
  'invalid_or_ineligible_process_selection',
  'an explicit subset of a state-120 Result is rejected'
);
select throws_ok(
  $sql$
    select private.lcia_scope_closure_normalize_request(
      '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000010","version":"01.00.000"}],"lciaMethods":[{"id":"503699e0-eca9-4089-8bf8-e0f49c93e578","version":"01.01.000"}]}'::jsonb
    )
  $sql$,
  '22023',
  'invalid_or_ineligible_process_selection',
  'an explicit subset of the migrated exact version is rejected'
);
select throws_ok(
  $sql$
    select private.lcia_scope_closure_normalize_request(
      '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000013","version":"01.00.000"}],"lciaMethods":[{"id":"503699e0-eca9-4089-8bf8-e0f49c93e578","version":"01.01.000"}]}'::jsonb
    )
  $sql$,
  '22023',
  'invalid_or_ineligible_process_selection',
  'an explicit subset of a reserved-state process is rejected'
);
select is(
  private.lcia_scope_closure_normalize_request(
    '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000010","version":"02.00.000"}],"lciaMethods":[{"id":"503699e0-eca9-4089-8bf8-e0f49c93e578","version":"01.01.000"}]}'::jsonb
  )->'processes',
  '[{"id": "64600000-0000-4000-8000-000000000010", "version": "02.00.000"}]'::jsonb,
  'an explicit subset of the surviving state-100 version still normalizes'
);

-- ------------------------------------------------------- eligible input manifest

select is(
  api.lcia_result_current_eligible_manifest()->>'predicateVersion',
  'published-state-code-100:latest-per-id:v2',
  'the eligible input manifest publishes the frozen predicate literal'
);
select is(
  api.lcia_result_current_eligible_manifest()->'inputStatusFilter',
  '{"state_code": {"eq": 100}}'::jsonb,
  'the eligible input manifest publishes an exact state-100 status filter'
);
select is(
  api.lcia_result_current_eligible_manifest()->'inputManifest'->>'predicateVersion',
  api.lcia_result_current_eligible_manifest()->>'predicateVersion',
  'the manifest body repeats the same predicate literal as the envelope'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      api.lcia_result_current_eligible_manifest()->'inputManifest'->'processes'
    ) as entry(value)
    where entry.value->>'id' in (
      '64600000-0000-4000-8000-000000000012',
      '64600000-0000-4000-8000-000000000014',
      '64600000-0000-4000-8000-000000000013',
      '64600000-0000-4000-8000-000000000015'
    )
  ),
  0::bigint,
  'the eligible input manifest lists no Result, draft, or reserved-state process'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      api.lcia_result_current_eligible_manifest()->'inputManifest'->'processes'
    ) as entry(value)
    where entry.value->>'id' = '64600000-0000-4000-8000-000000000010'
      and entry.value->>'version' = '01.00.000'
  ),
  0::bigint,
  'the migrated exact version is absent from the eligible input manifest'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      api.lcia_result_current_eligible_manifest()->'inputManifest'->'processes'
    ) as entry(value)
    where entry.value->>'id' = '64600000-0000-4000-8000-000000000010'
  ),
  1::bigint,
  'latest-per-id contributes exactly one entry for a partially migrated identity'
);
select is(
  (
    select entry.value->>'version'
    from jsonb_array_elements(
      api.lcia_result_current_eligible_manifest()->'inputManifest'->'processes'
    ) as entry(value)
    where entry.value->>'id' = '64600000-0000-4000-8000-000000000010'
  ),
  '02.00.000',
  'latest-per-id selects the highest state-100 version'
);
select is(
  (
    select count(*)
    from jsonb_array_elements(
      api.lcia_result_current_eligible_manifest()->'inputManifest'->'processes'
    ) as entry(value)
    where (entry.value->>'stateCode')::integer <> 100
  ),
  0::bigint,
  'every manifest process entry carries state code 100'
);
select is(
  api.lcia_result_current_eligible_manifest()->>'eligibleInputCount',
  api.lcia_result_current_eligible_manifest()->>'includedInputCount',
  'the global eligible manifest reports equal eligible and included counts'
);
select is(
  api.lcia_result_current_eligible_manifest()->>'inputManifestHash',
  md5(
    (
      select coalesce(
        string_agg(
          (entry.value->>'id') || ':' || (entry.value->>'version'),
          ',' order by entry.value->>'id', entry.value->>'version'
        ),
        ''
      )
      from jsonb_array_elements(
        api.lcia_result_current_eligible_manifest()->'inputManifest'->'processes'
      ) as entry(value)
    ) || '|published:100:latest-per-id:v2'
  ),
  'the manifest hash is reproducible from the emitted process list and its literal'
);

-- --------------------------------------------------------- formal release binding

insert into private.lca_release_runs(
  id, release_version, selection_manifest_hash, input_manifest_hash,
  calculation_bundle_hash, calculation_bundle_ref, profile_lock_hash,
  publish_plan_hash, publish_plan, artifact_set_hash, release_manifest_hash,
  release_manifest, status, idempotency_key, request_hash, created_by
) values (
  '64600000-0000-4000-8000-000000000040', '88.00.001', repeat('a', 64),
  repeat('b', 64), repeat('c', 64), '{}', repeat('d', 64), repeat('e', 64),
  '{}', repeat('f', 64), repeat('9', 64), '{}', 'published',
  'state120-release', repeat('1', 64), '64600000-0000-4000-8000-000000000001'
);
insert into private.lca_release_approvals(
  id, release_run_id, publish_plan_hash, approval_hash, approved_by,
  approved_at, expires_at
) values (
  '64600000-0000-4000-8000-000000000041',
  '64600000-0000-4000-8000-000000000040', repeat('e', 64), repeat('2', 64),
  '64600000-0000-4000-8000-000000000001', now(), now() + interval '1 day'
);
insert into private.lca_release_publications(
  id, release_run_id, release_version, approval_id, approval_hash,
  publish_plan_hash, release_manifest_hash, artifact_set_hash, approved_by,
  executed_by, credential_fingerprint, idempotency_key, published_at
) values (
  '64600000-0000-4000-8000-000000000042',
  '64600000-0000-4000-8000-000000000040', '88.00.001',
  '64600000-0000-4000-8000-000000000041', repeat('2', 64), repeat('e', 64),
  repeat('9', 64), repeat('f', 64),
  '64600000-0000-4000-8000-000000000001',
  '64600000-0000-4000-8000-000000000001', repeat('3', 64),
  'state120-publication', now()
);
-- The exact release dataset index contract: one self-mapped Unit Process, one
-- LifecycleModel and one Result Process per source Process, plus support data.
-- Result roles belong to this immutable index and never to the numeric axis.
insert into private.lca_release_dataset_versions(
  release_run_id, dataset_type, dataset_role, dataset_uuid, dataset_version,
  source_process_uuid, source_process_version, version_significant_hash,
  semantic_hash, canonical_content_hash, artifact_ref
) values
(
  '64600000-0000-4000-8000-000000000040', 'process', 'unit_process',
  '64600000-0000-4000-8000-000000000050', '01.00.000',
  '64600000-0000-4000-8000-000000000050', '01.00.000',
  repeat('4', 64), repeat('5', 64), repeat('6', 64), '{}'
),
(
  '64600000-0000-4000-8000-000000000040', 'lifecyclemodel', 'lifecycle_model',
  '64600000-0000-4000-8000-000000000051', '01.00.000',
  '64600000-0000-4000-8000-000000000050', '01.00.000',
  repeat('7', 64), repeat('8', 64), repeat('9', 64), '{}'
),
(
  '64600000-0000-4000-8000-000000000040', 'process', 'result_process',
  '64600000-0000-4000-8000-000000000052', '01.00.000',
  '64600000-0000-4000-8000-000000000050', '01.00.000',
  repeat('a', 64), repeat('b', 64), repeat('c', 64), '{}'
),
(
  '64600000-0000-4000-8000-000000000040', 'lciamethod', 'support',
  '64600000-0000-4000-8000-000000000054', '01.01.000',
  null, null, repeat('d', 64), repeat('e', 64), repeat('f', 64), '{}'
);

select is(
  (
    select count(*)
    from private.lca_release_dataset_versions
    where release_run_id = '64600000-0000-4000-8000-000000000040'
      and dataset_role in ('result_process', 'lifecycle_model')
  ),
  2::bigint,
  'the formal release index carries explicit Result and LifecycleModel roles'
);
select is(
  (
    select count(*)
    from private.lca_release_dataset_versions
    where release_run_id = '64600000-0000-4000-8000-000000000040'
      and dataset_type = 'process'
      and dataset_role = 'unit_process'
  ),
  1::bigint,
  'exactly one process row is a unit_process numeric member'
);
select ok(
  position(
    'dataset_role = ''unit_process'''
    in pg_get_functiondef(
      'private.lcia_scope_closure_normalize_request(jsonb)'::regprocedure
    )
  ) > 0,
  'release-bound normalization keeps its exact unit_process role filter'
);
select is(
  private.lcia_scope_closure_normalize_request(
    jsonb_build_object(
      'coverageMode', 'global_eligible',
      'lciaMethods', jsonb_build_array(jsonb_build_object(
        'id', '64600000-0000-4000-8000-000000000054',
        'version', '01.01.000'
      ))
    )
  )->>'eligibilityPredicateVersion',
  'current-public-release-manifest:v2',
  'with a current release the predicate switches to the formal manifest'
);
select is(
  private.lcia_scope_closure_normalize_request(
    jsonb_build_object(
      'coverageMode', 'global_eligible',
      'lciaMethods', jsonb_build_array(jsonb_build_object(
        'id', '64600000-0000-4000-8000-000000000054',
        'version', '01.01.000'
      ))
    )
  )->'processes',
  '[{"id": "64600000-0000-4000-8000-000000000050", "version": "01.00.000"}]'::jsonb,
  'release-bound global eligibility exposes only the unit_process member'
);
select throws_ok(
  $sql$
    select private.lcia_scope_closure_normalize_request(
      '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000052","version":"01.00.000"}],"lciaMethods":[{"id":"64600000-0000-4000-8000-000000000054","version":"01.01.000"}]}'::jsonb
    )
  $sql$,
  '22023',
  'process_not_in_current_public_release',
  'a release Result Process is refused as an explicit subset member'
);
select throws_ok(
  $sql$
    select private.lcia_scope_closure_normalize_request(
      '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000051","version":"01.00.000"}],"lciaMethods":[{"id":"64600000-0000-4000-8000-000000000054","version":"01.01.000"}]}'::jsonb
    )
  $sql$,
  '22023',
  'process_not_in_current_public_release',
  'a release LifecycleModel identity is refused as an explicit process member'
);
select throws_ok(
  $sql$
    select private.lcia_scope_closure_normalize_request(
      '{"coverageMode":"subset","processes":[{"id":"64600000-0000-4000-8000-000000000010","version":"02.00.000"}],"lciaMethods":[{"id":"64600000-0000-4000-8000-000000000054","version":"01.01.000"}]}'::jsonb
    )
  $sql$,
  '22023',
  'process_not_in_current_public_release',
  'a live state-100 process outside the release manifest is refused'
);

-- ------------------------------------------- guarded stale-publication boundary

-- The real consumer that compares a recorded package eligibility binding against
-- the live manifest. It is exercised directly so the rejection is proven at the
-- guard rather than inferred from a literal comparison.
insert into private.worker_jobs(
  id, job_kind, worker_queue, worker_runtime, status, priority,
  max_attempts, requester_type, visibility, payload_schema_version, payload_json
) values
(
  '64600000-0000-4000-8000-000000000060',
  'lcia_result.package_build', 'solver', 'calculator', 'completed', 0,
  3, 'operator', 'operator', 'lcia_result.package_build.request.v1',
  '{"type":"lcia_result_package_build"}'
),
(
  '64600000-0000-4000-8000-000000000066',
  'lcia_result.package_build', 'solver', 'calculator', 'completed', 0,
  3, 'operator', 'operator', 'lcia_result.package_build.request.v1',
  '{"type":"lcia_result_package_build"}'
);
insert into private.lca_network_snapshots(id, scope, status)
values ('64600000-0000-4000-8000-000000000061', 'full_library', 'ready');
insert into private.lca_results(id, job_id, snapshot_id, worker_job_id, artifact_url)
values (
  '64600000-0000-4000-8000-000000000062',
  '64600000-0000-4000-8000-000000000060',
  '64600000-0000-4000-8000-000000000061',
  '64600000-0000-4000-8000-000000000060',
  's3://state120-test/result.json'
);

-- Stale evidence: the retired predicate literal, its retired status filter, and a
-- manifest hash that no longer matches the live eligible set.
insert into private.lcia_result_packages(
  id, build_id, build_worker_job_id, package_version, coverage_mode,
  input_status_filter, eligibility_definition, eligibility_resolved_at,
  eligible_input_count, included_input_count, input_manifest_hash,
  input_manifest, snapshot_id, result_id, result_artifact_ref, status,
  created_by
) values (
  '64600000-0000-4000-8000-000000000063',
  '64600000-0000-4000-8000-000000000060',
  '64600000-0000-4000-8000-000000000060',
  '01.00.001', 'global_eligible',
  '{"state_code": {"between": [100, 199]}}'::jsonb,
  '{"predicateVersion": "published-state-code-100-199:latest-per-id:v1"}'::jsonb,
  now(),
  (select (api.lcia_result_current_eligible_manifest()->>'eligibleInputCount')::integer + 1),
  (select (api.lcia_result_current_eligible_manifest()->>'eligibleInputCount')::integer + 1),
  repeat('b', 32),
  '{"predicateVersion": "published-state-code-100-199:latest-per-id:v1", "selectionMode": "all_eligible", "processes": []}'::jsonb,
  '64600000-0000-4000-8000-000000000061',
  '64600000-0000-4000-8000-000000000062',
  '{"artifactUrl": "s3://state120-test/result.json"}'::jsonb,
  'preview_ready',
  '64600000-0000-4000-8000-000000000001'
);

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '64600000-0000-4000-8000-000000000001', true);
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"64600000-0000-4000-8000-000000000001"}',
  true
);

select is(
  api.cmd_lcia_result_package_publish(
    '64600000-0000-4000-8000-000000000063', 'climate-change', null
  )->>'code',
  'package_stale_eligibility',
  'the guarded publisher rejects a package bound to the retired 100..199 predicate'
);
select is(
  (
    select count(*)
    from private.command_audit_log
    where command = 'cmd_lcia_result_package_publish'
  ),
  0::bigint,
  'the guarded rejection writes no publication audit row'
);
select is(
  (
    select count(*)
    from private.lcia_result_publications
    where package_id = '64600000-0000-4000-8000-000000000063'
  ),
  0::bigint,
  'the guarded rejection creates no publication row'
);

select is(
  (
    select input_manifest_hash is distinct from
      api.lcia_result_current_eligible_manifest()->>'inputManifestHash'
    from private.lcia_result_packages
    where id = '64600000-0000-4000-8000-000000000063'
  ),
  true,
  'the rejected package still carries its retired eligibility binding'
);
select is(
  (
    select eligible_input_count is distinct from
      (api.lcia_result_current_eligible_manifest()->>'eligibleInputCount')::integer
    from private.lcia_result_packages
    where id = '64600000-0000-4000-8000-000000000063'
  ),
  true,
  'the rejected package still carries its retired eligible input count'
);

-- Positive control: a second package whose recorded binding matches the live
-- manifest. It proves the rejection above is caused by eligibility drift rather
-- than by an unrelated package defect. The preview_ready immutability guard forbids
-- editing the stale package, so this is a separate row.
insert into private.lcia_result_packages(
  id, build_id, build_worker_job_id, package_version, coverage_mode,
  input_status_filter, eligibility_definition, eligibility_resolved_at,
  eligible_input_count, included_input_count, input_manifest_hash,
  input_manifest, snapshot_id, result_id, result_artifact_ref, status,
  created_by
) values (
  '64600000-0000-4000-8000-000000000064',
  '64600000-0000-4000-8000-000000000065',
  '64600000-0000-4000-8000-000000000066',
  '01.00.002', 'global_eligible',
  api.lcia_result_current_eligible_manifest()->'inputStatusFilter',
  jsonb_build_object(
    'predicateVersion', api.lcia_result_current_eligible_manifest()->>'predicateVersion'
  ),
  now(),
  (api.lcia_result_current_eligible_manifest()->>'eligibleInputCount')::integer,
  (api.lcia_result_current_eligible_manifest()->>'eligibleInputCount')::integer,
  api.lcia_result_current_eligible_manifest()->>'inputManifestHash',
  api.lcia_result_current_eligible_manifest()->'inputManifest',
  '64600000-0000-4000-8000-000000000061',
  '64600000-0000-4000-8000-000000000062',
  '{"artifactUrl": "s3://state120-test/result.json"}'::jsonb,
  'preview_ready',
  '64600000-0000-4000-8000-000000000001'
);

select is(
  api.cmd_lcia_result_package_publish(
    '64600000-0000-4000-8000-000000000064', 'climate-change', null
  )->>'ok',
  'true',
  'the guarded publisher accepts a package bound to the current predicate'
);
select is(
  (
    select count(*)
    from private.lcia_result_publications
    where package_id = '64600000-0000-4000-8000-000000000064'
      and is_current = true
  ),
  1::bigint,
  'an accepted publication is recorded exactly once'
);
select is(
  (
    select count(*)
    from private.lcia_result_publications
    where package_id = '64600000-0000-4000-8000-000000000063'
  ),
  0::bigint,
  'the stale package still has no publication row after the control succeeds'
);

reset role;

-- ------------------------------------------------------------------ ACL closure

select ok(
  not has_function_privilege(
    'anon',
    'private.lcia_scope_closure_normalize_request(jsonb)',
    'execute'
  ),
  'anonymous callers cannot normalize a closure scope'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.lcia_scope_closure_normalize_request(jsonb)',
    'execute'
  ),
  'authenticated callers cannot normalize a closure scope directly'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'api.lcia_result_current_eligible_manifest()',
    'execute'
  ),
  'the eligible input manifest is not directly callable by authenticated callers'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.lcia_scope_closure_refresh_candidate_document_hash()',
    'execute'
  ),
  'the candidate cache trigger function is not directly callable'
);
select ok(
  has_function_privilege(
    'api_internal_executor',
    'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)',
    'execute'
  ),
  'only the internal api executor may run bounded candidate cache maintenance'
);
select ok(
  not has_function_privilege(
    'anon',
    'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'private.maintain_lcia_scope_closure_candidate_cache(integer,integer)',
    'execute'
  ),
  'browser roles cannot run candidate cache maintenance'
);
select ok(
  has_function_privilege(
    'api_internal_executor',
    'private.lcia_scope_closure_candidate_dataset_manifest()',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'private.lcia_scope_closure_candidate_dataset_manifest()',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'private.lcia_scope_closure_candidate_dataset_manifest()',
    'execute'
  ),
  'the gated candidate manifest keeps its internal-only execute boundary'
);
select ok(
  not has_function_privilege(
    'anon',
    'private.lcia_scope_closure_assert_candidate_cache_current()',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'private.lcia_scope_closure_assert_candidate_cache_current()',
    'execute'
  ),
  'the candidate cache gate is not directly callable by browser roles'
);

select * from finish();
rollback;
