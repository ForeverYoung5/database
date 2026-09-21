CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_factor"() RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select 1000::numeric
$$;

ALTER FUNCTION "private"."dataset_length_time_v1_factor"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_factor"() FROM PUBLIC;
