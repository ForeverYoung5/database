-- Open Data catalog filters and exact-version Process publication markers.

create table private.open_data_process_publications (
  process_id uuid not null,
  process_version character(9) not null,
  published_at timestamptz not null default now(),
  published_by uuid not null,
  constraint open_data_process_publications_pkey
    primary key (process_id, process_version),
  constraint open_data_process_publications_process_fkey
    foreign key (process_id, process_version)
    references public.processes (id, version)
    on update restrict
    on delete restrict
);

alter table private.open_data_process_publications owner to postgres;
alter table private.open_data_process_publications enable row level security;
revoke all on table private.open_data_process_publications
  from public, anon, authenticated, service_role;
grant select on table private.open_data_process_publications to api_internal_executor;

comment on table private.open_data_process_publications is
  'Exact Process versions explicitly published in the Open Data catalog. Row existence is the publication state.';
comment on column private.open_data_process_publications.published_by is
  'Authenticated actor that first published the exact Process version.';

create or replace function private.reject_open_data_process_publication_mutation()
returns trigger
language plpgsql
set search_path to pg_catalog, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'Open Data Process publications are append-only';
end;
$$;

alter function private.reject_open_data_process_publication_mutation() owner to postgres;
revoke all on function private.reject_open_data_process_publication_mutation() from public;

create trigger reject_open_data_process_publication_mutation
before update or delete on private.open_data_process_publications
for each row execute function private.reject_open_data_process_publication_mutation();

create or replace function private.open_data_catalog_filter_matches(
  p_dataset_kind text,
  p_json jsonb,
  p_filter_condition jsonb
)
returns boolean
language plpgsql
immutable
parallel safe
set search_path to pg_catalog, pg_temp
as $$
declare
  v_filter jsonb := coalesce(p_filter_condition, '{}'::jsonb);
  v_type_filter text;
  v_type_filters text[];
  v_as_input boolean;
  v_classification_filter jsonb := '[]'::jsonb;
begin
  if p_dataset_kind = 'process' then
    v_type_filter := nullif(btrim(v_filter ->> 'typeOfDataSet'), '');
    v_filter := v_filter - 'typeOfDataSet';
    return p_json @> v_filter
      and (
        v_type_filter is null
        or v_type_filter = 'all'
        or p_json #>> '{processDataSet,modellingAndValidation,LCIMethodAndAllocation,typeOfDataSet}' = v_type_filter
      );
  end if;

  if p_dataset_kind <> 'flow' then
    return p_json @> v_filter;
  end if;

  v_type_filter := nullif(btrim(v_filter ->> 'flowType'), '');
  v_type_filters := case when v_type_filter is null then null else string_to_array(v_type_filter, ',') end;
  v_filter := v_filter - 'flowType';

  if v_filter ? 'asInput' then
    v_as_input := nullif(btrim(v_filter ->> 'asInput'), '')::boolean;
  end if;
  v_filter := v_filter - 'asInput';

  if jsonb_typeof(v_filter -> 'classification') = 'array' then
    v_classification_filter := v_filter -> 'classification';
  end if;
  v_filter := v_filter - 'classification';

  return p_json @> v_filter
    and (
      v_type_filters is null
      or p_json #>> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}' = any(v_type_filters)
    )
    and (
      v_as_input is null
      or not v_as_input
      or not p_json @> '{"flowDataSet":{"flowInformation":{"dataSetInformation":{"classificationInformation":{"common:elementaryFlowCategorization":{"common:category":[{"#text":"Emissions","@level":"0"}]}}}}}}'::jsonb
    )
    and (
      jsonb_array_length(v_classification_filter) = 0
      or exists (
        select 1
        from jsonb_array_elements(v_classification_filter) selected(item)
        where (
          selected.item ->> 'scope' = 'elementary'
          and exists (
            select 1
            from jsonb_array_elements(
              case jsonb_typeof(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:elementaryFlowCategorization,common:category}')
                when 'array' then p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:elementaryFlowCategorization,common:category}'
                when 'object' then jsonb_build_array(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:elementaryFlowCategorization,common:category}')
                else '[]'::jsonb
              end
            ) category(item)
            where category.item ->> '@catId' = selected.item ->> 'code'
          )
        ) or (
          selected.item ->> 'scope' = 'classification'
          and exists (
            select 1
            from jsonb_array_elements(
              case jsonb_typeof(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:classification,common:class}')
                when 'array' then p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:classification,common:class}'
                when 'object' then jsonb_build_array(p_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation,common:classification,common:class}')
                else '[]'::jsonb
              end
            ) classification(item)
            where classification.item ->> '@classId' = selected.item ->> 'code'
          )
        )
      )
    );
