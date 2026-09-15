-- Database #646 / workspace #1201: Result Process product-read isolation.
--
-- A published Result Process (state_code 120) must not appear in the product read
-- surfaces the unchanged Next and Portal clients already use. This migration adds that
-- exclusion; it adds no public Result API, no new state, no role, no grant widening, and
-- no Portal projection change.
--
-- Why two layers:
--   * Layer 1 is a restrictive SELECT policy on public.processes. Restrictive policies
--     AND with the permissive ones, so it closes every RLS-evaluated path without
--     granting anything: direct PostgREST relation reads from Next, and SECURITY INVOKER
--     functions owned by postgres, which execute as the caller and therefore do evaluate
--     RLS. It carries no owner, team, reviewer or manager exception.
--   * Layer 2 adds explicit predicates inside SECURITY DEFINER bodies owned by postgres,
--     which execute as postgres and consequently bypass row security entirely. Those
--     paths cannot be closed by any policy.
--
-- No caller-settable bypass exists in either layer: no GUC read, no current_user escape,
-- no helper. A superuser already bypasses row security, so no redundant escape is added.
--
-- Scope: only entity `processes`. Unit, Flow, FlowProperty, UnitGroup, Source, Contact
-- and LifecycleModel behaviour, including their own states and support reads, is
-- unchanged. Internal computation and management reads (eligible manifest, scope-closure
-- normalization and candidate cache, review and derivative-rebuild commands) are
-- deliberately untouched: they are already exact-100 or operator-scoped.

BEGIN;

-- 1) Restrictive SELECT policy: state 120 is never readable through a generic path.
--
-- `is distinct from 120` rather than `<> 120` so a NULL state stays visible exactly as
-- before; this policy only ever removes 120.
drop policy if exists result_process_no_generic_read on public.processes;
create policy result_process_no_generic_read on public.processes
  as restrictive
  for select
  to authenticated, anon
  using (state_code is distinct from 120);

-- The Portal and Next public executors already carry exact `in (100, 200)` permissive
-- policies, so 120 cannot reach them. The restrictive policy is extended to those roles
-- as well so a future permissive grant cannot silently reopen 120.
drop policy if exists result_process_no_generic_read_public_executor on public.processes;
create policy result_process_no_generic_read_public_executor on public.processes
  as restrictive
  for select
  to portal_public_executor, next_public_search_executor
  using (state_code is distinct from 120);

-- 2) SECURITY DEFINER readers owned by postgres still need explicit predicates.
--
-- These bodies execute as postgres, so they bypass row security and layer 1 cannot reach
-- them. Each is reproduced verbatim below with only the 120 exclusion added.
--
--   * private.search_processes_latest_v2_impl - patched below. Its 'my' and 'te' branches
--     read `state_code_filter is null or p.state_code = state_code_filter`, so a null
--     filter returns every state. The exclusion is added to all four process scans: the
--     static exact-id branch (p and its latest-version lateral p2) and the dynamic branch
--     (the text_matches scan p and its latest-version lateral p2). The latest-version
--     anti-join matters because the qualifying row and the newest row are chosen
--     independently. Reached by api.search_processes, api.search_processes_latest and
--     api.search_processes_latest_v2.
--   * private.search_dataset_json_uuid_mentions_impl - ADDED BELOW. Same exclusion in the
--     process block only (`$4 is null or d.state_code = $4`), leaving
--     the flow, lifecyclemodel, source, contact, unitgroup and flowproperty blocks
--     unchanged. Reached by api.search_dataset_json_uuid_mentions (reference lookup).
--   * api.svc_tidas_package_export_enqueue - the selected_roots admission predicate
--     `datasets.state_code between 100 and 199` admits 120 via the caller's owner branch.
--     This path is actually used by Edge at edge-functions/supabase/functions/_shared/
--     tidas_package.ts:345, whose upload happens later in the Worker.
--
-- Layer 1 already covers every RLS-evaluated route: Next direct relation reads, the
-- postgres-owned SECURITY INVOKER readers (get_latest_process_versions,
-- pgroonga_search_processes_v1, semantic_search_processes_v1 - invoker executes as the
-- caller, so RLS applies), and every SECURITY DEFINER body owned by
-- api_internal_executor, which inherits authenticated and is NOBYPASSRLS.

