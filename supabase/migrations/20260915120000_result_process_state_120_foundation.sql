-- Database #646 / workspace #1201: Result Process publication state 120 foundation.
--
-- This additive slice makes state 120 expressible on public.processes and narrows
-- three explicit surfaces that currently treat the whole 100..199 reserved range as
-- numerically eligible:
--   * the no-current-release candidate closure scope (global and subset),
--   * the processes row of the candidate document hash cache,
--   * the LCIA result current eligible input manifest.
--
-- Scope boundary, stated exactly: this is a partial numeric-input isolation step.
-- It does NOT establish sole authoritative Result role proof, and it does not by
-- itself prove that every calculation entrance excludes a state-120 Process.
-- Owner-draft/demand paths, provider discovery and expansion, snapshot builder
-- filters, existing-release live-state handling, and the remaining Worker/Edge
-- surfaces belong to the coordinated follow-up scope. Public read permission is
-- explicitly unchanged: state 120 grants no wider numeric access.
--
-- It also deliberately does NOT:
--   * add a Result role/identity proof relation,
--   * add a Result publishing command or any review/withdrawal semantics,
--   * migrate an existing state-100 row to 120,
--   * change any Portal projection or public read permission.
-- Those remain tracked follow-up scope; see the delivery Issue.
--
-- Formal release membership (private.lca_release_dataset_versions) is unchanged and
-- stays the authoritative role source for release-bound calculation input. Its
-- unit_process filter is already exact and this migration leaves it byte-identical;
-- tests re-assert that Result and LifecycleModel roles stay outside the numeric axis.

BEGIN;

-- 1) public.processes gains 120 and keeps every pre-existing accepted value.
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.processes DROP CONSTRAINT processes_state_code_check;
ALTER TABLE public.processes ADD CONSTRAINT processes_state_code_check
  CHECK (state_code IN (-1, 0, 20, 100, 120, 200));
RESET lock_timeout;

