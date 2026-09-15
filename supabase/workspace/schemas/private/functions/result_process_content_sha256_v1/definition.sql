CREATE OR REPLACE FUNCTION "private"."result_process_content_sha256_v1"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select encode(extensions.digest(convert_to(p_text, 'UTF8'), 'sha256'), 'hex')
$$;

ALTER FUNCTION "private"."result_process_content_sha256_v1"("p_text" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_process_content_sha256_v1"("p_text" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."result_process_content_sha256_v1"("p_text" "text") TO "api_internal_executor";