-- 2b) private.search_processes_latest_v2_impl: exclude 120 from the 'my' and 'te'
-- branches of every process scan. Eight clauses are added - 'my' and 'te' for the
-- qualifying scan and for its latest-version lateral, in both the static exact-id branch
-- and the dynamic text branch. Each added clause is literally
-- `and p.state_code is distinct from 120` (or p2), so the null-filter behaviour that
-- previously returned every state can no longer return a Result.
create or replace function private.search_processes_latest_v2_impl(
  query_text text,
  filter_condition jsonb default '{}'::jsonb,
  page_size bigint default 10,
  page_current bigint default 1,
  data_source text default 'tg'::text,
  this_user_id text default ''::text,
  team_id_filter uuid default null::uuid,
  state_code_filter integer default null::integer,
  type_of_data_set_filter text default 'all'::text,
  query_terms text[] default null::text[],
  owner_draft_only boolean default false
) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "model_id" "uuid", "total_count" bigint)
language plpgsql
security definer
set search_path = 'private', 'api', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
set statement_timeout = '60s'
as $_$
declare
  normalized_page_size bigint;
  normalized_page_current bigint;
  normalized_data_source text;
  effective_user_id uuid;
  can_read_team_filter boolean;
  exact_query_id uuid;
  filter_condition_jsonb jsonb;
  json_filter_clause text;
  v_sql text;
  escaped_query_terms text[];
  text_match_clause text;
