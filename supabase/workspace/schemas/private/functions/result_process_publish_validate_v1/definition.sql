CREATE OR REPLACE FUNCTION "private"."result_process_publish_validate_v1"("p_request" "jsonb", "p_phase" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
declare
  v_hex constant text := '^[0-9a-f]{64}$';
  v_common constant text[] := array[
    'table', 'id', 'version', 'contentText', 'contentSha256', 'sourceKind', 'source', 'audit'
  ];
  v_prepare_source constant text[] := array['candidateSetHash', 'sourceManifestHash'];
  v_execute_source constant text[] := array[
    'candidateSetHash', 'sourceManifestHash', 'executablePlanHash', 'approvalHash'
  ];
  v_prepare_only constant text[] := array[]::text[];
  v_execute_only constant text[] := array['expectedPreparationHash', 'idempotencyKey'];
  v_allowed text[];
  v_source_allowed text[];
  v_key text;
  v_reason text;
  v_key_value text;
begin
  if p_phase not in ('prepare', 'execute') then
    raise exception using errcode = '22023', message = 'invalid publication phase';
  end if;

  if jsonb_typeof(p_request) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'Request must be a JSON object');
  end if;

  v_allowed := case when p_phase = 'prepare'
    then v_common || v_prepare_only
    else v_common || v_execute_only end;
  v_source_allowed := case when p_phase = 'prepare'
    then v_prepare_source else v_execute_source end;

  for v_key in select jsonb_object_keys(p_request) loop
    if not (v_key = any(v_allowed)) then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400,
        'message', 'Field not allowed in ' || p_phase || ': ' || v_key);
    end if;
  end loop;

  -- Server-derived authority fields are rejected outright.
  if p_request ? 'role' or p_request ? 'targetState'
     or p_request ? 'actorUserId' or p_request ? 'stateCode' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400,
      'message', 'role, targetState, stateCode and actorUserId are server-derived');
  end if;

  -- source is required in both phases, and its members are phase-specific.
  if jsonb_typeof(p_request -> 'source') is distinct from 'object' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'source is required and must be an object');
  end if;
  for v_key in select jsonb_object_keys(p_request -> 'source') loop
    if not (v_key = any(v_source_allowed)) then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400,
        'message', 'Source field not allowed in ' || p_phase || ': ' || v_key);
    end if;
  end loop;
  foreach v_key in array v_source_allowed loop
    if jsonb_typeof(p_request -> 'source' -> v_key) is distinct from 'string'
       or (p_request -> 'source' ->> v_key) !~ v_hex then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400,
        'message', 'source.' || v_key || ' must be a lowercase SHA-256 hex string');
    end if;
  end loop;

  if jsonb_typeof(p_request -> 'audit') is distinct from 'object'
     or jsonb_typeof(p_request -> 'audit' -> 'reason') is distinct from 'string' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'audit.reason is required and must be a string');
  end if;
  for v_key in select jsonb_object_keys(p_request -> 'audit') loop
    if v_key <> 'reason' then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400, 'message', 'Unknown audit field: ' || v_key);
    end if;
  end loop;
  v_reason := p_request -> 'audit' ->> 'reason';
  if length(v_reason) not between 1 and 1000
     or octet_length(v_reason) > 4000
     or v_reason ~ '[[:cntrl:]]' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'audit.reason must be 1..1000 printable characters');
  end if;

  if jsonb_typeof(p_request -> 'table') is distinct from 'string'
     or p_request ->> 'table' <> 'processes' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'table must be the string processes');
  end if;
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
  if jsonb_typeof(p_request -> 'sourceKind') is distinct from 'string'
     or p_request ->> 'sourceKind' <> 'manager_attestation' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'sourceKind must be the string manager_attestation');
  end if;
  if jsonb_typeof(p_request -> 'contentSha256') is distinct from 'string'
     or (p_request ->> 'contentSha256') !~ v_hex then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'contentSha256 must be a lowercase SHA-256 hex string');
  end if;
  if jsonb_typeof(p_request -> 'contentText') is distinct from 'string' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'contentText must be a string containing the JSON document');
  end if;
  if octet_length(p_request ->> 'contentText') not between 2 and 1048576 then
    return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
      'status', 400, 'message', 'contentText must be between 2 bytes and 1 MiB');
  end if;

  if p_phase = 'execute' then
    if jsonb_typeof(p_request -> 'expectedPreparationHash') is distinct from 'string'
       or (p_request ->> 'expectedPreparationHash') !~ v_hex then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400,
        'message', 'expectedPreparationHash must be a lowercase SHA-256 hex string');
    end if;
    if jsonb_typeof(p_request -> 'idempotencyKey') is distinct from 'string' then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400, 'message', 'idempotencyKey must be a string');
    end if;
    v_key_value := p_request ->> 'idempotencyKey';
    if length(v_key_value) not between 1 and 200
       or v_key_value <> btrim(v_key_value) then
      return jsonb_build_object('ok', false, 'code', 'result_publish_request_invalid',
        'status', 400,
        'message', 'idempotencyKey must be 1..200 characters with no surrounding whitespace');
    end if;
  end if;

  return jsonb_build_object('ok', true);
end;
$_$;

ALTER FUNCTION "private"."result_process_publish_validate_v1"("p_request" "jsonb", "p_phase" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_process_publish_validate_v1"("p_request" "jsonb", "p_phase" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."result_process_publish_validate_v1"("p_request" "jsonb", "p_phase" "text") TO "api_internal_executor";