-- 2) No-current-release (candidate) numeric eligibility is exactly state 100.
--    The formal-release branch above it is untouched: it remains bound to exact
--    unit_process membership and never selects a Result role.
create or replace function private.lcia_scope_closure_normalize_request(p_requested_scope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = 'private', 'api', 'public', 'util', 'extensions', 'pg_temp'
as $$
declare
  v_mode text := lower(trim(coalesce(p_requested_scope->>'coverageMode', '')));
  v_processes jsonb;
  v_methods jsonb;
  v_policy jsonb;
  v_freshness text;
  v_release_id uuid;
  v_count integer;
  v_requested integer;
  v_duplicate integer;
  v_predicate text;
begin
  if jsonb_typeof(coalesce(p_requested_scope, 'null'::jsonb)) <> 'object'
     or v_mode not in ('subset', 'global_eligible') then
    raise exception using errcode = '22023', message = 'invalid_closure_scope';
  end if;
  if jsonb_typeof(coalesce(p_requested_scope->'processes', '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_requested_scope->'lciaMethods', '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'invalid_closure_scope_identity_list';
  end if;

  select release_run_id
  into v_release_id
  from private.lca_release_publications
  where is_current = true and status = 'current'
  order by published_at desc
  limit 1;

  if v_release_id is not null then
    v_predicate := 'current-public-release-manifest:v2';
    if v_mode = 'global_eligible' then
      if jsonb_array_length(coalesce(p_requested_scope->'processes', '[]'::jsonb)) <> 0 then
        raise exception using errcode = '22023', message = 'global_eligible_scope_must_not_supply_processes';
      end if;
      select coalesce(jsonb_agg(
        jsonb_build_object('id', dataset_uuid, 'version', dataset_version)
        order by dataset_uuid, dataset_version
      ), '[]'::jsonb)
      into v_processes
      from private.lca_release_dataset_versions
      where release_run_id = v_release_id
        and dataset_type = 'process'
        and dataset_role = 'unit_process';
      if jsonb_array_length(v_processes) = 0 then
        raise exception using errcode = '22023', message = 'current_release_has_no_eligible_processes';
      end if;
    else
      with requested as (
        select (item.value->>'id')::uuid as id,
          btrim(item.value->>'version') as version
        from jsonb_array_elements(p_requested_scope->'processes') item(value)
      ),
      resolved as (
        select r.id, r.version
        from requested r
        join private.lca_release_dataset_versions d
          on d.release_run_id = v_release_id
         and d.dataset_type = 'process'
         and d.dataset_role = 'unit_process'
         and d.dataset_uuid = r.id
         and d.dataset_version = r.version
      )
      select count(*), (select count(*) from requested),
        (select count(*) - count(distinct (id, version)) from requested),
        coalesce(jsonb_agg(
          jsonb_build_object('id', id, 'version', version) order by id, version
        ), '[]'::jsonb)
      into v_count, v_requested, v_duplicate, v_processes
      from resolved;
      if coalesce(v_requested, 0) = 0 or v_count <> v_requested or v_duplicate <> 0 then
        raise exception using errcode = '22023', message = 'process_not_in_current_public_release';
      end if;
    end if;

    with requested as (
      select (item.value->>'id')::uuid as id,
        btrim(item.value->>'version') as version
      from jsonb_array_elements(p_requested_scope->'lciaMethods') item(value)
    ),
    resolved as (
      select r.id, r.version
      from requested r
      join private.lca_release_dataset_versions d
        on d.release_run_id = v_release_id
       and d.dataset_type = 'lciamethod'
       and d.dataset_uuid = r.id
       and d.dataset_version = r.version
    )
    select count(*), (select count(*) from requested),
      (select count(*) - count(distinct (id, version)) from requested),
      coalesce(jsonb_agg(
        jsonb_build_object('id', id, 'version', version) order by id, version
      ), '[]'::jsonb)
    into v_count, v_requested, v_duplicate, v_methods
    from resolved;
    if coalesce(v_requested, 0) = 0 or v_count <> v_requested or v_duplicate <> 0 then
      raise exception using errcode = '22023', message = 'lcia_method_not_in_current_public_release';
    end if;
  else
    v_predicate := 'candidate-public-state-code-100:v2';
    if v_mode = 'global_eligible' then
      if jsonb_array_length(coalesce(p_requested_scope->'processes', '[]'::jsonb)) <> 0 then
        raise exception using errcode = '22023', message = 'global_eligible_scope_must_not_supply_processes';
      end if;
      with ranked as (
        select p.id, btrim(p.version::text) as version,
          row_number() over (
            partition by p.id
            order by btrim(p.version::text) desc, p.modified_at desc nulls last
          ) as rank
        from public.processes p
        where p.state_code = 100
          and p.json_ordered is not null
      )
      select coalesce(jsonb_agg(
        jsonb_build_object('id', id, 'version', version) order by id, version
      ), '[]'::jsonb)
      into v_processes
      from ranked
      where rank = 1;
      if jsonb_array_length(v_processes) = 0 then
        raise exception using errcode = '22023', message = 'candidate_scope_has_no_eligible_processes';
      end if;
    else
      with requested as (
        select (item.value->>'id')::uuid as id,
          btrim(item.value->>'version') as version
        from jsonb_array_elements(p_requested_scope->'processes') item(value)
      ),
      resolved as (
        select r.id, r.version
        from requested r
        join public.processes p
          on p.id = r.id
         and btrim(p.version::text) = r.version
         and p.state_code = 100
         and p.json_ordered is not null
      )
      select count(*), (select count(*) from requested),
        (select count(*) - count(distinct (id, version)) from requested),
        coalesce(jsonb_agg(
          jsonb_build_object('id', id, 'version', version) order by id, version
        ), '[]'::jsonb)
      into v_count, v_requested, v_duplicate, v_processes
      from resolved;
      if coalesce(v_requested, 0) = 0 or v_count <> v_requested or v_duplicate <> 0 then
        raise exception using errcode = '22023', message = 'invalid_or_ineligible_process_selection';
      end if;
    end if;

    with requested as (
      select (item.value->>'id')::uuid as id,
        btrim(item.value->>'version') as version
      from jsonb_array_elements(p_requested_scope->'lciaMethods') item(value)
    ),
    eligible_methods as (
      select reviewed.method_id as id,
        reviewed.method_version as version
      from public.lciamethods m
      join private.lcia_scope_closure_reviewed_lcia_methods reviewed
        on reviewed.artifact_locator_id = m.id
       and reviewed.method_version = btrim(m.version::text)
      where coalesce(m.json, m.json_ordered::jsonb) is not null
    ),
    resolved as (
      select r.id, r.version
      from requested r
      join eligible_methods m using (id, version)
    )
    select count(*), (select count(*) from requested),
      (select count(*) - count(distinct (id, version)) from requested),
      coalesce(jsonb_agg(
        jsonb_build_object('id', id, 'version', version) order by id, version
      ), '[]'::jsonb)
    into v_count, v_requested, v_duplicate, v_methods
    from resolved;
    if coalesce(v_requested, 0) = 0 or v_count <> v_requested or v_duplicate <> 0 then
      raise exception using errcode = '22023', message = 'invalid_lcia_method_selection';
    end if;
  end if;

  v_freshness := coalesce(
    nullif(trim(p_requested_scope->>'certificateFreshnessPolicy'), ''),
    'frozen-artifact-reusable-v1'
  );
  if v_freshness not in (
    'frozen-artifact-reusable-v1',
    'current-membership-required-v1'
  ) then
    raise exception using errcode = '22023', message = 'invalid_certificate_freshness_policy';
  end if;

  v_policy := coalesce(p_requested_scope->'linkPolicy', '{}'::jsonb);
  if jsonb_typeof(v_policy) <> 'object'
     or coalesce(v_policy->>'linkSemanticsVersion', 'signed-flow-balance-v1') <> 'signed-flow-balance-v1'
     or coalesce(v_policy->>'flowIdentityPolicy', 'exact-flow-version-reference-unit-v2') <> 'exact-flow-version-reference-unit-v2'
     or coalesce(v_policy->>'allocationSemanticsVersion', 'tidas-reference-allocation-v3') <> 'tidas-reference-allocation-v3'
     or coalesce(v_policy->>'technosphereBoundaryPolicy', 'cutoff') not in ('closed', 'open', 'cutoff')
     or coalesce(v_policy->>'providerUniversePolicy', 'scope_only') not in ('scope_only', 'eligible_transitive_expansion-v1') then
    raise exception using errcode = '22023', message = 'invalid_closure_link_policy';
  end if;

  return jsonb_build_object(
    'schemaVersion', 'lcia.scope-manifest.v1',
    'coverageMode', v_mode,
    'eligibilityPredicateVersion', v_predicate,
    'processes', v_processes,
    'lciaMethods', v_methods,
    'versionResolutionPolicy', 'reference-version-resolution-v1',
    'legacyOmittedVersionPolicy', 'reject',
    'certificateFreshnessPolicy', v_freshness,
    'linkPolicy', jsonb_build_object(
      'linkSemanticsVersion', 'signed-flow-balance-v1',
      'flowIdentityPolicy', 'exact-flow-version-reference-unit-v2',
      'allocationSemanticsVersion', 'tidas-reference-allocation-v3',
      'technosphereBoundaryPolicy', 'cutoff',
      'providerUniversePolicy',
        coalesce(v_policy->>'providerUniversePolicy', 'scope_only')
    ),
    'processManifestHash',
      private.lcia_scope_closure_sha256(jsonb_build_object('processes', v_processes))
  );
exception
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'invalid_scope_identity';
end;
$$;

ALTER FUNCTION private.lcia_scope_closure_normalize_request(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.lcia_scope_closure_normalize_request(jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION private.lcia_scope_closure_normalize_request(jsonb) TO service_role;
GRANT ALL ON FUNCTION private.lcia_scope_closure_normalize_request(jsonb) TO api_internal_executor;

-- 3) The numeric candidate hash cache excludes Result Processes.
--    Only the processes branch changes: its state predicate becomes exactly 100.
--    The lciamethods branch and the support predicate for every other dataset type
--    are retained verbatim, so candidate support semantics are untouched. The cache
--    keeps exactly its two existing role values; no Result role is introduced.
create or replace function private.lcia_scope_closure_refresh_candidate_document_hash()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_document jsonb;
  v_dataset_id uuid;
  v_role text;
  v_is_eligible boolean;
begin
  if tg_op <> 'INSERT' then
    delete from private.lcia_scope_closure_candidate_document_hashes
    where dataset_type = tg_table_name
      and source_locator_id = old.id
      and dataset_version = btrim(old.version::text);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  if tg_table_name = 'lciamethods' then
    -- LCIA methods are the separately reviewed 25-method static bundle. Their
    -- authoring lifecycle state_code remains 0 in production and is not the
    -- candidate-public-data eligibility predicate used by other datasets.
    v_document := coalesce(new.json, new.json_ordered::jsonb);
    v_is_eligible := v_document is not null;
    v_dataset_id := private.lcia_scope_closure_lcia_method_identity(
      new.id,
      btrim(new.version::text),
      v_document
    );
    v_is_eligible := v_is_eligible and exists (
      select 1
      from private.lcia_scope_closure_reviewed_lcia_methods reviewed
      where reviewed.method_id = v_dataset_id
        and reviewed.method_version = btrim(new.version::text)
        and reviewed.artifact_locator_id = new.id
    );
    v_role := 'support';
  else
    v_document := new.json_ordered::jsonb;
    -- Only the processes numeric axis is narrowed to exactly 100. Every other
    -- candidate dataset keeps its existing support eligibility predicate verbatim;
    -- this slice does not redefine support data rules.
    v_is_eligible := case
      when tg_table_name = 'processes' then new.state_code = 100
      else new.state_code between 100 and 199
    end and v_document is not null;
    v_dataset_id := new.id;
    v_role := case
      when tg_table_name = 'processes' then 'unit_process'
      else 'support'
    end;
  end if;

  if v_is_eligible then
    insert into private.lcia_scope_closure_candidate_document_hashes(
      dataset_type,
      dataset_id,
      dataset_version,
      source_locator_id,
      role,
      canonical_content_hash,
      source_modified_at,
      refreshed_at
    ) values (
      tg_table_name,
      v_dataset_id,
      btrim(new.version::text),
      new.id,
      v_role,
      private.lcia_scope_closure_worker_canonical_sha256(v_document),
      new.modified_at,
      now()
    )
    on conflict (dataset_type, dataset_id, dataset_version)
    do update set
      source_locator_id = excluded.source_locator_id,
      role = excluded.role,
      canonical_content_hash = excluded.canonical_content_hash,
      source_modified_at = excluded.source_modified_at,
      refreshed_at = excluded.refreshed_at;
  end if;

  return new;
end;
$$;

ALTER FUNCTION private.lcia_scope_closure_refresh_candidate_document_hash() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.lcia_scope_closure_refresh_candidate_document_hash() FROM PUBLIC;
GRANT ALL ON FUNCTION private.lcia_scope_closure_refresh_candidate_document_hash() TO api_internal_executor;

-- 4) Current eligible input manifest is exactly state 100 latest-per-id.
create or replace function api.lcia_result_current_eligible_manifest()
returns jsonb
language sql
stable
security definer
set search_path = 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
as $$
  with eligible as (
    select distinct on (id)
      id,
      version,
      state_code
    from public.processes
    where state_code = 100
      and json ? 'processDataSet'
    order by id, version desc, modified_at desc
  ),
  aggregated as (
    select
      count(*)::integer as eligible_count,
      md5(
        coalesce(
          string_agg(id::text || ':' || version, ',' order by id, version),
          ''
        ) || '|published:100:latest-per-id:v2'
      ) as input_manifest_hash,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', id,
            'version', version,
            'stateCode', state_code
          )
          order by id, version
        ),
        '[]'::jsonb
      ) as processes
    from eligible
  )
  select jsonb_build_object(
    'predicateVersion', 'published-state-code-100:latest-per-id:v2',
    'inputStatusFilter', jsonb_build_object(
      'state_code',
      jsonb_build_object('eq', 100)
    ),
    'eligibleInputCount', eligible_count,
    'includedInputCount', eligible_count,
    'inputManifestHash', input_manifest_hash,
    'inputManifest', jsonb_build_object(
      'predicateVersion', 'published-state-code-100:latest-per-id:v2',
      'selectionMode', 'all_eligible',
      'processes', processes
    )
  )
  from aggregated
