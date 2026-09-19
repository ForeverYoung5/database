CREATE OR REPLACE FUNCTION "private"."portal_navigation_ensure_virtual_v1"("p_node_id" "text", "p_dimension" "text", "p_taxonomy" "text", "p_labels_key" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
  insert into private.portal_navigation_node_v1 (
    node_id, parent_node_id, code, taxonomy, dimension,
    source_index_path, source_file, labels, label_strategy
  ) values (
    p_node_id, null, '~', p_taxonomy, p_dimension, null, null,
    private.portal_navigation_virtual_labels_v1(p_labels_key),
    pg_catalog.jsonb_build_object(
      'en', 'database-virtual-container', 'zh-CN', 'database-virtual-container',
      'de', 'database-virtual-container', 'fr', 'database-virtual-container'
    )
  )
  on conflict (node_id) do nothing
$$;

ALTER FUNCTION "private"."portal_navigation_ensure_virtual_v1"("p_node_id" "text", "p_dimension" "text", "p_taxonomy" "text", "p_labels_key" "text") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_ensure_virtual_v1"("p_node_id" "text", "p_dimension" "text", "p_taxonomy" "text", "p_labels_key" "text") FROM PUBLIC;
