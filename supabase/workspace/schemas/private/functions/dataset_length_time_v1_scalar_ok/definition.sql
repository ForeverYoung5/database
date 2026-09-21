CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_scalar_ok"("p_value" "jsonb", "p_pattern" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select jsonb_typeof(p_value) = 'string' and (p_value #>> '{}') ~ p_pattern
$$;

ALTER FUNCTION "private"."dataset_length_time_v1_scalar_ok"("p_value" "jsonb", "p_pattern" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_scalar_ok"("p_value" "jsonb", "p_pattern" "text") FROM PUBLIC;
