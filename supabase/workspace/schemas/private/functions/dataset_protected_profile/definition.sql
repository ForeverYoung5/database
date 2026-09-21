CREATE OR REPLACE FUNCTION "private"."dataset_protected_profile"("p_plan" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when jsonb_typeof(p_plan) is distinct from 'object' then null
    when p_plan->>'schema_version' = 'dataset-alias-plan.v2' then 'alias_v2'
    when p_plan->>'schema_version' = 'dataset-length-time-plan.v1' then 'length_time_v1'
    else null
  end
$$;

ALTER FUNCTION "private"."dataset_protected_profile"("p_plan" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_protected_profile"("p_plan" "jsonb") FROM PUBLIC;
