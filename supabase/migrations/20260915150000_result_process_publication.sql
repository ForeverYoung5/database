-- Database #646 / workspace #1201: manager-attested Result Process publication.
--
-- Implements docs/agents/result-process-publication-contract.md. The recorded truth is
-- manager_attestation: an authorized attestation, NOT verified calculation lineage.
-- Supplied candidate/source/plan/approval hashes are bound and attested; the server does
-- not validate an upstream approval artifact.
--
-- Scope: three api-schema RPCs callable with an actor JWT, one private append-only receipt
-- table, and the exact-signature capability classification. No public Result API, no
-- generic read widening, no Portal change, no new role, no Result 100 migration, and no
-- trigger is disabled anywhere in this migration.

BEGIN;

-- 1) Immutable attestation receipt.
--
-- One authoritative attestation per identity, and one per (actor, idempotency key) so a
-- lost-response retry resolves to the same record. There is deliberately no unique
-- constraint on (actor, plan hash): one release plan covers multiple Results.
create table if not exists private.result_process_publications (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null,
  dataset_id uuid not null,
  dataset_version text not null,
  state_code integer not null,
  role text not null,
  target_state integer not null,
  content_sha256 text not null,
  hash_domain text not null,
  source_kind text not null,
  candidate_set_hash text not null,
  source_manifest_hash text not null,
  executable_plan_hash text not null,
  approval_hash text not null,
  preparation_hash text not null,
  idempotency_key text not null,
  reason text not null,
  request_binding jsonb not null,
  published_at timestamptz not null default now(),
  constraint result_process_publications_role_chk check (role = 'result_process'),
  constraint result_process_publications_target_chk check (target_state = 120),
  constraint result_process_publications_state_chk check (state_code = 120),
  constraint result_process_publications_domain_chk
    check (hash_domain = 'result-process-content.v1'),
  constraint result_process_publications_source_kind_chk
    check (source_kind = 'manager_attestation'),
  constraint result_process_publications_version_chk
    check (dataset_version ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'),
  constraint result_process_publications_content_hash_chk
    check (content_sha256 ~ '^[0-9a-f]{64}$'),
  constraint result_process_publications_preparation_hash_chk
    check (preparation_hash ~ '^[0-9a-f]{64}$'),
  constraint result_process_publications_candidate_hash_chk
    check (candidate_set_hash ~ '^[0-9a-f]{64}$'),
  constraint result_process_publications_manifest_hash_chk
    check (source_manifest_hash ~ '^[0-9a-f]{64}$'),
  constraint result_process_publications_plan_hash_chk
    check (executable_plan_hash ~ '^[0-9a-f]{64}$'),
  constraint result_process_publications_approval_hash_chk
    check (approval_hash ~ '^[0-9a-f]{64}$'),
  constraint result_process_publications_key_chk
    check (length(idempotency_key) between 1 and 200),
  constraint result_process_publications_reason_chk
    check (length(reason) between 1 and 1000),
  constraint result_process_publications_binding_chk
    check (jsonb_typeof(request_binding) = 'object')
);

alter table private.result_process_publications owner to postgres;

create unique index if not exists result_process_publications_identity_uidx
  on private.result_process_publications (dataset_id, dataset_version);
create unique index if not exists result_process_publications_key_uidx
  on private.result_process_publications (actor_user_id, idempotency_key);

-- Append-only. Rewriting a conflicting publication requires a new explicitly authorized
-- identity/version instead.
create or replace function private.result_process_publications_immutable_v1()
returns trigger
language plpgsql
set search_path = ''
as $guard$
begin
  raise exception using
    errcode = '55000',
    message = 'RESULT_PROCESS_ATTESTATION_IMMUTABLE',
    detail = 'A Result Process publication attestation is append-only.';
end;
$guard$;

alter function private.result_process_publications_immutable_v1() owner to postgres;
revoke all on function private.result_process_publications_immutable_v1()
  from public, anon, authenticated, service_role;

drop trigger if exists result_process_publications_immutable on private.result_process_publications;
create trigger result_process_publications_immutable
  before update or delete on private.result_process_publications
  for each row execute function private.result_process_publications_immutable_v1();

-- Minimal ACL: no browser role and no service write grant.
revoke all on private.result_process_publications
  from public, anon, authenticated, service_role;
grant select on private.result_process_publications to api_internal_executor;

-- 2) Strict request validation.
--
-- Every field is type-checked with jsonb_typeof using IS DISTINCT FROM, so a JSON number,
-- boolean, array or object can never be coerced into a text field by ->>. Unknown fields
-- are rejected at every level, and phase separation is enforced: prepare may not carry
-- execute-only fields, and the plan/approval hashes belong to execute only, so they can
-- never enter a preparation digest.
create or replace function private.result_process_publish_validate_v1(
  p_request jsonb,
  p_phase text
) returns jsonb
language plpgsql
immutable
set search_path = ''
as $fn$
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
$fn$;