end;
$$;

alter function private.open_data_catalog_filter_matches(text, jsonb, jsonb) owner to postgres;
revoke all on function private.open_data_catalog_filter_matches(text, jsonb, jsonb) from public;

create or replace function api.cmd_open_data_process_publish_batch(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to api, private, public, util, extensions, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_input_count integer;
  v_requested_count integer;
  v_existing_count integer;
  v_inserted_count integer;
  v_valid_count integer;
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  if not exists (
    select 1
    from private.roles r
    where r.user_id = v_actor
      and r.team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and r.role::text = 'data_product_manager'
  ) then
    raise exception using errcode = '42501', message = 'data_product_manager role required';
  end if;

  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'p_items must be a JSON array';
  end if;

  v_input_count := jsonb_array_length(p_items);
  if v_input_count < 1 or v_input_count > 100 then
    raise exception using errcode = '22023', message = 'p_items must contain between 1 and 100 items';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) item(value)
    where jsonb_typeof(item.value) is distinct from 'object'
      or jsonb_typeof(item.value -> 'id') is distinct from 'string'
      or jsonb_typeof(item.value -> 'version') is distinct from 'string'
      or not ((item.value ->> 'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      or not ((item.value ->> 'version') ~ '^\d{2}\.\d{2}\.\d{3}$')
  ) then
    raise exception using errcode = '22023', message = 'each item must contain a valid id and version';
  end if;

  select count(*)
  into v_requested_count
  from (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested;

  -- Lock in a stable order so concurrent overlapping batches cannot invert locks.
  perform p.id
  from public.processes p
  join (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested
    on requested.process_id = p.id
   and requested.process_version = p.version
  order by p.id, p.version
  for update of p;

  select count(*)
  into v_valid_count
  from public.processes p
  join (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested
    on requested.process_id = p.id
   and requested.process_version = p.version
  where p.state_code = 100;

  if v_valid_count <> v_requested_count then
    raise exception using
      errcode = '22023',
      message = 'all requested Process versions must exist with state_code 100';
  end if;

  select count(*)
  into v_existing_count
  from private.open_data_process_publications publication
  join (
    select distinct
      (item.value ->> 'id')::uuid as process_id,
      (item.value ->> 'version')::character(9) as process_version
    from jsonb_array_elements(p_items) item(value)
  ) requested
    using (process_id, process_version);

  insert into private.open_data_process_publications (
    process_id,
    process_version,
    published_by
  )
  select distinct
    (item.value ->> 'id')::uuid,
    (item.value ->> 'version')::character(9),
    v_actor
  from jsonb_array_elements(p_items) item(value)
  order by 1, 2
  on conflict (process_id, process_version) do nothing;

  get diagnostics v_inserted_count = row_count;

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'inputCount', v_input_count,
      'requestedCount', v_requested_count,
      'publishedCount', v_inserted_count,
      'alreadyPublishedCount', v_existing_count
    )
  );
end;
$$;

alter function api.cmd_open_data_process_publish_batch(jsonb) owner to postgres;
revoke all on function api.cmd_open_data_process_publish_batch(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function api.cmd_open_data_process_publish_batch(jsonb)
  to api_internal_executor, authenticated;

comment on function api.cmd_open_data_process_publish_batch(jsonb) is
  'Idempotently publishes 1-100 exact state-100 Process versions for Open Data. Does not change Process lifecycle state.';

create or replace function api.search_open_data_catalog(
  p_dataset_kind text,
  p_search_mode text default 'list',
  p_query_text text default '',
  p_query_terms text[] default null,
  p_filter_condition jsonb default '{}'::jsonb,
  p_source_filter text default 'all',
  p_publication_filter text default 'all',
  p_page_size integer default 10,
  p_page_current integer default 1,
  p_sort_by text default 'modified_at',
  p_sort_direction text default 'desc'
)
returns table (
  id uuid,
  "json" jsonb,
  version character(9),
  modified_at timestamptz,
  team_id uuid,
  model_id uuid,
  model_version character(9),
  is_published boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path to api, private, public, util, extensions, pg_temp
set statement_timeout to '60s'
as $_$
declare
  v_kind text := lower(btrim(coalesce(p_dataset_kind, '')));
  v_mode text := lower(btrim(coalesce(p_search_mode, 'list')));
  v_source_filter text := lower(btrim(coalesce(p_source_filter, 'all')));
  v_publication_filter text := lower(btrim(coalesce(p_publication_filter, 'all')));
  v_table regclass;
  v_model_id_expression text := 'null::uuid';
  v_model_version_expression text := 'null::character(9)';
  v_match_clause text;
  v_score_expression text := '0::double precision';
  v_order_clause text;
  v_sort_by text := lower(btrim(coalesce(p_sort_by, 'modified_at')));
  v_sort_direction text := lower(btrim(coalesce(p_sort_direction, 'desc')));
  v_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 100);
  v_page_current integer := greatest(coalesce(p_page_current, 1), 1);
  v_filter jsonb := coalesce(p_filter_condition, '{}'::jsonb);
  v_terms text[];
  v_uuid_pattern text;
  v_sql text;
begin
  v_table := case v_kind
    when 'process' then 'public.processes'::regclass
    when 'flow' then 'public.flows'::regclass
    when 'lifecyclemodel' then 'public.lifecyclemodels'::regclass
    when 'contact' then 'public.contacts'::regclass
    when 'source' then 'public.sources'::regclass
    when 'unitgroup' then 'public.unitgroups'::regclass
    when 'flowproperty' then 'public.flowproperties'::regclass
    else null
  end;
  if v_table is null then
    raise exception using errcode = '22023', message = 'unsupported p_dataset_kind';
  end if;
  if v_mode not in ('list', 'lexical', 'uuid') then
    raise exception using errcode = '22023', message = 'p_search_mode must be list, lexical, or uuid';
  end if;
  if v_source_filter not in ('all', 'literature', 'enterprise') then
    raise exception using errcode = '22023', message = 'p_source_filter must be all, literature, or enterprise';
  end if;
  if v_publication_filter not in ('all', 'published', 'unpublished') then
    raise exception using errcode = '22023', message = 'p_publication_filter must be all, published, or unpublished';
  end if;
  if v_kind <> 'process' and v_publication_filter <> 'all' then
    raise exception using errcode = '22023', message = 'publication filter is supported only for Process data';
  end if;
  if v_sort_by not in ('version', 'created_at', 'modified_at') then
    v_sort_by := 'modified_at';
  end if;
  if v_sort_direction not in ('asc', 'desc') then
    v_sort_direction := 'desc';
  end if;

  if v_kind = 'process' then
    v_model_id_expression := 'd.model_id';
    v_model_version_expression := 'd.model_version';
  end if;

  if v_mode = 'lexical' then
    v_terms := private.pgroonga_escape_query_terms(p_query_terms);
    if cardinality(v_terms) = 0 then
      v_terms := private.pgroonga_escape_query_terms(array[p_query_text]);
    end if;
    if cardinality(v_terms) = 0 then
      raise exception using errcode = '22023', message = 'lexical search requires query text';
    end if;
    v_match_clause := 'and d.search_text &@~| $4';
    v_score_expression := 'pgroonga_score(d.tableoid, d.ctid)';
    v_order_clause := 'candidate_score desc, modified_at desc, id';
  elsif v_mode = 'uuid' then
    if not (coalesce(btrim(p_query_text), '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
      raise exception using errcode = '22023', message = 'uuid search requires a UUID query';
    end if;
    v_uuid_pattern := '%' || lower(btrim(p_query_text)) || '%';
    v_match_clause := 'and d.json::text like $5';
    v_order_clause := 'modified_at desc, id';
  else
    v_match_clause := '';
    v_order_clause := format('%I %s nulls last, id', v_sort_by, v_sort_direction);
  end if;

  v_sql := format($sql$
    with candidate_rows as (
      select
        d.id,
        d.json,
        d.version,
        d.created_at,
        d.modified_at,
        d.team_id,
        %2$s as model_id,
        %3$s as model_version,
        case when $6 = 'process' then exists (
          select 1
          from private.open_data_process_publications publication
          where publication.process_id = d.id
            and publication.process_version = d.version
        ) else false end as is_published,
        %4$s as candidate_score
      from %1$s d
      where d.state_code = 100
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($6, d.json, $3)
        %5$s
    ),
    latest_rows as (
      select distinct on (candidate_rows.id) candidate_rows.*
      from candidate_rows
      order by candidate_rows.id, candidate_rows.version desc, candidate_rows.modified_at desc
    ),
    filtered_rows as (
      select latest_rows.*
      from latest_rows
      where $6 <> 'process'
        or $2 = 'all'
        or ($2 = 'published' and latest_rows.is_published)
        or ($2 = 'unpublished' and not latest_rows.is_published)
    ),
    counted_rows as (
      select filtered_rows.*, count(*) over()::bigint as total_count
      from filtered_rows
    )
    select
      counted_rows.id,
      counted_rows.json,
      counted_rows.version,
      counted_rows.modified_at,
      counted_rows.team_id,
      counted_rows.model_id,
      counted_rows.model_version,
      counted_rows.is_published,
      counted_rows.total_count
    from counted_rows
    order by %6$s
    limit $7
    offset ($8 - 1) * $7
  $sql$, v_table, v_model_id_expression, v_model_version_expression,
    v_score_expression, v_match_clause, v_order_clause);

  return query execute v_sql
    using v_source_filter, v_publication_filter, v_filter, v_terms,
      v_uuid_pattern, v_kind, v_page_size, v_page_current;
end;
$_$;

alter function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text)
  owner to postgres;
revoke all on function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text)
  from public, anon, authenticated, service_role;
grant execute on function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text)
  to anon, authenticated, api_internal_executor;

comment on function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text) is
  'Lists or searches latest state-100 Open Data rows with source and exact-version Process publication filters applied before count and pagination.';

create or replace function api.hybrid_search_open_data_catalog(
  p_dataset_kind text,
  query_text text,
  query_embedding text,
  filter_condition jsonb default '{}'::jsonb,
  match_threshold double precision default 0.5,
  match_count integer default 20,
  lexical_weight double precision default 0.5,
  semantic_weight double precision default 0.5,
  rrf_k integer default 10,
  page_size integer default 10,
  page_current integer default 1,
  query_terms text[] default null,
  source_filter text default 'all',
  publication_filter text default 'all'
)
returns table (
  id uuid,
  "json" jsonb,
  version character(9),
  modified_at timestamptz,
  team_id uuid,
  model_id uuid,
  model_version character(9),
  is_published boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path to api, private, public, util, extensions, pg_temp
set statement_timeout to '60s'
as $_$
declare
  v_kind text := lower(btrim(coalesce(p_dataset_kind, '')));
  v_source_filter text := lower(btrim(coalesce(source_filter, 'all')));
  v_publication_filter text := lower(btrim(coalesce(publication_filter, 'all')));
  v_table regclass;
  v_model_id_expression text := 'null::uuid';
  v_model_version_expression text := 'null::character(9)';
  v_terms text[];
  v_filter jsonb := coalesce(filter_condition, '{}'::jsonb);
  v_page_size integer := least(greatest(coalesce(page_size, 10), 1), 100);
  v_page_current integer := greatest(coalesce(page_current, 1), 1);
  v_candidate_limit integer := least(greatest(coalesce(match_count, 20), v_page_size) * 10, 2000);
  v_threshold_distance double precision := 1 - least(greatest(coalesce(match_threshold, 0.5), -1), 1);
  v_sql text;
begin
  v_table := case v_kind
    when 'process' then 'public.processes'::regclass
    when 'flow' then 'public.flows'::regclass
    when 'lifecyclemodel' then 'public.lifecyclemodels'::regclass
    when 'contact' then 'public.contacts'::regclass
    when 'source' then 'public.sources'::regclass
    when 'unitgroup' then 'public.unitgroups'::regclass
    when 'flowproperty' then 'public.flowproperties'::regclass
    else null
  end;
  if v_table is null then
    raise exception using errcode = '22023', message = 'unsupported p_dataset_kind';
  end if;
  if v_source_filter not in ('all', 'literature', 'enterprise') then
    raise exception using errcode = '22023', message = 'source_filter must be all, literature, or enterprise';
  end if;
  if v_publication_filter not in ('all', 'published', 'unpublished') then
    raise exception using errcode = '22023', message = 'publication_filter must be all, published, or unpublished';
  end if;
  if v_kind <> 'process' and v_publication_filter <> 'all' then
    raise exception using errcode = '22023', message = 'publication filter is supported only for Process data';
  end if;
  if coalesce(btrim(query_text), '') = '' then
    raise exception using errcode = '22023', message = 'query_text is required';
  end if;

  v_terms := private.pgroonga_escape_query_terms(query_terms);
  if cardinality(v_terms) = 0 then
    v_terms := private.pgroonga_escape_query_terms(array[query_text]);
  end if;
  if v_kind = 'process' then
    v_model_id_expression := 'd.model_id';
    v_model_version_expression := 'd.model_version';
  end if;

  v_sql := format($sql$
    with lexical_candidates as materialized (
      select
        d.id,
        pgroonga_score(d.tableoid, d.ctid) as score
      from %1$s d
      where d.state_code = 100
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($5, d.json, $3)
        and d.search_text &@~| $4
      order by score desc, d.modified_at desc, d.id
      limit $7
    ),
    lexical as (
      select
        lexical_candidates.id,
        rank() over (order by max(lexical_candidates.score) desc, lexical_candidates.id)::bigint as lexical_rank
      from lexical_candidates
      group by lexical_candidates.id
    ),
    semantic_candidates as materialized (
      select
        d.id,
        d.embedding_ft <=> $6::extensions.vector(1024) as distance
      from %1$s d
      where d.state_code = 100
        and d.embedding_ft is not null
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($5, d.json, $3)
        and (d.embedding_ft <=> $6::extensions.vector(1024)) < $8
      order by d.embedding_ft <=> $6::extensions.vector(1024), d.id
      limit $7
    ),
    semantic as (
      select
        semantic_candidates.id,
        rank() over (order by min(semantic_candidates.distance), semantic_candidates.id)::bigint as semantic_rank
      from semantic_candidates
      group by semantic_candidates.id
    ),
    fused as (
      select
        coalesce(lexical.id, semantic.id) as id,
        coalesce(1.0 / ($9 + lexical.lexical_rank), 0.0) * $10
          + coalesce(1.0 / ($9 + semantic.semantic_rank), 0.0) * $11 as score
      from lexical
      full outer join semantic using (id)
    ),
    visible_rows as (
      select
        d.id,
        d.json,
        d.version,
        d.modified_at,
        d.team_id,
        %2$s as model_id,
        %3$s as model_version,
        case when $5 = 'process' then exists (
          select 1 from private.open_data_process_publications publication
          where publication.process_id = d.id and publication.process_version = d.version
        ) else false end as is_published,
        fused.score
      from %1$s d
      join fused using (id)
      where d.state_code = 100
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($5, d.json, $3)
    ),
    latest_rows as (
      select distinct on (visible_rows.id) visible_rows.*
      from visible_rows
      order by visible_rows.id, visible_rows.version desc, visible_rows.modified_at desc
    ),
    filtered_rows as (
      select latest_rows.*
      from latest_rows
      where $5 <> 'process'
        or $2 = 'all'
        or ($2 = 'published' and latest_rows.is_published)
        or ($2 = 'unpublished' and not latest_rows.is_published)
    ),
    counted_rows as (
      select filtered_rows.*, count(*) over()::bigint as total_count
      from filtered_rows
    )
    select
      counted_rows.id,
      counted_rows.json,
      counted_rows.version,
      counted_rows.modified_at,
      counted_rows.team_id,
      counted_rows.model_id,
      counted_rows.model_version,
      counted_rows.is_published,
      counted_rows.total_count
    from counted_rows
    order by counted_rows.score desc, counted_rows.modified_at desc, counted_rows.id
    limit $12
    offset ($13 - 1) * $12
  $sql$, v_table, v_model_id_expression, v_model_version_expression);

  return query execute v_sql
    using v_source_filter, v_publication_filter, v_filter, v_terms, v_kind,
      query_embedding, v_candidate_limit, v_threshold_distance, greatest(coalesce(rrf_k, 10), 1),
      greatest(coalesce(lexical_weight, 0.5), 0), greatest(coalesce(semantic_weight, 0.5), 0),
      v_page_size, v_page_current;
end;
$_$;

alter function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text)
  owner to postgres;
revoke all on function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text)
  from public, anon, authenticated, service_role;
grant execute on function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text)
  to anon, authenticated, api_internal_executor;

comment on function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text) is
  'Hybrid Open Data search with source and exact-version Process publication filters applied to lexical and semantic candidates before fusion, count, and pagination.';

insert into private.api_capability_grants (
  routine_identity,
  capability_id,
  allow_anon,
  allow_authenticated,
  allow_service_role
) values
  (
    'api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text)',
    'NX-CORE-02',
    true,
    true,
    false
  ),
  (
    'api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text)',
    'NX-CORE-02',
    true,
    true,
    false
  ),
  (
    'api.cmd_open_data_process_publish_batch(jsonb)',
    'CLI-RPC-01',
    false,
    true,
    false
  )
on conflict (routine_identity) do update set
  capability_id = excluded.capability_id,
  allow_anon = excluded.allow_anon,
  allow_authenticated = excluded.allow_authenticated,
  allow_service_role = excluded.allow_service_role;

notify pgrst, 'reload schema';
