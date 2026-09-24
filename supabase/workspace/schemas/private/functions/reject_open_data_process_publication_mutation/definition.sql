CREATE OR REPLACE FUNCTION "private"."reject_open_data_process_publication_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'pg_temp'
    AS $$
begin
  raise exception using
    errcode = '55000',
    message = 'Open Data Process publications are append-only';
end;
$$;

ALTER FUNCTION "private"."reject_open_data_process_publication_mutation"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."reject_open_data_process_publication_mutation"() FROM PUBLIC;