$$;

ALTER FUNCTION api.lcia_result_current_eligible_manifest() OWNER TO postgres;
REVOKE ALL ON FUNCTION api.lcia_result_current_eligible_manifest() FROM PUBLIC;
GRANT ALL ON FUNCTION api.lcia_result_current_eligible_manifest() TO api_internal_executor;

-- 5) Cache hygiene and fail-closed gate for pre-existing rows.
--
-- On a fresh or forward-only database the narrowed trigger already removes the
-- exact candidate when a row leaves state 100, so nothing is left behind. A
-- database that already recorded cache rows under the old 100..199 rule cannot be
-- repaired by the trigger alone. Those rows would otherwise still be frozen into a
-- candidate manifest, so they are never allowed to stay silently visible: the
-- manifest accessor refuses to serve while any invalid row exists.
--
-- The migration reports only a bounded sample (the first 1000 primary keys of the
-- processes rows) and mutates nothing, so it stays safe on partial and repeated
-- application. The sample count is evidence that maintenance is pending, not a
-- bound on total table cardinality and not a full population count.
do $hygiene$
declare
  v_sampled bigint;
  v_sampled_invalid bigint;
begin
  with sample as (
    select
      cache.source_locator_id,
      cache.dataset_version
    from private.lcia_scope_closure_candidate_document_hashes as cache
    where cache.dataset_type = 'processes'
    order by cache.dataset_id, cache.dataset_version
    limit 1000
  )
  select
    count(*),
    count(*) filter (
      where not exists (
        select 1
        from public.processes as process_row
        where process_row.id = sample.source_locator_id
          and btrim(process_row.version::text) = sample.dataset_version
          and process_row.state_code = 100
          and process_row.json_ordered is not null
      )
    )
  into v_sampled, v_sampled_invalid
  from sample;

  raise notice
    'lcia_scope_closure candidate cache: % of % sampled process rows are no longer numerically eligible; call private.maintain_lcia_scope_closure_candidate_cache(integer, integer) repeatedly before enabling state-120 publication',
    v_sampled_invalid,
    v_sampled;
