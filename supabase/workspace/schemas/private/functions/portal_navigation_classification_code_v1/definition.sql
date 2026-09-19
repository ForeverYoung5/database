CREATE OR REPLACE FUNCTION "private"."portal_navigation_classification_code_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select nullif(
    pg_catalog.btrim(coalesce(
      p_value ->> '@classId',
      p_value ->> 'code',
      p_value ->> '#text'
    )),
    ''
  )
$$;

ALTER FUNCTION "private"."portal_navigation_classification_code_v1"("p_value" "jsonb") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_classification_code_v1"("p_value" "jsonb") FROM PUBLIC;
