CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_scalar_ok"("p_value" "jsonb", "p_pattern" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  -- coalesce is load-bearing: for an absent key the argument is SQL NULL and `jsonb_typeof(NULL) =
  -- 'string'` is NULL, not false, so an uncoalesced helper would return NULL and every
  -- `not helper(...)` guard would silently pass. An absent, null, wrongly-typed or malformed value
  -- all return false here.
  select coalesce(jsonb_typeof(p_value) = 'string' and (p_value #>> '{}') ~ p_pattern, false)
$$;

ALTER FUNCTION "private"."dataset_length_time_v1_scalar_ok"("p_value" "jsonb", "p_pattern" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_scalar_ok"("p_value" "jsonb", "p_pattern" "text") FROM PUBLIC;
