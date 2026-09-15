CREATE OR REPLACE FUNCTION "api"."cmd_result_process_publish_v1"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid := auth.uid();
  v_check jsonb;
  v_id uuid;
  v_version text;
  v_version_char character(9);
  v_source jsonb;
  v_reason text;
  v_key text;
  v_expected_prep text;
  v_content_sha text;
  v_validation jsonb;
  v_existing private.result_process_publications%rowtype;
  v_other private.result_process_publications%rowtype;
  v_binding jsonb;
  v_classification text;
  v_state integer;
  v_stored text;
  v_prep text;
  v_receipt jsonb;
  v_receipt_id uuid;
  v_published_at timestamptz;
  v_rows integer;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'auth_required', 'status', 401,
      'message', 'Authentication required');
  end if;
  if not private.lca_release_is_manager() then
    return jsonb_build_object('ok', false, 'code', 'not_data_product_manager',
      'status', 403, 'message', 'Data product manager role is required');
  end if;

  v_check := private.result_process_publish_validate_v1(p_request, 'execute');
  if not (v_check->>'ok')::boolean then
    return v_check;
  end if;

  v_id := (p_request->>'id')::uuid;
  v_version := p_request->>'version';
  v_version_char := v_version::character(9);
  v_source := p_request->'source';
  v_reason := p_request#>>'{audit,reason}';
  v_key := p_request->>'idempotencyKey';
  v_expected_prep := p_request->>'expectedPreparationHash';

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

  -- Fixed lock order: identity namespace first, then idempotency-key namespace.
  perform pg_advisory_xact_lock(6461201, hashtext(v_id::text || ':' || v_version));
  perform pg_advisory_xact_lock(6461202, hashtext(v_actor::text || ':' || v_key));

  -- Step 5a: resolve this actor's key FIRST, regardless of identity. A key already bound to
  -- a different identity is a replay mismatch and must be rejected before any insert, so no
  -- row can be created and then abandoned.
  select * into v_other
  from private.result_process_publications as receipt
  where receipt.actor_user_id = v_actor
    and receipt.idempotency_key = v_key;

  if v_other.id is not null
     and (v_other.dataset_id is distinct from v_id
          or v_other.dataset_version is distinct from v_version) then
    return jsonb_build_object('ok', false, 'code', 'result_publication_replay_mismatch',
      'status', 409,
      'message', 'This idempotency key is already bound to a different Result identity');
  end if;

  -- Step 5b: exact-binding retry. The precondition legitimately changed from absent to 120,
  -- so the preparation is NOT recomputed here; the recorded binding is compared instead.
  if v_other.id is not null then
    v_binding := jsonb_build_object(
      'id', v_id, 'version', v_version, 'contentSha256', v_content_sha,
      'candidateSetHash', v_source->>'candidateSetHash',
      'sourceManifestHash', v_source->>'sourceManifestHash',
      'executablePlanHash', v_source->>'executablePlanHash',
      'approvalHash', v_source->>'approvalHash',
      'reason', v_reason, 'expectedPreparationHash', v_expected_prep
    );
    if v_other.content_sha256 = v_content_sha
       and v_other.request_binding = v_binding then
      select process_row.state_code, process_row.json_ordered::text
      into v_state, v_stored
      from public.processes as process_row
      where process_row.id = v_id
        and process_row.version = v_version_char;
      if v_state is distinct from 120
         or private.result_process_content_sha256_v1(v_stored) <> v_content_sha then
        return jsonb_build_object('ok', false, 'code', 'result_publication_conflict',
          'status', 409, 'message', 'The published row no longer matches its attestation');
      end if;
      return jsonb_build_object('ok', true, 'reused', true,
        'data', private.result_process_receipt_json_v1(v_other));
    end if;
    return jsonb_build_object('ok', false, 'code', 'result_publication_replay_mismatch',
      'status', 409,
      'message', 'This idempotency key is already bound to a different publication binding');
  end if;

  -- Step 6: no receipt for this key. Classify the row before recomputing the preparation,
  -- so a row that already exists is reported as a conflict (the specific and useful
  -- diagnosis) rather than as a stale preparation. A different idempotency key against an
  -- existing identity therefore conflicts, exactly as the contract requires.
  select classified.classification, classified.state_code, classified.stored_sha256
  into v_classification, v_state, v_stored
  from private.result_process_publish_classify_v1(v_id, v_version, v_content_sha)
    as classified;

  if v_classification <> 'absent' then
    return jsonb_build_object('ok', false, 'code', 'result_publication_conflict',
      'status', 409, 'message', 'A row already exists for this identity',
      'details', jsonb_build_object('stateCode', v_state));
  end if;

  v_prep := private.result_process_preparation_hash_v1(
    v_actor, v_id, v_version, v_content_sha, v_source, v_reason, v_classification, v_state
  );
  if v_prep <> v_expected_prep then
    return jsonb_build_object('ok', false, 'code', 'result_preparation_stale',
      'status', 409,
      'message', 'expectedPreparationHash does not match the current preparation');
  end if;

  -- Absent: insert directly at 120. Never 0, never 100.
  begin
    insert into public.processes (id, version, json_ordered, user_id, state_code)
    values (v_id, v_version_char, (p_request->>'contentText')::json, v_actor, 120);
  exception
    when unique_violation then
      return jsonb_build_object('ok', false, 'code', 'result_publication_conflict',
        'status', 409, 'message', 'The identity was created concurrently');
    when lock_not_available then
      -- Narrow, retryable case. The governed row fence
      -- private.dataset_flow_identity_active_fence takes a NON-BLOCKING actor lock on
      -- 'dataset-flow-identity-actor:<user_id>' and raises SQLSTATE 55P03 with this exact
      -- message when another transaction currently holds it. That is contention on the
      -- actor's own row domain, not a defect and not an authorization result, and the
      -- promise of this command is a typed JSON envelope, so it is reported as retryable.
      --
      -- The match is deliberately exact and narrow: the insert subtransaction has already
      -- rolled back here (so no Process row survives), nothing is written to the receipt or
      -- audit, and EVERY other 55P03 or unexpected failure re-raises unchanged. The
      -- underlying fence is not altered, relaxed or bypassed, and no retry loop is started:
      -- the caller decides whether to re-issue the same frozen request.
      -- Exact equality against the known message. No trimming, no prefix/pattern match: a
      -- message that merely resembles the fence signal must not be converted.
      if sqlerrm = 'FLOW_IDENTITY_ACTIVE_SCOPE_ACTOR_FENCE_BUSY' then
        return jsonb_build_object(
          'ok', false,
          'code', 'result_publication_busy',
          'status', 409,
          'message',
            'Another transaction is modifying this actor''s dataset rows. Retry the same request.'
        );
      end if;
      raise;
  end;

  v_binding := jsonb_build_object(
    'id', v_id, 'version', v_version, 'contentSha256', v_content_sha,
    'candidateSetHash', v_source->>'candidateSetHash',
    'sourceManifestHash', v_source->>'sourceManifestHash',
    'executablePlanHash', v_source->>'executablePlanHash',
    'approvalHash', v_source->>'approvalHash',
    'reason', v_reason, 'expectedPreparationHash', v_expected_prep
  );

  -- Receipt, attestation audit and the row commit together. Any failure here RAISES so the
  -- whole transaction rolls back: a returned error must never leave an orphan Process row.
  insert into private.result_process_publications (
    actor_user_id, dataset_id, dataset_version, state_code, role, target_state,
    content_sha256, hash_domain, source_kind, candidate_set_hash, source_manifest_hash,
    executable_plan_hash, approval_hash, preparation_hash, idempotency_key, reason,
    request_binding
  ) values (
    v_actor, v_id, v_version, 120, 'result_process', 120,
    v_content_sha, 'result-process-content.v1', 'manager_attestation',
    v_source->>'candidateSetHash', v_source->>'sourceManifestHash',
    v_source->>'executablePlanHash', v_source->>'approvalHash',
    v_prep, v_key, v_reason, v_binding
  )
  returning id, published_at into v_receipt_id, v_published_at;

  insert into private.command_audit_log (
    command, actor_user_id, target_table, target_id, target_version, payload
  ) values (
    'cmd_result_process_publish_v1', v_actor, 'processes', v_id, v_version,
    jsonb_build_object(
      'reason', v_reason,
      'receiptId', v_receipt_id,
      'role', 'result_process',
      'targetState', 120,
      'contentSha256', v_content_sha,
      'hashDomain', 'result-process-content.v1',
      'sourceKind', 'manager_attestation',
      'preparationHash', v_prep,
      'candidateSetHash', v_source->>'candidateSetHash',
      'sourceManifestHash', v_source->>'sourceManifestHash',
      'executablePlanHash', v_source->>'executablePlanHash',
      'approvalHash', v_source->>'approvalHash'
    )
  );

  select * into v_existing
  from private.result_process_publications as receipt
  where receipt.id = v_receipt_id;

  return jsonb_build_object('ok', true, 'reused', false,
    'data', private.result_process_receipt_json_v1(v_existing));
exception
  when others then
    -- Any unexpected failure after the row insert propagates: the transaction rolls back
    -- the row, the receipt and the audit together. Never a partial commit or false success.
    raise;
end;
$$;

ALTER FUNCTION "api"."cmd_result_process_publish_v1"("p_request" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_result_process_publish_v1"("p_request" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_result_process_publish_v1"("p_request" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."cmd_result_process_publish_v1"("p_request" "jsonb") TO "authenticated";
