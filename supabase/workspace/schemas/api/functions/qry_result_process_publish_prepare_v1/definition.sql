CREATE OR REPLACE FUNCTION "api"."qry_result_process_publish_prepare_v1"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid := auth.uid();
  v_check jsonb;
  v_id uuid;
  v_version text;
  v_source jsonb;
  v_reason text;
  v_content_sha text;
  v_validation jsonb;
  v_classification text;
  v_state integer;
  v_stored text;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'auth_required', 'status', 401,
      'message', 'Authentication required');
  end if;
  if not private.lca_release_is_manager() then
    return jsonb_build_object('ok', false, 'code', 'not_data_product_manager',
      'status', 403, 'message', 'Data product manager role is required');
  end if;

  v_check := private.result_process_publish_validate_v1(p_request, 'prepare');
  if not (v_check->>'ok')::boolean then
    return v_check;
  end if;

  v_id := (p_request->>'id')::uuid;
  v_version := p_request->>'version';
  v_source := p_request->'source';
  v_reason := p_request#>>'{audit,reason}';

  v_validation := private.result_process_content_validate_v1(
    p_request->>'contentText', v_id, v_version
  );
  if not (v_validation->>'ok')::boolean then
    return v_validation;
  end if;

  v_content_sha := private.result_process_content_sha256_v1(p_request->>'contentText');
  if v_content_sha <> p_request->>'contentSha256' then
    return jsonb_build_object('ok', false, 'code', 'result_content_hash_mismatch',
      'status', 400,
      'message', 'contentSha256 does not match the submitted content bytes');
  end if;

  select classified.classification, classified.state_code, classified.stored_sha256
  into v_classification, v_state, v_stored
  from private.result_process_publish_classify_v1(v_id, v_version, v_content_sha)
    as classified;

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'schemaVersion', 'result-process.publish-prepare.v1',
      'preparationHash', private.result_process_preparation_hash_v1(
        v_actor, v_id, v_version, v_content_sha, v_source, v_reason,
        v_classification, v_state
      ),
      'actorUserId', v_actor,
      'id', v_id,
      'version', v_version,
      'contentSha256', v_content_sha,
      'hashDomain', 'result-process-content.v1',
      'sourceKind', 'manager_attestation',
      'classification', v_classification,
      'existingState', v_state
    )
  );
end;
$$;

ALTER FUNCTION "api"."qry_result_process_publish_prepare_v1"("p_request" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_result_process_publish_prepare_v1"("p_request" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_result_process_publish_prepare_v1"("p_request" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."qry_result_process_publish_prepare_v1"("p_request" "jsonb") TO "authenticated";
