CREATE OR REPLACE FUNCTION "private"."result_process_receipt_json_v1"("p_receipt" "private"."result_process_publications") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select jsonb_build_object(
    'schemaVersion', 'result-process.publication-receipt.v1',
    'receiptId', p_receipt.id,
    'actorUserId', p_receipt.actor_user_id,
    'id', p_receipt.dataset_id,
    'version', p_receipt.dataset_version,
    'stateCode', p_receipt.state_code,
    'role', p_receipt.role,
    'targetState', p_receipt.target_state,
    'contentSha256', p_receipt.content_sha256,
    'hashDomain', p_receipt.hash_domain,
    'sourceKind', p_receipt.source_kind,
    'candidateSetHash', p_receipt.candidate_set_hash,
    'sourceManifestHash', p_receipt.source_manifest_hash,
    'executablePlanHash', p_receipt.executable_plan_hash,
    'approvalHash', p_receipt.approval_hash,
    'preparationHash', p_receipt.preparation_hash,
    'idempotencyKey', p_receipt.idempotency_key,
    'publishedAt', p_receipt.published_at,
    'reason', p_receipt.reason
  )
$$;

ALTER FUNCTION "private"."result_process_receipt_json_v1"("p_receipt" "private"."result_process_publications") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_process_receipt_json_v1"("p_receipt" "private"."result_process_publications") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."result_process_receipt_json_v1"("p_receipt" "private"."result_process_publications") TO "api_internal_executor";
