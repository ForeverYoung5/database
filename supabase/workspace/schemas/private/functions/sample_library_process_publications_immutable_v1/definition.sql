CREATE OR REPLACE FUNCTION "private"."sample_library_process_publications_immutable_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  raise exception using
    errcode = '55000',
    message = 'SAMPLE_LIBRARY_PUBLICATION_IMMUTABLE',
    detail = 'A sample-library Process publication is append-only.';
end;
$$;

ALTER FUNCTION "private"."sample_library_process_publications_immutable_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."sample_library_process_publications_immutable_v1"() FROM PUBLIC;
