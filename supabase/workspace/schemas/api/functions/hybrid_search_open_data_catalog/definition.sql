CREATE OR REPLACE FUNCTION "api"."hybrid_search_open_data_catalog"("p_dataset_kind" "text", "query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "source_filter" "text" DEFAULT 'all'::"text", "publication_filter" "text" DEFAULT 'all'::"text") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "model_id" "uuid", "model_version" character, "is_published" boolean, "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $_$
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

ALTER FUNCTION "api"."hybrid_search_open_data_catalog"("p_dataset_kind" "text", "query_text" "text", "query_embedding" "text", "filter_condition" "jsonb", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "page_size" integer, "page_current" integer, "query_terms" "text"[], "source_filter" "text", "publication_filter" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."hybrid_search_open_data_catalog"("p_dataset_kind" "text", "query_text" "text", "query_embedding" "text", "filter_condition" "jsonb", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "page_size" integer, "page_current" integer, "query_terms" "text"[], "source_filter" "text", "publication_filter" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."hybrid_search_open_data_catalog"("p_dataset_kind" "text", "query_text" "text", "query_embedding" "text", "filter_condition" "jsonb", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "page_size" integer, "page_current" integer, "query_terms" "text"[], "source_filter" "text", "publication_filter" "text") TO "anon";

GRANT ALL ON FUNCTION "api"."hybrid_search_open_data_catalog"("p_dataset_kind" "text", "query_text" "text", "query_embedding" "text", "filter_condition" "jsonb", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "page_size" integer, "page_current" integer, "query_terms" "text"[], "source_filter" "text", "publication_filter" "text") TO "authenticated";

GRANT ALL ON FUNCTION "api"."hybrid_search_open_data_catalog"("p_dataset_kind" "text", "query_text" "text", "query_embedding" "text", "filter_condition" "jsonb", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "page_size" integer, "page_current" integer, "query_terms" "text"[], "source_filter" "text", "publication_filter" "text") TO "api_internal_executor";