end
$hygiene$;

-- Fail-closed gate. The Worker-facing candidate manifest is the frozen numeric
-- universe, so it must not be produced from a cache that still holds rows the
-- narrowed predicate rejects. This is an unambiguous safety gate rather than a
-- silent narrowing: while invalid rows exist the manifest errors, and it starts
-- serving again as soon as the bounded maintenance operation above drains them.
create or replace function private.lcia_scope_closure_assert_candidate_cache_current()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from private.lcia_scope_closure_candidate_document_hashes as cache
    left join public.processes as process_row
      on process_row.id = cache.source_locator_id
     and btrim(process_row.version::text) = cache.dataset_version
    where cache.dataset_type = 'processes'
      and (
        process_row.id is null
        or process_row.state_code is distinct from 100
        or process_row.json_ordered is null
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'candidate_cache_not_current',
      detail = 'Run private.maintain_lcia_scope_closure_candidate_cache(integer, integer) until moreRemaining is false.';
  end if;
end;
$$;

ALTER FUNCTION private.lcia_scope_closure_assert_candidate_cache_current() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.lcia_scope_closure_assert_candidate_cache_current() FROM PUBLIC;
GRANT ALL ON FUNCTION private.lcia_scope_closure_assert_candidate_cache_current() TO api_internal_executor;

-- The manifest accessor keeps its exact signature, argument list and output shape;
-- it gains only the fail-closed gate before it freezes the universe.
create or replace function private.lcia_scope_closure_candidate_dataset_manifest()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_manifest jsonb;
begin
  perform private.lcia_scope_closure_assert_candidate_cache_current();

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'datasetType', dataset_type,
      'datasetId', dataset_id,
      'datasetVersion', dataset_version,
      'role', role,
      -- Worker v2 requires all three hashes.  Candidate snapshots define each
      -- compatibility field over the exact frozen full document.
      'versionSignificantHash', canonical_content_hash,
      'semanticHash', canonical_content_hash,
      'canonicalContentHash', canonical_content_hash
    )
    order by dataset_type, dataset_id, dataset_version, role
  ), '[]'::jsonb)
  into v_manifest
  from private.lcia_scope_closure_candidate_document_hashes;

  return v_manifest;
