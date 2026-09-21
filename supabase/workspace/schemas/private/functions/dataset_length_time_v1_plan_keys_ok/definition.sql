CREATE OR REPLACE FUNCTION "private"."dataset_length_time_v1_plan_keys_ok"("p_plan" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select jsonb_typeof(p_plan) = 'object'
    and not exists (
      select 1
      from jsonb_object_keys(p_plan) as key(name)
      where key.name <> all (array[
        'schema_version', 'actor_id', 'target_visibility', 'flow_snapshots',
        'target_flow_property', 'target_unit_group', 'source_evidence', 'expected',
        'actions', 'plan_sha256'
      ])
    )
$$;

ALTER FUNCTION "private"."dataset_length_time_v1_plan_keys_ok"("p_plan" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_length_time_v1_plan_keys_ok"("p_plan" "jsonb") FROM PUBLIC;
