CREATE OR REPLACE FUNCTION "api"."list_dataset_display_candidates_filtered"("p_dataset_kind" "text" DEFAULT 'all'::"text", "p_visibility" "text" DEFAULT 'all'::"text", "p_query" "text" DEFAULT ''::"text", "p_page_size" integer DEFAULT 50, "p_page" integer DEFAULT 1, "p_filter_condition" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $$
 select private.dataset_display_list_filtered(p_dataset_kind,p_visibility,p_query,p_page_size,p_page,true,p_filter_condition);
$$;

ALTER FUNCTION "api"."list_dataset_display_candidates_filtered"("p_dataset_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_filter_condition" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."list_dataset_display_candidates_filtered"("p_dataset_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_filter_condition" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."list_dataset_display_candidates_filtered"("p_dataset_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_filter_condition" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "api"."list_dataset_display_candidates_filtered"("p_dataset_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_filter_condition" "jsonb") TO "api_internal_executor";
