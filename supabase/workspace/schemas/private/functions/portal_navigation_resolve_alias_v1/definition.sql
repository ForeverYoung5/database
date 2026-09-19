CREATE OR REPLACE FUNCTION "private"."portal_navigation_resolve_alias_v1"("p_dimension" "text", "p_code" "text") RETURNS "text"
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case when count(*)=1 then min(n.node_id) else null end
  from private.portal_navigation_node_v1 n
  where n.dimension=p_dimension and cardinality(n.alias_codes)>0
    and n.alias_codes @> array[upper(btrim(p_code))]
$$;

ALTER FUNCTION "private"."portal_navigation_resolve_alias_v1"("p_dimension" "text", "p_code" "text") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_resolve_alias_v1"("p_dimension" "text", "p_code" "text") FROM PUBLIC;
