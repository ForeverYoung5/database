CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_derivative_target_ok"("p_target" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select jsonb_typeof(p_target) = 'object'
    and not exists (
      select 1
      from jsonb_object_keys(p_target) as key(name)
      where key.name <> all (array['table', 'id', 'version', 'user_id', 'state_code', 'baseline_snapshot_sha256'])
    )
    and (p_target->>'table') in ('flows', 'processes')
    and coalesce(p_target->>'id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and coalesce(p_target->>'version', '') ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
    and coalesce(p_target->>'user_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and coalesce(p_target->>'state_code', '') = '0'
    and coalesce(p_target->>'baseline_snapshot_sha256', '') ~ '^[a-f0-9]{64}$'
$_$;

ALTER FUNCTION "private"."dataset_alias_v2_derivative_target_ok"("p_target" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_derivative_target_ok"("p_target" "jsonb") FROM PUBLIC;