end;
$$;

ALTER FUNCTION private.lcia_scope_closure_candidate_dataset_manifest() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.lcia_scope_closure_candidate_dataset_manifest() FROM PUBLIC;
GRANT ALL ON FUNCTION private.lcia_scope_closure_candidate_dataset_manifest() TO api_internal_executor;

-- Separately named, forward-only cache maintenance. It removes only cache rows that
-- the narrowed predicate no longer accepts, at most p_max_rows per call, ordered by
-- the cache primary key so repeated calls make deterministic forward progress. It
-- never rebuilds eligible rows, never stores a new role value, and is idempotent.
-- It is intentionally not called by this migration.
--
-- Isolation and lock order, stated exactly.
--
-- Repeating an eligibility subquery inside the DELETE is NOT sufficient here. Under
-- Read Committed a command may re-evaluate an updated target row while still
-- observing the original statement snapshot of other tables, so a concurrent
-- public.processes insert or state change need not be visible to that subquery. The
-- removal therefore does not try to win a race; it removes the race by taking one
-- consistent order against source writers.
--
-- Protocol: acquire a SHARE ROW EXCLUSIVE lock on public.processes before reading
-- the cache, so the candidate decision and the delete share one snapshot that no
-- source write can invalidate. This lock is the database half of the
-- source-before-cache order that this repository's eligibility writers follow: a
-- source write takes a row lock on public.processes and its cache trigger writes the
-- cache later in the same transaction. Maintenance takes locks only in that same
-- direction, so it introduces no cycle against those writers. This is not a general
-- deadlock guarantee against arbitrary callers that take locks in another order.
--
-- SHARE ROW EXCLUSIVE conflicts with ROW EXCLUSIVE, so ordinary Process writers wait
-- for the fence instead of interleaving with the batch. p_lock_timeout_ms bounds only
-- acquisition of the fence: an existing holder causes lock_not_available (55P03),
-- reported as status=lock_timeout with removedCount 0 and moreRemaining true, and
-- maintenance retries later. It does not bound how long a writer can be blocked once
-- the fence is granted, and it does not bound the scan.
--
-- Caller contract, because a table lock is held until transaction end, not until
-- function return:
--   * call this in its own short autocommit transaction, one batch per transaction;
--   * do not call it inside a long enclosing transaction, or the fence is retained
--     for the whole enclosing transaction and blocks Process writers;
--   * bound total writer blocking with the caller's own statement_timeout set before
--     the call. Setting statement_timeout inside the function would not bound that
--     same statement's execution.
-- The caller's prior lock_timeout is restored on every return and error path.
--
-- Bounds, stated exactly: the fence excludes concurrent source writes for one batch;
-- the candidate selection reads at most p_max_rows rows and the residual probe reads
-- at most p_max_rows + 1 rows. remainingCount is exact when it is at most
-- p_max_rows and null otherwise, so it never claims a total it did not measure.
-- moreRemaining is true whenever any invalid row still exists. The operation does
-- not promise a bound on the total number of invalid rows present in the relation,
-- nor does the row limit bound the source scan: callers drain by repeating until
-- moreRemaining is false.
create or replace function private.maintain_lcia_scope_closure_candidate_cache(
  p_max_rows integer default 2000,
  p_lock_timeout_ms integer default 5000
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer := 0;
  v_remaining bigint;
  v_rows integer;
  v_previous_lock_timeout text := pg_catalog.current_setting('lock_timeout');
  v_result jsonb;
begin
  if p_max_rows is null or p_max_rows < 1 or p_max_rows > 10000 then
    raise exception using
      errcode = '22023',
      message = 'invalid_candidate_cache_maintenance_batch';
  end if;

  if p_lock_timeout_ms is null
     or p_lock_timeout_ms < 1
     or p_lock_timeout_ms > 60000 then
    raise exception using
      errcode = '22023',
      message = 'invalid_candidate_cache_maintenance_lock_timeout';
  end if;

  perform pg_catalog.set_config(
    'lock_timeout',
    p_lock_timeout_ms::text || 'ms',
    true
  );

  begin
    -- The fence. Any source write in flight either committed before this lock is
    -- granted, in which case its cache effect is already present and accounted for,
    -- or it starts after the batch completes.
    lock table public.processes in share row exclusive mode;
  exception
    when lock_not_available then
      perform pg_catalog.set_config('lock_timeout', v_previous_lock_timeout, true);
      return jsonb_build_object(
        'status', 'lock_timeout',
        'removedCount', 0,
        'remainingCount', null,
        'batchLimit', p_max_rows,
        'moreRemaining', true,
        'lockTimeoutMs', p_lock_timeout_ms
      );
  end;

  -- Candidate decision and delete are one statement, taken under the fence so the
  -- decision cannot be invalidated before the delete. The nested LIMIT subquery
  -- selects exactly p_max_rows identities in the same deterministic order used by
  -- the residual probe below, and the delete re-evaluates each cache row's primary
  -- key against that selection rather than deleting by a separately built key list.
  delete from private.lcia_scope_closure_candidate_document_hashes as cache
  where cache.dataset_type = 'processes'
    and (cache.dataset_id, cache.dataset_version) in (
      select target.dataset_id, target.dataset_version
      from (
        select cache_row.dataset_id, cache_row.dataset_version
        from private.lcia_scope_closure_candidate_document_hashes as cache_row
        left join public.processes as process_row
          on process_row.id = cache_row.source_locator_id
         and btrim(process_row.version::text) = cache_row.dataset_version
        where cache_row.dataset_type = 'processes'
          and (
            process_row.id is null
            or process_row.state_code is distinct from 100
            or process_row.json_ordered is null
          )
        order by cache_row.dataset_id, cache_row.dataset_version
        limit p_max_rows
      ) as target
    );
  get diagnostics v_rows = row_count;
  v_deleted := v_rows;

  -- Residual after this batch: one row past the limit is enough to decide whether
  -- more work remains; the exact total is never claimed.
  select count(*)
  into v_remaining
  from (
    select 1
    from private.lcia_scope_closure_candidate_document_hashes as cache
    left join public.processes as process_row
      on process_row.id = cache.source_locator_id
     and btrim(process_row.version::text) = cache.dataset_version
    where cache.dataset_type = 'processes'
      and (
        process_row.id is null
        or process_row.state_code is distinct from 100
        or process_row.json_ordered is null
      )
    limit p_max_rows + 1
  ) as probe;

  v_result := jsonb_build_object(
    'status', 'ok',
    'removedCount', v_deleted,
    'remainingCount',
      case when v_remaining > p_max_rows then null else v_remaining end,
    'batchLimit', p_max_rows,
    'moreRemaining', (v_remaining > 0),
    'lockTimeoutMs', p_lock_timeout_ms
  );

  perform pg_catalog.set_config('lock_timeout', v_previous_lock_timeout, true);
  return v_result;
exception
  when others then
    perform pg_catalog.set_config('lock_timeout', v_previous_lock_timeout, true);
    raise;
end;
$$;

ALTER FUNCTION private.maintain_lcia_scope_closure_candidate_cache(integer, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.maintain_lcia_scope_closure_candidate_cache(integer, integer) FROM PUBLIC;
GRANT ALL ON FUNCTION private.maintain_lcia_scope_closure_candidate_cache(integer, integer) TO api_internal_executor;

NOTIFY pgrst, 'reload schema';

COMMIT;
