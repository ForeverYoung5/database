CREATE OR REPLACE FUNCTION "private"."open_data_catalog_filter_matches"("p_dataset_kind" "text", "p_json" "jsonb", "p_filter_condition" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'pg_catalog', 'pg_temp'
    AS $$ select private.dataset_catalog_filter_matches(p_dataset_kind,p_json,p_filter_condition) $$;

ALTER FUNCTION "private"."open_data_catalog_filter_matches"("p_dataset_kind" "text", "p_json" "jsonb", "p_filter_condition" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."open_data_catalog_filter_matches"("p_dataset_kind" "text", "p_json" "jsonb", "p_filter_condition" "jsonb") FROM PUBLIC;
