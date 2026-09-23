CREATE OR REPLACE FUNCTION "api"."qry_sample_library_datasets_v1"("p_dataset_type" "text", "p_origin" "text" DEFAULT 'all'::"text", "p_publication_status" "text" DEFAULT 'all'::"text", "p_page_size" integer DEFAULT 20, "p_page_current" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_dataset_type text := lower(coalesce(p_dataset_type, ''));
  v_origin text := lower(coalesce(p_origin, 'all'));
  v_publication_status text := lower(coalesce(p_publication_status, 'all'));
  v_table_name text;
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_page_current integer := greatest(coalesce(p_page_current, 1), 1);
  v_result jsonb;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'auth_required', 'status', 401,
      'message', 'Authentication required');
  end if;
  if not private.lca_release_is_manager() then
    return jsonb_build_object('ok', false, 'code', 'not_data_product_manager',
      'status', 403, 'message', 'Data product manager role is required');
  end if;

  v_table_name := case v_dataset_type
    when 'lifecyclemodels' then 'lifecyclemodels'
    when 'processes' then 'processes'
    when 'flows' then 'flows'
    when 'flowproperties' then 'flowproperties'
    when 'unitgroups' then 'unitgroups'
    when 'sources' then 'sources'
    when 'contacts' then 'contacts'
    else null
  end;

  if v_table_name is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_dataset_type', 'status', 400,
      'message', 'Unsupported sample-library dataset type');
  end if;
  if v_origin not in ('all', 'literature', 'enterprise') then
    return jsonb_build_object('ok', false, 'code', 'invalid_origin', 'status', 400,
      'message', 'origin must be all, literature, or enterprise');
  end if;
  if v_publication_status not in ('all', 'published', 'unpublished') then
    return jsonb_build_object('ok', false, 'code', 'invalid_publication_status', 'status', 400,
      'message', 'publication status must be all, published, or unpublished');
  end if;
  if v_dataset_type <> 'processes' and v_publication_status <> 'all' then
    return jsonb_build_object('ok', false, 'code', 'publication_status_not_supported',
      'status', 400, 'message', 'Publication status applies only to Processes');
  end if;

  execute format($sql$
    with latest as (
      select distinct on (source.id)
        source.id,
        source.version,
        source.user_id,
        coalesce(source.json, source.json_ordered::jsonb) as content,
        source.modified_at
      from public.%I as source
      where source.state_code = 100
      order by source.id, source.version desc, source.modified_at desc nulls last
    ), filtered as (
      select
        latest.id,
        latest.version,
        latest.content,
        latest.modified_at,
        case when latest.user_id is null then 'literature' else 'enterprise' end as origin,
        publication.published_at
      from latest
      left join private.sample_library_process_publications as publication
        on $3 = 'processes'
       and publication.process_id = latest.id
       and publication.process_version = latest.version
      where ($4 = 'all'
        or ($4 = 'literature' and latest.user_id is null)
        or ($4 = 'enterprise' and latest.user_id is not null))
        and ($3 <> 'processes'
          or $5 = 'all'
          or ($5 = 'published' and publication.process_id is not null)
          or ($5 = 'unpublished' and publication.process_id is null))
    ), page as (
      select *
      from filtered
      order by modified_at desc nulls last, id, version desc
      limit $1 offset $2
    )
    select jsonb_build_object(
      'ok', true,
      'data', jsonb_build_object(
        'datasetType', $3,
        'page', $6,
        'pageSize', $1,
        'total', (select count(*) from filtered),
        'items', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', page.id,
            'version', page.version,
            'json', page.content,
            'modifiedAt', page.modified_at,
            'origin', page.origin,
            'published', case when $3 = 'processes'
              then page.published_at is not null else null end,
            'publishedAt', page.published_at
          ) order by page.modified_at desc nulls last, page.id, page.version desc)
          from page
        ), '[]'::jsonb)
      )
    )
  $sql$, v_table_name)
  into v_result
  using v_page_size, (v_page_current - 1) * v_page_size,
    v_dataset_type, v_origin, v_publication_status, v_page_current;

  return v_result;
end;
$_$;

ALTER FUNCTION "api"."qry_sample_library_datasets_v1"("p_dataset_type" "text", "p_origin" "text", "p_publication_status" "text", "p_page_size" integer, "p_page_current" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_sample_library_datasets_v1"("p_dataset_type" "text", "p_origin" "text", "p_publication_status" "text", "p_page_size" integer, "p_page_current" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_sample_library_datasets_v1"("p_dataset_type" "text", "p_origin" "text", "p_publication_status" "text", "p_page_size" integer, "p_page_current" integer) TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."qry_sample_library_datasets_v1"("p_dataset_type" "text", "p_origin" "text", "p_publication_status" "text", "p_page_size" integer, "p_page_current" integer) TO "authenticated";
