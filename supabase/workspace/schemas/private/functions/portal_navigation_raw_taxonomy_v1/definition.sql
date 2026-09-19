CREATE OR REPLACE FUNCTION "private"."portal_navigation_raw_taxonomy_v1"("p_system" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case pg_catalog.lower(pg_catalog.btrim(coalesce(
    p_system ->> '#text',
    p_system ->> '@name',
    case when pg_catalog.jsonb_typeof(p_system) = 'string' then p_system #>> '{}' end,
    ''
  )))
    when 'isic' then 'isic'
    when 'cpc' then 'cpc'
    when 'elementary-flow' then 'elementary'
    when 'ilcd-flow-categorization' then 'elementary'
    else 'unclassified'
  end;
$$;

ALTER FUNCTION "private"."portal_navigation_raw_taxonomy_v1"("p_system" "jsonb") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_raw_taxonomy_v1"("p_system" "jsonb") FROM PUBLIC;
