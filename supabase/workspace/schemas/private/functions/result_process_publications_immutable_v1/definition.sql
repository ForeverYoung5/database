CREATE OR REPLACE FUNCTION "private"."result_process_publications_immutable_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  raise exception using
    errcode = '55000',
    message = 'RESULT_PROCESS_ATTESTATION_IMMUTABLE',
    detail = 'A Result Process publication attestation is append-only.';
end;
$$;

ALTER FUNCTION "private"."result_process_publications_immutable_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_process_publications_immutable_v1"() FROM PUBLIC;
