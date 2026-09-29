CREATE OR REPLACE FUNCTION "private"."review_report_reference_matches_v1"("p_payload" "jsonb", "p_source_id" "uuid", "p_source_version" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  with recursive nodes(node, parent_key) as (
    select coalesce(p_payload, 'null'::jsonb), null::text
    union all
    select child.node, coalesce(child.key, nodes.parent_key)
    from nodes
    cross join lateral (
      select object_item.key, object_item.value as node
      from pg_catalog.jsonb_each(
        case when pg_catalog.jsonb_typeof(nodes.node) = 'object'
          then nodes.node else '{}'::jsonb end
      ) as object_item
      union all
      select null::text, array_item.value
      from pg_catalog.jsonb_array_elements(
        case when pg_catalog.jsonb_typeof(nodes.node) = 'array'
          then nodes.node else '[]'::jsonb end
      ) as array_item
    ) as child
  )
  select exists (
    select 1
    from nodes
    where nodes.parent_key = 'common:referenceToCompleteReviewReport'
      and pg_catalog.jsonb_typeof(nodes.node) = 'object'
      and nodes.node->>'@refObjectId' = p_source_id::text
      and nodes.node->>'@version' = p_source_version
  );
$$;

ALTER FUNCTION "private"."review_report_reference_matches_v1"("p_payload" "jsonb", "p_source_id" "uuid", "p_source_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."review_report_reference_matches_v1"("p_payload" "jsonb", "p_source_id" "uuid", "p_source_version" "text") FROM PUBLIC;