alter function private.result_process_publish_validate_v1(jsonb, text) owner to postgres;
revoke all on function private.result_process_publish_validate_v1(jsonb, text)
  from public, anon, authenticated, service_role;
grant all on function private.result_process_publish_validate_v1(jsonb, text)
  to api_internal_executor;

-- 3) Content and preparation helpers.
--
-- The content hash domain is result-process-content.v1: SHA-256 over the UTF-8 bytes of the
-- exact submitted text, which is also the exact stored json_ordered byte sequence.
create or replace function private.result_process_content_sha256_v1(p_text text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select encode(extensions.digest(convert_to(p_text, 'UTF8'), 'sha256'), 'hex')
$fn$;

alter function private.result_process_content_sha256_v1(text) owner to postgres;
revoke all on function private.result_process_content_sha256_v1(text)
  from public, anon, authenticated, service_role;
grant all on function private.result_process_content_sha256_v1(text) to api_internal_executor;

-- Process envelope validation.
--
-- Duplicate keys are rejected RECURSIVELY by the SQL/JSON predicate
-- `IS JSON OBJECT WITH UNIQUE KEYS`, which descends into nested objects and into objects
-- inside arrays. This is stronger than comparing key counts, and it also rejects a
-- non-object root. Duplicates matter because `json` preserves them while `jsonb` silently
-- collapses them, so the stored bytes and any derived jsonb reading would disagree.
create or replace function private.result_process_content_validate_v1(
  p_text text,
  p_id uuid,
  p_version text
) returns jsonb
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  v_document json;
  v_root_uuid text;
  v_root_version text;
begin
  begin
    v_document := p_text::json;
  exception when others then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message', 'contentText is not valid JSON');
  end;

  if not (v_document IS JSON OBJECT WITH UNIQUE KEYS) then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message',
      'contentText must be a JSON object with no duplicate keys at any level');
  end if;

  if json_typeof(v_document -> 'processDataSet') is distinct from 'object' then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message', 'contentText must contain processDataSet');
  end if;

  v_root_uuid := v_document #>>
    '{processDataSet,processInformation,dataSetInformation,common:UUID}';
  v_root_version := v_document #>>
    '{processDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}';

  if json_typeof(v_document #> '{processDataSet,processInformation,dataSetInformation}') is distinct from 'object'
     or json_typeof(v_document #> '{processDataSet,processInformation,dataSetInformation,common:UUID}') is distinct from 'string'
     or lower(v_root_uuid) <> p_id::text then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message', 'processDataSet common:UUID must be a string equal to id');
  end if;

  if json_typeof(v_document #> '{processDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}') is distinct from 'string'
     or v_root_version <> p_version then
    return jsonb_build_object('ok', false, 'code', 'result_publish_content_invalid',
      'status', 400, 'message',
      'publicationAndOwnership common:dataSetVersion must be a string equal to version');
  end if;

  return jsonb_build_object('ok', true, 'document', v_document);
end;
$fn$;

alter function private.result_process_content_validate_v1(text, uuid, text) owner to postgres;
revoke all on function private.result_process_content_validate_v1(text, uuid, text)
  from public, anon, authenticated, service_role;
grant all on function private.result_process_content_validate_v1(text, uuid, text)
  to api_internal_executor;

-- Precondition classifier, shared by prepare and execute so a preparation digest produced
-- by prepare is reproducible by execute. Existence is decided by FOUND, not by a null
-- state_code, so a row that exists with a NULL state is a conflict rather than absent.
create or replace function private.result_process_publish_classify_v1(
  p_id uuid,
  p_version text,
  p_content_sha256 text,
  out classification text,
  out state_code integer,
  out stored_sha256 text
)
returns record
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_stored text;
begin
  select process_row.state_code, process_row.json_ordered::text
  into state_code, v_stored
  from public.processes as process_row
  where process_row.id = p_id
    and btrim(process_row.version::text) = p_version;

  if not found then
    classification := 'absent';
    state_code := null;
    stored_sha256 := null;
    return;
  end if;

  stored_sha256 := private.result_process_content_sha256_v1(v_stored);

  if state_code = 120 and stored_sha256 = p_content_sha256 then
    -- Strictly content candidacy. It is not authorization, not actor/source matching, and
    -- not a no-op: execute still resolves the exact receipt before anything else.
    classification := 'candidate_content_matches_existing';
  else
    classification := 'conflict';
  end if;
end;
$fn$;

alter function private.result_process_publish_classify_v1(uuid, text, text) owner to postgres;
revoke all on function private.result_process_publish_classify_v1(uuid, text, text)
  from public, anon, authenticated, service_role;
grant all on function private.result_process_publish_classify_v1(uuid, text, text)
  to api_internal_executor;

-- Preparation digest domain result-process-preparation.v1.
--
-- It hashes the phase-independent source projection only (candidate + manifest). The plan
-- and approval hashes belong to execute and are bound separately in the receipt, so prepare
-- and execute always hash the same projection and a legitimate retry is never stale.
create or replace function private.result_process_preparation_hash_v1(
  p_actor uuid,
  p_id uuid,
  p_version text,
  p_content_sha256 text,
  p_source jsonb,
  p_reason text,
  p_classification text,
  p_state integer
) returns text
language sql
immutable
set search_path = ''
as $fn$
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
$fn$;

alter function private.result_process_preparation_hash_v1(
  uuid, uuid, text, text, jsonb, text, text, integer
) owner to postgres;
revoke all on function private.result_process_preparation_hash_v1(
  uuid, uuid, text, text, jsonb, text, text, integer
) from public, anon, authenticated, service_role;
grant all on function private.result_process_preparation_hash_v1(
  uuid, uuid, text, text, jsonb, text, text, integer
) to api_internal_executor;

-- Receipt projection, shared by execute and readback so the returned shape is identical.
create or replace function private.result_process_receipt_json_v1(
  p_receipt private.result_process_publications
) returns jsonb
language sql
immutable
set search_path = ''
as $fn$
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
$fn$;

alter function private.result_process_receipt_json_v1(
  private.result_process_publications
) owner to postgres;
revoke all on function private.result_process_receipt_json_v1(
  private.result_process_publications
) from public, anon, authenticated, service_role;
grant all on function private.result_process_receipt_json_v1(
  private.result_process_publications
) to api_internal_executor;

-- 4) Prepare: read-only classification and deterministic preparation digest.
create or replace function api.qry_result_process_publish_prepare_v1(p_request jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
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
$fn$;

alter function api.qry_result_process_publish_prepare_v1(jsonb) owner to postgres;
revoke all on function api.qry_result_process_publish_prepare_v1(jsonb) from public;
grant all on function api.qry_result_process_publish_prepare_v1(jsonb) to api_internal_executor;
grant all on function api.qry_result_process_publish_prepare_v1(jsonb) to authenticated;

-- 5) Execute: atomic manager-attested publication.
--
-- Locks use the validated two-integer form pg_advisory_xact_lock(integer, integer) with
-- hashtext, in a fixed order across two separate namespaces: identity (6461201) then
-- idempotency key (6461202). Separate namespaces mean a key hash that equals an identity
-- hash can never be confused with it, and every caller acquires in the same order.
create or replace function api.cmd_result_process_publish_v1(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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
$fn$;

alter function api.cmd_result_process_publish_v1(jsonb) owner to postgres;
revoke all on function api.cmd_result_process_publish_v1(jsonb) from public;
grant all on function api.cmd_result_process_publish_v1(jsonb) to api_internal_executor;
grant all on function api.cmd_result_process_publish_v1(jsonb) to authenticated;

-- 6) Readback: exact receipt binding only.
--
-- Returns the exact stored content so Release can verify canonical content and receipt
-- independently, without any generic read (blocked for 120 by the isolation slice). It
-- never performs an arbitrary row lookup, never lists, and never exposes a public surface.
create or replace function api.qry_result_process_publication_readback_v1(p_request jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
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
$fn$;

alter function api.qry_result_process_publication_readback_v1(jsonb) owner to postgres;
revoke all on function api.qry_result_process_publication_readback_v1(jsonb) from public;
grant all on function api.qry_result_process_publication_readback_v1(jsonb) to api_internal_executor;
grant all on function api.qry_result_process_publication_readback_v1(jsonb) to authenticated;

-- 7) Capability classification. Every api routine needs an exact-signature manifest entry or
-- the PostgREST pre-request gate denies it with 42501. These are actor-bound RPCs, so they
-- use the existing CLI transport capability and admit authenticated callers only.
insert into private.api_capability_grants (
  routine_identity, capability_id, allow_anon, allow_authenticated, allow_service_role
) values
  ('api.qry_result_process_publish_prepare_v1(jsonb)', 'CLI-RPC-01', false, true, false),
  ('api.cmd_result_process_publish_v1(jsonb)', 'CLI-RPC-01', false, true, false),
  ('api.qry_result_process_publication_readback_v1(jsonb)', 'CLI-RPC-01', false, true, false)
on conflict (routine_identity) do update set
  capability_id = excluded.capability_id,
  allow_anon = excluded.allow_anon,
  allow_authenticated = excluded.allow_authenticated,
  allow_service_role = excluded.allow_service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
