CREATE OR REPLACE FUNCTION "private"."catalog_portal_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("dataset_kind" "text", "id" "uuid", "version" "text", "card" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "row_security" TO 'on'
    AS $$
  select candidate.dataset_kind,
    candidate.id,
    candidate.version,
    candidate.card
  from private.catalog_portal_facet_candidate_rows_v2(
    p_kind, p_query, p_exact_id, p_like_pattern
  ) as candidate
$$;

ALTER FUNCTION "private"."catalog_portal_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."catalog_portal_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."catalog_portal_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") TO "api_internal_executor";
