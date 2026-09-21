CREATE OR REPLACE FUNCTION "private"."dataset_alias_v2_payload_sha256"("p_payload" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select encode(extensions.digest(convert_to(private.dataset_alias_canonical_jsonb_v1(p_payload)::text, 'UTF8'), 'sha256'), 'hex')
$$;

ALTER FUNCTION "private"."dataset_alias_v2_payload_sha256"("p_payload" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_alias_v2_payload_sha256"("p_payload" "jsonb") FROM PUBLIC;
