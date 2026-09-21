CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_derivative_chunks"("p_request_id" "uuid", "p_plan_sha256" "text", "p_targets" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'ordinal', chunk.ordinal,
    'batch_id', (
      substr(chunk.digest, 1, 8) || '-' || substr(chunk.digest, 9, 4) || '-'
      || substr(chunk.digest, 13, 4) || '-' || substr(chunk.digest, 17, 4) || '-'
      || substr(chunk.digest, 21, 12)
    )::uuid,
    'target_count', jsonb_array_length(chunk.targets),
    'targets', chunk.targets
  ) order by chunk.ordinal), '[]'::jsonb)
  from (
    select (entry.ordinality - 1) / 50 + 1 as ordinal,
           md5(p_request_id::text || ':' || p_plan_sha256 || ':' || (((entry.ordinality - 1) / 50 + 1))::text) as digest,
           jsonb_agg(entry.value order by entry.ordinality) as targets
    from jsonb_array_elements(coalesce(p_targets, '[]'::jsonb)) with ordinality as entry(value, ordinality)
    group by 1, 2
  ) as chunk
$$;

ALTER FUNCTION "private"."dataset_alias_v2_derivative_chunks"("p_request_id" "uuid", "p_plan_sha256" "text", "p_targets" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_derivative_chunks"("p_request_id" "uuid", "p_plan_sha256" "text", "p_targets" "jsonb") FROM PUBLIC;