begin
  normalized_page_size := greatest(coalesce(page_size, 10), 1);
  normalized_page_current := greatest(coalesce(page_current, 1), 1);
  normalized_data_source := coalesce(nullif(lower(btrim(data_source)), ''), 'tg');
  if owner_draft_only and normalized_data_source <> 'my' then
    return;
  end if;
  effective_user_id := private.dataset_search_effective_user_id(this_user_id);
  can_read_team_filter := private.dataset_search_can_read_team_filter(team_id_filter, effective_user_id);
  exact_query_id := case
    when coalesce(btrim(query_text) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
      then btrim(query_text)::uuid
    else null::uuid
  end;
  filter_condition_jsonb := coalesce(filter_condition, '{}'::jsonb);
  escaped_query_terms := private.pgroonga_escape_query_terms(query_terms);
  if cardinality(escaped_query_terms) = 0 then
    escaped_query_terms := private.pgroonga_escape_query_terms(array[query_text]);
  end if;
  text_match_clause := 'where p.search_text &@~| $11';

  if exact_query_id is not null then
    return query
      with matched_ids as (
        select p.id, 1.0::double precision as search_score
        from public.processes p
        where p.id = exact_query_id
          and p.json @> filter_condition_jsonb
          and (
            (((normalized_data_source = 'tg' AND p.state_code = 100) OR (normalized_data_source = 'ex' AND p.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or p.team_id = team_id_filter))
            or (normalized_data_source = 'co' and p.state_code = 200 and (team_id_filter is null or p.team_id = team_id_filter))
            or (normalized_data_source = 'my' and effective_user_id is not null and p.user_id = effective_user_id and (state_code_filter is null or p.state_code = state_code_filter) and (not owner_draft_only or (p.state_code = 0)) and p.state_code is distinct from 120)
            or (normalized_data_source = 'te' and team_id_filter is not null and can_read_team_filter and p.team_id = team_id_filter and (state_code_filter is null or p.state_code = state_code_filter) and p.state_code is distinct from 120)
          )
          and (
            coalesce(type_of_data_set_filter, 'all') = 'all'
            or p.json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}' = type_of_data_set_filter
          )
        group by p.id
      ),
      latest_rows as (
        select matched_ids.id, latest_row.json, latest_row.version, latest_row.modified_at, latest_row.team_id, latest_row.model_id, matched_ids.search_score
        from matched_ids
        join lateral (
          select p2.json, p2.version, p2.modified_at, p2.team_id, p2.model_id
          from public.processes p2
          where p2.id = matched_ids.id
            and (
              (((normalized_data_source = 'tg' AND p2.state_code = 100) OR (normalized_data_source = 'ex' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and (team_id_filter is null or p2.team_id = team_id_filter))
              or (normalized_data_source = 'co' and p2.state_code = 200 and (team_id_filter is null or p2.team_id = team_id_filter))
              or (normalized_data_source = 'my' and effective_user_id is not null and p2.user_id = effective_user_id and (state_code_filter is null or p2.state_code = state_code_filter) and (not owner_draft_only or (p2.state_code = 0)) and p2.state_code is distinct from 120)
              or (normalized_data_source = 'te' and team_id_filter is not null and can_read_team_filter and p2.team_id = team_id_filter and (state_code_filter is null or p2.state_code = state_code_filter) and p2.state_code is distinct from 120)
            )
          order by p2.version desc, p2.modified_at desc
          limit 1
        ) latest_row on true
      ),
      counted_rows as (
        select latest_rows.*, count(*) over()::bigint as total_count
        from latest_rows
      )
      select 1::bigint as rank, counted_rows.id, counted_rows.json, counted_rows.version, counted_rows.modified_at, counted_rows.team_id, counted_rows.model_id, counted_rows.total_count
      from counted_rows
      order by rank, counted_rows.id
      limit normalized_page_size
      offset (normalized_page_current - 1) * normalized_page_size;
    return;
  end if;

  json_filter_clause := case
    when filter_condition_jsonb = '{}'::jsonb then ''
    else 'and p.json @> $2'
  end;

  v_sql := format($sql$
    with text_matches as materialized (
      select p.id,
             p.json,
             p.state_code,
             p.team_id,
             p.user_id,
             p.model_id,
             p.review_id,
             pgroonga_score(p.tableoid, p.ctid) as search_score
      from public.processes p
      %s
    ),
    matched_ids as (
      select p.id, max(p.search_score) as search_score
      from text_matches p
      where (
          ((($5 = 'tg' AND p.state_code = 100) OR ($5 = 'ex' AND p.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or p.team_id = $7))
          or ($5 = 'co' and p.state_code = 200 and ($7 is null or p.team_id = $7))
          or ($5 = 'my' and $6 is not null and p.user_id = $6 and ($8 is null or p.state_code = $8) and (not $12 or (p.state_code = 0)) and p.state_code is distinct from 120)
          or ($5 = 'te' and $7 is not null and $9 and p.team_id = $7 and ($8 is null or p.state_code = $8) and p.state_code is distinct from 120)
        )
        %s
        and (
          coalesce($10, 'all') = 'all'
          or p.json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}' = $10
        )
      group by p.id
    ),
    latest_rows as (
      select matched_ids.id, latest_row.json, latest_row.version, latest_row.modified_at, latest_row.team_id, latest_row.model_id, matched_ids.search_score
      from matched_ids
      join lateral (
        select p2.json, p2.version, p2.modified_at, p2.team_id, p2.model_id
        from public.processes p2
        where p2.id = matched_ids.id
          and (
            ((($5 = 'tg' AND p2.state_code = 100) OR ($5 = 'ex' AND p2.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($7 is null or p2.team_id = $7))
            or ($5 = 'co' and p2.state_code = 200 and ($7 is null or p2.team_id = $7))
            or ($5 = 'my' and $6 is not null and p2.user_id = $6 and ($8 is null or p2.state_code = $8) and (not $12 or (p2.state_code = 0)) and p2.state_code is distinct from 120)
            or ($5 = 'te' and $7 is not null and $9 and p2.team_id = $7 and ($8 is null or p2.state_code = $8) and p2.state_code is distinct from 120)
          )
        order by p2.version desc, p2.modified_at desc
        limit 1
      ) latest_row on true
    ),
    counted_rows as (
      select latest_rows.*, count(*) over()::bigint as total_count
      from latest_rows
    ),
    ranked_rows as (
      select rank() over (order by counted_rows.search_score desc, counted_rows.modified_at desc, counted_rows.id)::bigint as rank,
             counted_rows.*
      from counted_rows
    )
    select ranked_rows.rank, ranked_rows.id, ranked_rows.json, ranked_rows.version, ranked_rows.modified_at, ranked_rows.team_id, ranked_rows.model_id, ranked_rows.total_count
    from ranked_rows
    order by ranked_rows.rank, ranked_rows.id
    limit $3
    offset ($4 - 1) * $3
  $sql$, text_match_clause, json_filter_clause);

  return query execute v_sql
    using query_text, filter_condition_jsonb, normalized_page_size, normalized_page_current,
          normalized_data_source, effective_user_id, team_id_filter, state_code_filter,
          can_read_team_filter, type_of_data_set_filter, escaped_query_terms,
          owner_draft_only;
end;
$_$;

alter function private.search_processes_latest_v2_impl(
  text, jsonb, bigint, bigint, text, text, uuid, integer, text, text[], boolean
) owner to postgres;
revoke all on function private.search_processes_latest_v2_impl(
  text, jsonb, bigint, bigint, text, text, uuid, integer, text, text[], boolean
) from public;
grant all on function private.search_processes_latest_v2_impl(
  text, jsonb, bigint, bigint, text, text, uuid, integer, text, text[], boolean
) to service_role;
grant all on function private.search_processes_latest_v2_impl(
  text, jsonb, bigint, bigint, text, text, uuid, integer, text, text[], boolean
) to api_internal_executor;

-- 2c) private.search_dataset_json_uuid_mentions_impl: exclude 120 from the process
-- block only. This is the reference-lookup path (api.search_dataset_json_uuid_mentions).
-- Every other entity block - flow, lifecyclemodel, source, contact, unitgroup,
-- flowproperty - is byte-identical to its previous definition, so support lookup
-- behaviour is unchanged. One clause is added, to the 'my' and 'te' branches of the
-- process block, which otherwise admit every state when the filter is null.
create or replace function private.search_dataset_json_uuid_mentions_impl(
  p_uuid uuid,
  p_source_entity_kinds text[] default null::text[],
  p_data_source text default 'tg'::text,
  p_this_user_id text default ''::text,
  p_team_id_filter uuid default null::uuid,
  p_state_code_filter integer default null::integer,
  p_limit integer default 20
) RETURNS TABLE("rank" bigint, "source_entity_kind" "text", "source_id" "uuid", "source_version" character, "source_name" "text", "source_modified_at" timestamp with time zone, "source_team_id" "uuid", "source_json" "jsonb", "matched_by" "text", "matched_entity_table" "text")
language plpgsql
security definer
set search_path = 'private', 'api', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
set statement_timeout = '20s'
as $_$
declare
  normalized_data_source text;
  effective_user_id uuid;
  can_read_team_filter boolean;
  normalized_limit integer;
  per_entity_limit integer;
  uuid_pattern text;
  normalized_source_entity_kinds text[];
  branches text[] := array[]::text[];
  v_sql text;
begin
  normalized_data_source := coalesce(nullif(lower(btrim(p_data_source)), ''), 'tg');
  effective_user_id := private.dataset_search_effective_user_id(p_this_user_id);
  can_read_team_filter := private.dataset_search_can_read_team_filter(p_team_id_filter, effective_user_id);
  normalized_limit := least(greatest(coalesce(p_limit, 20), 1), 50);
  per_entity_limit := normalized_limit;
  uuid_pattern := '%' || p_uuid::text || '%';

  if p_source_entity_kinds is not null then
    select array_agg(distinct normalized_kind order by normalized_kind)
    into normalized_source_entity_kinds
    from (
      select case lower(btrim(kind))
        when 'flow' then 'flow'
        when 'flows' then 'flow'
        when 'process' then 'process'
        when 'processes' then 'process'
        when 'lifecyclemodel' then 'lifecyclemodel'
        when 'lifecyclemodels' then 'lifecyclemodel'
        when 'model' then 'lifecyclemodel'
        when 'models' then 'lifecyclemodel'
        when 'source' then 'source'
        when 'sources' then 'source'
        when 'contact' then 'contact'
        when 'contacts' then 'contact'
        when 'unitgroup' then 'unitgroup'
        when 'unitgroups' then 'unitgroup'
        when 'flowproperty' then 'flowproperty'
        when 'flowproperties' then 'flowproperty'
        else null
      end as normalized_kind
      from unnest(p_source_entity_kinds) as requested(kind)
    ) normalized
    where normalized_kind is not null;

    if coalesce(array_length(normalized_source_entity_kinds, 1), 0) = 0 then
      return;
    end if;
  end if;

  if normalized_source_entity_kinds is null or 'process' = any(normalized_source_entity_kinds) then
    branches := branches || array[$branch$
      (select *
      from (
        select distinct on (d.id)
          10::integer as entity_rank,
          'process'::text as source_entity_kind,
          d.id as source_id,
          d.version as source_version,
          private.dataset_json_display_name('process', d.json) as source_name,
          d.modified_at as source_modified_at,
          d.team_id as source_team_id,
          d.json as source_json,
          'json_uuid_scan'::text as matched_by,
          'public.processes'::text as matched_entity_table
        from public.processes d
        where (
            ((($1 = 'tg' AND d.state_code = 100) OR ($1 = 'ex' AND d.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($3 is null or d.team_id = $3))
            or ($1 = 'co' and d.state_code = 200 and ($3 is null or d.team_id = $3))
            or ($1 = 'my' and $2 is not null and d.user_id = $2 and ($4 is null or d.state_code = $4) and d.state_code is distinct from 120)
            or ($1 = 'te' and $3 is not null and $5 and d.team_id = $3 and ($4 is null or d.state_code = $4) and d.state_code is distinct from 120)
          )
        order by d.id, d.version desc, d.modified_at desc
      ) latest
      where latest.source_json::text like $6
      order by latest.source_modified_at desc nulls last, latest.source_id
      limit $8
      )
    $branch$];
  end if;

  if normalized_source_entity_kinds is null or 'flow' = any(normalized_source_entity_kinds) then
    branches := branches || array[$branch$
      (select *
      from (
        select distinct on (d.id)
          20::integer as entity_rank,
          'flow'::text as source_entity_kind,
          d.id as source_id,
          d.version as source_version,
          private.dataset_json_display_name('flow', d.json) as source_name,
          d.modified_at as source_modified_at,
          d.team_id as source_team_id,
          d.json as source_json,
          'json_uuid_scan'::text as matched_by,
          'public.flows'::text as matched_entity_table
        from public.flows d
        where (
            ((($1 = 'tg' AND d.state_code = 100) OR ($1 = 'ex' AND d.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($3 is null or d.team_id = $3))
            or ($1 = 'co' and d.state_code = 200 and ($3 is null or d.team_id = $3))
            or ($1 = 'my' and $2 is not null and d.user_id = $2 and ($4 is null or d.state_code = $4))
            or ($1 = 'te' and $3 is not null and $5 and d.team_id = $3 and ($4 is null or d.state_code = $4))
          )
        order by d.id, d.version desc, d.modified_at desc
      ) latest
      where latest.source_json::text like $6
      order by latest.source_modified_at desc nulls last, latest.source_id
      limit $8
      )
    $branch$];
  end if;

  if normalized_source_entity_kinds is null or 'lifecyclemodel' = any(normalized_source_entity_kinds) then
    branches := branches || array[$branch$
      (select *
      from (
        select distinct on (d.id)
          30::integer as entity_rank,
          'lifecyclemodel'::text as source_entity_kind,
          d.id as source_id,
          d.version as source_version,
          private.dataset_json_display_name('lifecyclemodel', d.json) as source_name,
          d.modified_at as source_modified_at,
          d.team_id as source_team_id,
          d.json as source_json,
          'json_uuid_scan'::text as matched_by,
          'public.lifecyclemodels'::text as matched_entity_table
        from public.lifecyclemodels d
        where (
            ((($1 = 'tg' AND d.state_code = 100) OR ($1 = 'ex' AND d.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($3 is null or d.team_id = $3))
            or ($1 = 'co' and d.state_code = 200 and ($3 is null or d.team_id = $3))
            or ($1 = 'my' and $2 is not null and d.user_id = $2 and ($4 is null or d.state_code = $4))
            or ($1 = 'te' and $3 is not null and $5 and d.team_id = $3 and ($4 is null or d.state_code = $4))
          )
        order by d.id, d.version desc, d.modified_at desc
      ) latest
      where latest.source_json::text like $6
      order by latest.source_modified_at desc nulls last, latest.source_id
      limit $8
      )
    $branch$];
  end if;

  if normalized_source_entity_kinds is null or 'source' = any(normalized_source_entity_kinds) then
    branches := branches || array[$branch$
      (select *
      from (
        select distinct on (d.id)
          40::integer as entity_rank,
          'source'::text as source_entity_kind,
          d.id as source_id,
          d.version as source_version,
          private.dataset_json_display_name('source', d.json) as source_name,
          d.modified_at as source_modified_at,
          d.team_id as source_team_id,
          d.json as source_json,
          'json_uuid_scan'::text as matched_by,
          'public.sources'::text as matched_entity_table
        from public.sources d
        where (
            ((($1 = 'tg' AND d.state_code = 100) OR ($1 = 'ex' AND d.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($3 is null or d.team_id = $3))
            or ($1 = 'co' and d.state_code = 200 and ($3 is null or d.team_id = $3))
            or ($1 = 'my' and $2 is not null and d.user_id = $2 and ($4 is null or d.state_code = $4))
            or ($1 = 'te' and $3 is not null and $5 and d.team_id = $3 and ($4 is null or d.state_code = $4))
          )
        order by d.id, d.version desc, d.modified_at desc
      ) latest
      where latest.source_json::text like $6
      order by latest.source_modified_at desc nulls last, latest.source_id
      limit $8
      )
    $branch$];
  end if;

  if normalized_source_entity_kinds is null or 'contact' = any(normalized_source_entity_kinds) then
    branches := branches || array[$branch$
      (select *
      from (
        select distinct on (d.id)
          50::integer as entity_rank,
          'contact'::text as source_entity_kind,
          d.id as source_id,
          d.version as source_version,
          private.dataset_json_display_name('contact', d.json) as source_name,
          d.modified_at as source_modified_at,
          d.team_id as source_team_id,
          d.json as source_json,
          'json_uuid_scan'::text as matched_by,
          'public.contacts'::text as matched_entity_table
        from public.contacts d
        where (
            ((($1 = 'tg' AND d.state_code = 100) OR ($1 = 'ex' AND d.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($3 is null or d.team_id = $3))
            or ($1 = 'co' and d.state_code = 200 and ($3 is null or d.team_id = $3))
            or ($1 = 'my' and $2 is not null and d.user_id = $2 and ($4 is null or d.state_code = $4))
            or ($1 = 'te' and $3 is not null and $5 and d.team_id = $3 and ($4 is null or d.state_code = $4))
          )
        order by d.id, d.version desc, d.modified_at desc
      ) latest
      where latest.source_json::text like $6
      order by latest.source_modified_at desc nulls last, latest.source_id
      limit $8
      )
    $branch$];
  end if;

  if normalized_source_entity_kinds is null or 'unitgroup' = any(normalized_source_entity_kinds) then
    branches := branches || array[$branch$
      (select *
      from (
        select distinct on (d.id)
          60::integer as entity_rank,
          'unitgroup'::text as source_entity_kind,
          d.id as source_id,
          d.version as source_version,
          private.dataset_json_display_name('unitgroup', d.json) as source_name,
          d.modified_at as source_modified_at,
          d.team_id as source_team_id,
          d.json as source_json,
          'json_uuid_scan'::text as matched_by,
          'public.unitgroups'::text as matched_entity_table
        from public.unitgroups d
        where (
            ((($1 = 'tg' AND d.state_code = 100) OR ($1 = 'ex' AND d.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($3 is null or d.team_id = $3))
            or ($1 = 'co' and d.state_code = 200 and ($3 is null or d.team_id = $3))
            or ($1 = 'my' and $2 is not null and d.user_id = $2 and ($4 is null or d.state_code = $4))
            or ($1 = 'te' and $3 is not null and $5 and d.team_id = $3 and ($4 is null or d.state_code = $4))
          )
        order by d.id, d.version desc, d.modified_at desc
      ) latest
      where latest.source_json::text like $6
      order by latest.source_modified_at desc nulls last, latest.source_id
      limit $8
      )
    $branch$];
  end if;

  if normalized_source_entity_kinds is null or 'flowproperty' = any(normalized_source_entity_kinds) then
    branches := branches || array[$branch$
      (select *
      from (
        select distinct on (d.id)
          70::integer as entity_rank,
          'flowproperty'::text as source_entity_kind,
          d.id as source_id,
          d.version as source_version,
          private.dataset_json_display_name('flowproperty', d.json) as source_name,
          d.modified_at as source_modified_at,
          d.team_id as source_team_id,
          d.json as source_json,
          'json_uuid_scan'::text as matched_by,
          'public.flowproperties'::text as matched_entity_table
        from public.flowproperties d
        where (
            ((($1 = 'tg' AND d.state_code = 100) OR ($1 = 'ex' AND d.state_code = -1 AND (SELECT auth.uid()) IS NOT NULL)) and ($3 is null or d.team_id = $3))
            or ($1 = 'co' and d.state_code = 200 and ($3 is null or d.team_id = $3))
            or ($1 = 'my' and $2 is not null and d.user_id = $2 and ($4 is null or d.state_code = $4))
            or ($1 = 'te' and $3 is not null and $5 and d.team_id = $3 and ($4 is null or d.state_code = $4))
          )
        order by d.id, d.version desc, d.modified_at desc
      ) latest
      where latest.source_json::text like $6
      order by latest.source_modified_at desc nulls last, latest.source_id
      limit $8
      )
    $branch$];
  end if;

  if coalesce(array_length(branches, 1), 0) = 0 then
    return;
  end if;

  v_sql := format($sql$
    with matched_rows as (
      %s
    )
    select
      row_number() over (
        order by entity_rank, source_modified_at desc nulls last, source_entity_kind, source_id
      )::bigint as rank,
      source_entity_kind,
      source_id,
      source_version,
      source_name,
      source_modified_at,
      source_team_id,
      source_json,
      matched_by,
      matched_entity_table
    from matched_rows
    order by entity_rank, source_modified_at desc nulls last, source_entity_kind, source_id
    limit $7
  $sql$, array_to_string(branches, E'\nunion all\n'));

  return query execute v_sql
    using normalized_data_source, effective_user_id, p_team_id_filter, p_state_code_filter,
          can_read_team_filter, uuid_pattern, normalized_limit, per_entity_limit;
end;
$_$;

alter function private.search_dataset_json_uuid_mentions_impl(
  uuid, text[], text, text, uuid, integer, integer
) owner to postgres;
revoke all on function private.search_dataset_json_uuid_mentions_impl(
  uuid, text[], text, text, uuid, integer, integer
) from public;
grant all on function private.search_dataset_json_uuid_mentions_impl(
  uuid, text[], text, text, uuid, integer, integer
) to service_role;
grant all on function private.search_dataset_json_uuid_mentions_impl(
  uuid, text[], text, text, uuid, integer, integer
) to api_internal_executor;

-- 2d) api.svc_tidas_package_export_enqueue: the selected_roots admission admitted any
-- process with state between 100 and 199 through the requester's owner branch, so a
-- Result could be exported. Edge really uses this path
-- (edge-functions/supabase/functions/_shared/tidas_package.ts:345), and the package bytes
-- are produced later by the Worker, so the Database admission is what must refuse it.
--
-- Exactly one predicate is added: a processes root is refused when its state is 120,
-- regardless of ownership or scope. Support tables keep their existing admission
-- untouched, and current_user / open_data / current_user_and_open_data scopes are
-- unchanged because they do not reach this block.
create or replace function api.svc_tidas_package_export_enqueue(
  p_requested_by uuid,
  p_scope text,
  p_roots jsonb,
  p_request_key text,
  p_request_payload jsonb,
  p_job_id uuid,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $_$
declare
  v_scope text := lower(btrim(coalesce(p_scope, '')));
  v_request_key text := nullif(btrim(p_request_key), '');
  v_roots jsonb := '[]'::jsonb;
  v_root_count integer := 0;
  v_exportable_count integer := 0;
  v_request_payload jsonb;
  v_cache private.lca_package_request_cache%rowtype;
  v_worker private.worker_jobs%rowtype;
  v_enqueue jsonb;
  v_worker_id uuid;
  v_resolved_job_id uuid;
  v_worker_status text;
begin
  if p_requested_by is null or p_job_id is null or v_request_key is null
     or v_scope not in ('current_user', 'open_data', 'current_user_and_open_data', 'selected_roots')
     or jsonb_typeof(coalesce(p_roots, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'INVALID_PACKAGE_EXPORT_REQUEST', 'status', 400);
  end if;
  if jsonb_array_length(coalesce(p_roots, '[]'::jsonb)) > 500 then
    return jsonb_build_object('ok', false, 'code', 'PACKAGE_ROOT_LIMIT_EXCEEDED', 'status', 400);
  end if;
  if v_scope not in ('current_user', 'selected_roots') and not exists (
    select 1 from private.roles
    where user_id = p_requested_by
      and team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and role in ('owner', 'admin')
  ) then
    return jsonb_build_object('ok', false, 'code', 'EXPORT_SCOPE_FORBIDDEN', 'status', 403);
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_roots, '[]'::jsonb)) as root(value)
    where jsonb_typeof(root.value) <> 'object'
      or root.value ->> 'table' not in (
        'contacts', 'sources', 'unitgroups', 'flowproperties',
        'flows', 'processes', 'lifecyclemodels'
      )
      or coalesce(root.value ->> 'id', '') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      or nullif(btrim(root.value ->> 'version'), '') is null
  ) then
    return jsonb_build_object('ok', false, 'code', 'INVALID_PACKAGE_ROOT', 'status', 400);
  end if;

  with normalized as (
    select distinct
      root.value ->> 'table' as table_name,
      lower(root.value ->> 'id')::uuid as id,
      btrim(root.value ->> 'version') as version
    from jsonb_array_elements(coalesce(p_roots, '[]'::jsonb)) as root(value)
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'table', normalized.table_name,
      'id', normalized.id,
      'version', normalized.version
    ) order by normalized.table_name, normalized.id, normalized.version), '[]'::jsonb),
    count(*)
  into v_roots, v_root_count
  from normalized;

  if (v_scope = 'selected_roots') <> (v_root_count > 0) then
    return jsonb_build_object('ok', false, 'code', 'PACKAGE_SCOPE_ROOTS_MISMATCH', 'status', 400);
  end if;

  if v_scope = 'selected_roots' then
    with requested as (
      select
        root.value ->> 'table' as table_name,
        (root.value ->> 'id')::uuid as id,
        root.value ->> 'version' as version
      from jsonb_array_elements(v_roots) as root(value)
    ), datasets as (
      select 'contacts'::text as table_name, id, version, user_id, state_code from public.contacts
      union all select 'sources', id, version, user_id, state_code from public.sources
      union all select 'unitgroups', id, version, user_id, state_code from public.unitgroups
      union all select 'flowproperties', id, version, user_id, state_code from public.flowproperties
      union all select 'flows', id, version, user_id, state_code from public.flows
      union all select 'processes', id, version, user_id, state_code from public.processes
      union all select 'lifecyclemodels', id, version, user_id, state_code from public.lifecyclemodels
    )
    select count(*)
    into v_exportable_count
    from requested
    join datasets using (table_name, id, version)
    where (
        datasets.user_id = p_requested_by
        or datasets.state_code = -1
        or datasets.state_code between 100 and 199
      )
      -- A published Result Process is never an exportable root, for any requester.
      and not (datasets.table_name = 'processes' and datasets.state_code = 120);

    if v_exportable_count <> v_root_count then
      return jsonb_build_object('ok', false, 'code', 'ROOT_EXPORT_FORBIDDEN', 'status', 403);
    end if;
  end if;

  v_request_payload := coalesce(p_request_payload, '{}'::jsonb) || jsonb_build_object(
    'scope', v_scope,
    'roots', v_roots
  );

  perform pg_advisory_xact_lock(hashtextextended(
    p_requested_by::text || ':export_package:' || v_request_key, 0
  ));
  select * into v_cache from private.lca_package_request_cache
  where requested_by = p_requested_by and operation = 'export_package' and request_key = v_request_key
  for update;
  if v_cache.id is not null then
    update private.lca_package_request_cache set
      hit_count = hit_count + 1, last_accessed_at = now(), updated_at = now()
    where id = v_cache.id returning * into v_cache;

    -- All scopes may change without changing the request identities. Reuse
    -- active work, but let completed exports reach worker_enqueue_job so a new
    -- intent reads current root/dependency data and keeps its own artifacts.
    if v_cache.worker_job_id is not null then
      select * into v_worker from private.worker_jobs where id = v_cache.worker_job_id;
      if v_worker.status in ('queued', 'running', 'waiting', 'stale', 'completed', 'blocked') then
        if v_worker.status = 'blocked' then
          update private.lca_package_request_cache
          set status = 'failed', updated_at = now()
          where id = v_cache.id
          returning * into v_cache;
        end if;

        if v_worker.status <> 'completed' then
          return jsonb_build_object(
            'ok', true,
            'mode', case
              when v_worker.status = 'blocked' then 'blocked'
              else 'in_progress'
            end,
            'job_id', v_cache.job_id,
            'worker_job_id', v_cache.worker_job_id
          );
        end if;
      end if;
    end if;
  end if;

  v_enqueue := private.worker_enqueue_job(
    p_job_kind => 'tidas.export_package',
    p_payload_json => jsonb_build_object(
      'type', 'export_package', 'job_id', p_job_id, 'requested_by', p_requested_by,
      'scope', v_scope, 'roots', v_roots
    ),
    p_payload_schema_version => 'tidas.export_package.request.v1',
    p_subject_type => 'lca_package_job',
    p_subject_id => p_job_id,
    p_subject_version => v_scope,
    p_requested_by => p_requested_by,
    p_requester_type => 'user',
    p_idempotency_key => p_idempotency_key,
    p_request_hash => v_request_key,
    p_queue_key => v_scope,
    p_visibility => 'user'
  );
  if coalesce((v_enqueue ->> 'ok')::boolean, false) is false then return v_enqueue; end if;
  v_worker_id := (v_enqueue #>> '{data,id}')::uuid;
  v_resolved_job_id := coalesce(
    nullif(v_enqueue #>> '{data,payload,job_id}', '')::uuid,
    nullif(v_enqueue #>> '{data,subjectId}', '')::uuid,
    p_job_id
  );
  v_worker_status := v_enqueue #>> '{data,status}';

  insert into private.lca_package_request_cache as cache (
    requested_by, operation, request_key, request_payload, status,
    job_id, worker_job_id, hit_count, last_accessed_at, created_at, updated_at
  ) values (
    p_requested_by, 'export_package', v_request_key, v_request_payload,
    case when v_worker_status = 'blocked' then 'failed' else 'pending' end,
    v_resolved_job_id, v_worker_id, 1, now(), now(), now()
  ) on conflict (requested_by, operation, request_key) do update set
    request_payload = excluded.request_payload,
    status = excluded.status, job_id = excluded.job_id, worker_job_id = excluded.worker_job_id,
    error_code = null, error_message = null,
    hit_count = cache.hit_count + 1, last_accessed_at = now(), updated_at = now()
  returning * into v_cache;

  return jsonb_build_object(
    'ok', true,
    'mode', case
      when v_worker_status = 'blocked' then 'blocked'
      when coalesce((v_enqueue ->> 'reused')::boolean, false) then 'in_progress'
      else 'queued'
    end,
    'job_id', v_cache.job_id,
    'worker_job_id', v_cache.worker_job_id,
    'scope', v_scope,
    'root_count', v_root_count
  );
end
$_$;

alter function api.svc_tidas_package_export_enqueue(
  uuid, text, jsonb, text, jsonb, uuid, text
) owner to postgres;
revoke all on function api.svc_tidas_package_export_enqueue(
  uuid, text, jsonb, text, jsonb, uuid, text
) from public;
grant all on function api.svc_tidas_package_export_enqueue(
  uuid, text, jsonb, text, jsonb, uuid, text
) to service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
