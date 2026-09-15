CREATE OR REPLACE FUNCTION "private"."result_process_preparation_hash_v1"("p_actor" "uuid", "p_id" "uuid", "p_version" "text", "p_content_sha256" "text", "p_source" "jsonb", "p_reason" "text", "p_classification" "text", "p_state" integer) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select encode(extensions.digest(convert_to(
    private.lcia_scope_closure_worker_canonical_json_text(jsonb_build_object(
      'domain', 'result-process-preparation.v1',
      'actorUserId', p_actor,
      'id', p_id,
      'version', p_version,
      'contentSha256', p_content_sha256,
      'sourceKind', 'manager_attestation',
      'candidateSetHash', p_source ->> 'candidateSetHash',
      'sourceManifestHash', p_source ->> 'sourceManifestHash',
      'reason', p_reason,
      'classification', p_classification,
      'existingState', p_state
    )), 'UTF8'), 'sha256'), 'hex')
$$;

ALTER FUNCTION "private"."result_process_preparation_hash_v1"("p_actor" "uuid", "p_id" "uuid", "p_version" "text", "p_content_sha256" "text", "p_source" "jsonb", "p_reason" "text", "p_classification" "text", "p_state" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_process_preparation_hash_v1"("p_actor" "uuid", "p_id" "uuid", "p_version" "text", "p_content_sha256" "text", "p_source" "jsonb", "p_reason" "text", "p_classification" "text", "p_state" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."result_process_preparation_hash_v1"("p_actor" "uuid", "p_id" "uuid", "p_version" "text", "p_content_sha256" "text", "p_source" "jsonb", "p_reason" "text", "p_classification" "text", "p_state" integer) TO "api_internal_executor";
