CREATE OR REPLACE FUNCTION "private"."portal_navigation_virtual_labels_v1"("p_key" "text") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case p_key
    when 'unclassified' then pg_catalog.jsonb_build_object(
      'en', 'Unclassified', 'zh-CN', '未分类', 'de', 'Nicht klassifiziert', 'fr', 'Non classé'
    )
    else pg_catalog.jsonb_build_object(
      'en', 'Unmapped locations', 'zh-CN', '未映射地区',
      'de', 'Nicht zugeordnete Standorte', 'fr', 'Localisations non mappées'
    )
  end;
$$;

ALTER FUNCTION "private"."portal_navigation_virtual_labels_v1"("p_key" "text") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_virtual_labels_v1"("p_key" "text") FROM PUBLIC;
