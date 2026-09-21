CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_nonneg_int_ok"("p_value" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select coalesce(jsonb_typeof(p_value) = 'number' and (p_value #>> '{}') ~ '^[0-9]+$', false)
$_$;

ALTER FUNCTION "private"."dataset_length_time_v1_nonneg_int_ok"("p_value" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_nonneg_int_ok"("p_value" "jsonb") FROM PUBLIC;
