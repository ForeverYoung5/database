CREATE OR REPLACE FUNCTION "api"."search_open_data_catalog"("p_dataset_kind" "text", "p_search_mode" "text" DEFAULT 'list'::"text", "p_query_text" "text" DEFAULT ''::"text", "p_query_terms" "text"[] DEFAULT NULL::"text"[], "p_filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "p_source_filter" "text" DEFAULT 'all'::"text", "p_publication_filter" "text" DEFAULT 'all'::"text", "p_page_size" integer DEFAULT 10, "p_page_current" integer DEFAULT 1, "p_sort_by" "text" DEFAULT 'modified_at'::"text", "p_sort_direction" "text" DEFAULT 'desc'::"text") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "model_id" "uuid", "model_version" character, "is_published" boolean, "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $_$
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

ALTER FUNCTION "api"."search_open_data_catalog"("p_dataset_kind" "text", "p_search_mode" "text", "p_query_text" "text", "p_query_terms" "text"[], "p_filter_condition" "jsonb", "p_source_filter" "text", "p_publication_filter" "text", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."search_open_data_catalog"("p_dataset_kind" "text", "p_search_mode" "text", "p_query_text" "text", "p_query_terms" "text"[], "p_filter_condition" "jsonb", "p_source_filter" "text", "p_publication_filter" "text", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."search_open_data_catalog"("p_dataset_kind" "text", "p_search_mode" "text", "p_query_text" "text", "p_query_terms" "text"[], "p_filter_condition" "jsonb", "p_source_filter" "text", "p_publication_filter" "text", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text") TO "anon";

GRANT ALL ON FUNCTION "api"."search_open_data_catalog"("p_dataset_kind" "text", "p_search_mode" "text", "p_query_text" "text", "p_query_terms" "text"[], "p_filter_condition" "jsonb", "p_source_filter" "text", "p_publication_filter" "text", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text") TO "authenticated";

GRANT ALL ON FUNCTION "api"."search_open_data_catalog"("p_dataset_kind" "text", "p_search_mode" "text", "p_query_text" "text", "p_query_terms" "text"[], "p_filter_condition" "jsonb", "p_source_filter" "text", "p_publication_filter" "text", "p_page_size" integer, "p_page_current" integer, "p_sort_by" "text", "p_sort_direction" "text") TO "api_internal_executor";
