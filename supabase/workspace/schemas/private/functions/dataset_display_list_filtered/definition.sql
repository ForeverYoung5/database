CREATE OR REPLACE FUNCTION "private"."dataset_display_list_filtered"("p_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_candidates" boolean, "p_filter_condition" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $_$
declare result_json jsonb; filter_json jsonb := coalesce(p_filter_condition,'{}'::jsonb); search_sql text := ''; filter_sql text := '';
begin
  if auth.uid() is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_candidates then perform private.dataset_display_require_manager(); end if;
  if p_kind is null or p_kind not in ('all','lifecyclemodel','process','flow','flowproperty','unitgroup','source','contact')
    or p_visibility is null or p_visibility not in ('all','visible','hidden')
    or p_query is null or pg_catalog.octet_length(p_query)>512
    or p_page_size is null or p_page_size not between 1 and 100
    or p_page is null or p_page not between 1 and 1000000 then
    raise exception using errcode='22023',message='invalid display list filters or pagination';
  end if;
  perform private.dataset_catalog_filter_validate(filter_json);
  if filter_json ?| array['datasetId','sourceEntityKinds'] then raise exception using errcode='22023',message='display lists do not accept identity filters'; end if;
  if p_kind='all' and pg_catalog.jsonb_array_length(coalesce(filter_json->'classification','[]'::jsonb))>0 then
    raise exception using errcode='22023',message='select a dataset kind before classification';
  end if;
  if p_query<>'' then
    search_sql := ' and (strpos(lower(coalesce(c.name::text,'''')),lower($3))>0 or strpos(c.dataset_id::text,lower($3))>0)';
  end if;
  if filter_json<>'{}'::jsonb and filter_json<>'{"classification":[]}'::jsonb then
    filter_sql := ' and private.dataset_catalog_filter_matches(c.dataset_kind,private.dataset_catalog_source_json(c.dataset_kind,c.dataset_id,c.dataset_version),$7)';
  end if;
  execute $query$
    with eligible as materialized (
      select c.dataset_kind,c.dataset_id,c.dataset_version,coalesce(s.is_visible,false) as is_visible
      from private.dataset_display_catalog c
      left join private.dataset_display_settings s using(dataset_kind,dataset_id,dataset_version)
      where ($1='all' or c.dataset_kind=$1) and ($6 or s.is_visible)
        and ($2='all' or ($2='visible' and s.is_visible) or ($2='hidden' and not coalesce(s.is_visible,false)))
    $query$||search_sql||filter_sql||$query$
    ), page as materialized (
      select * from eligible order by dataset_kind,dataset_id,dataset_version desc limit $4 offset ($5::bigint-1)*$4
    ), hydrated as (
      select page.*,case when octet_length(c.name::text)<=16384 then c.name else null end as name,
        private.dataset_catalog_display_metadata(page.dataset_kind,
          private.dataset_catalog_source_json(page.dataset_kind,page.dataset_id,page.dataset_version)) as metadata
      from page cross join lateral (
        select source.name from private.dataset_display_catalog source
        where source.dataset_kind=page.dataset_kind and source.dataset_id=page.dataset_id and source.dataset_version=page.dataset_version offset 0
      ) c
    ) select jsonb_build_object('data',coalesce((select jsonb_agg(
      (case when $6 then to_jsonb(hydrated)-'metadata' else to_jsonb(hydrated)-'metadata'-'is_visible' end)||hydrated.metadata
      order by dataset_kind,dataset_id,dataset_version desc) from hydrated),'[]'::jsonb),'total',(select count(*) from eligible))
  $query$ into result_json using p_kind,p_visibility,p_query,p_page_size,p_page,p_candidates,filter_json;
  return result_json;
end;
$_$;

ALTER FUNCTION "private"."dataset_display_list_filtered"("p_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_candidates" boolean, "p_filter_condition" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_display_list_filtered"("p_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_candidates" boolean, "p_filter_condition" "jsonb") FROM PUBLIC;
