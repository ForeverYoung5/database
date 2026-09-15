CREATE OR REPLACE FUNCTION "api"."qry_result_process_publication_readback_v1"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_allowed constant text[] := array['id', 'version', 'idempotencyKey'];
  v_version_char character(9);
  v_key text;
  v_id uuid;
  v_version text;
  v_idem text;
  v_receipt private.result_process_publications%rowtype;
  v_state integer;
  v_stored text;
  v_live_sha text;
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'auth_required', 'status', 401,
      'message', 'Authentication required');
  end if;
  if not private.lca_release_is_manager() then
    return jsonb_build_object('ok', false, 'code', 'not_data_product_manager',
      'status', 403, 'message', 'Data product manager role is required');
  end if;

  if jsonb_typeof(p_request) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'Request must be a JSON object');
  end if;
  for v_key in select jsonb_object_keys(p_request) loop
    if not (v_key = any(v_allowed)) then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400, 'message', 'Unknown request field: ' || v_key);
    end if;
  end loop;

  -- Same exact scalar constraints as prepare and execute, so a malformed identity returns
  -- the promised envelope rather than a raw 22P02 from the uuid cast.
  if jsonb_typeof(p_request -> 'id') is distinct from 'string'
     or (p_request ->> 'id') !~
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'id must be a lowercase UUID string');
  end if;
  if jsonb_typeof(p_request -> 'version') is distinct from 'string'
     or (p_request ->> 'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'version must be a NN.NN.NNN string');
  end if;
  if jsonb_typeof(p_request -> 'idempotencyKey') is distinct from 'string'
     or length(p_request ->> 'idempotencyKey') not between 1 and 200
     or (p_request ->> 'idempotencyKey') <> btrim(p_request ->> 'idempotencyKey') then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400,
      'message', 'idempotencyKey must be 1..200 characters with no surrounding whitespace');
  end if;

  v_id := (p_request->>'id')::uuid;
  v_version := p_request->>'version';
  v_version_char := v_version::character(9);
  v_idem := p_request->>'idempotencyKey';

  select * into v_receipt
  from private.result_process_publications as receipt
  where receipt.actor_user_id = v_actor
    and receipt.dataset_id = v_id
    and receipt.dataset_version = v_version
    and receipt.idempotency_key = v_idem;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'result_publication_not_found',
      'status', 404, 'message', 'No publication attestation matches this exact binding');
  end if;

  select process_row.state_code, process_row.json_ordered::text
  into v_state, v_stored
  from public.processes as process_row
  where process_row.id = v_id
    and process_row.version = v_version_char;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'result_publication_not_found',
      'status', 404, 'message', 'The attested row no longer exists');
  end if;

  v_live_sha := private.result_process_content_sha256_v1(v_stored);

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'receipt', private.result_process_receipt_json_v1(v_receipt),
      'row', jsonb_build_object(
        'stateCode', v_state,
        'contentSha256', v_live_sha,
        'contentText', v_stored
      ),
      'verified', jsonb_build_object(
        'rowMatchesReceipt', (v_live_sha = v_receipt.content_sha256 and v_state = 120),
        'receiptMatchesRequest', (v_receipt.idempotency_key = v_idem),
        'liveManager', true
      )
    )
  );
end;
$_$;

ALTER FUNCTION "api"."qry_result_process_publication_readback_v1"("p_request" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."qry_result_process_publication_readback_v1"("p_request" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."qry_result_process_publication_readback_v1"("p_request" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."qry_result_process_publication_readback_v1"("p_request" "jsonb") TO "authenticated";
