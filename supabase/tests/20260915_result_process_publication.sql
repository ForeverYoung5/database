-- Database #646 / workspace #1201: manager-attested Result Process publication.
--
-- Rollback-only. Exercises the real RPC entry points, not source text: happy path, every
-- negative class, revocation, full-semantic retry, raw 120 without a receipt, legacy 100,
-- cache exclusion, lifecycle interaction and the ACL surface.
--
-- Concurrency is NOT proven here. A single session cannot demonstrate two first writers,
-- lost responses or non-cooperating uniqueness races; those live in the companion
-- two-client harness under supabase/tests/regression/. This suite asserts only what one
-- session can honestly establish.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

-- Outbound extraction webhooks need Vault secrets a disposable database does not have.
-- Only that egress call is redirected; no guard, trigger or policy is disabled.
create temporary table publication_webhook_calls (
  edge_function text not null,
  body jsonb not null,
  timeout_milliseconds integer not null
) on commit drop;

create or replace function util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds integer default ((5 * 60) * 1000)
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into pg_temp.publication_webhook_calls(
    edge_function, body, timeout_milliseconds
  ) values (name, body, timeout_milliseconds);
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
) values
  ('00000000-0000-0000-0000-000000000000','64a00000-0000-4000-8000-000000000001',
   'authenticated','authenticated','pub-manager@example.invalid','x',now(),'{}','{}',now(),now(),false,false),
  ('00000000-0000-0000-0000-000000000000','64a00000-0000-4000-8000-000000000002',
   'authenticated','authenticated','pub-owner@example.invalid','x',now(),'{}','{}',now(),now(),false,false),
  ('00000000-0000-0000-0000-000000000000','64a00000-0000-4000-8000-000000000003',
   'authenticated','authenticated','pub-revocable@example.invalid','x',now(),'{}','{}',now(),now(),false,false);
insert into private.users(id, raw_user_meta_data, contact) values
  ('64a00000-0000-4000-8000-000000000001','{}',null),
  ('64a00000-0000-4000-8000-000000000002','{}',null),
  ('64a00000-0000-4000-8000-000000000003','{}',null);
insert into private.teams(id, json, rank, is_public)
values ('00000000-0000-0000-0000-000000000000','{"name":"System"}',0,false)
on conflict (id) do nothing;
-- 001 is the standing manager. 002 is an ordinary owner with no platform role. 003 is a
-- second manager used only for the revocation case. No role is invented.
insert into private.roles(user_id, team_id, role) values
  ('64a00000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','data_product_manager'),
  ('64a00000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','data_product_manager');

-- Request builders. mkreq always computes the preparation with the prepare-phase source
-- projection, then adds the execute-only plan and approval hashes plus the idempotency key,
-- exactly as the contract requires. A helper error aborts the suite rather than hiding.
create or replace function pg_temp.mkcontent(p_uuid text, p_version text)
returns text language sql immutable as $$
  select '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"'
    || p_uuid || '"}},"administrativeInformation":{"publicationAndOwnership":'
    || '{"common:dataSetVersion":"' || p_version || '"}}}}'
$$;

create or replace function pg_temp.mkcontent_dup_nested(p_uuid text, p_version text)
returns text language sql immutable as $$
  select '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"'
    || p_uuid || '"},"nested":{"a":1,"a":2}},"administrativeInformation":'
    || '{"publicationAndOwnership":{"common:dataSetVersion":"' || p_version || '"}}}}'
$$;

create or replace function pg_temp.mkcontent_dup_root(p_uuid text, p_version text)
returns text language sql immutable as $$
  select '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"'
    || p_uuid || '","common:UUID":"' || p_uuid || '"}},"administrativeInformation":'
    || '{"publicationAndOwnership":{"common:dataSetVersion":"' || p_version || '"}}}}'
$$;

-- Prepare-phase request: the common fields plus the prepare-phase source projection only.
-- Execute-only fields and the plan/approval hashes are deliberately absent, because prepare
-- rejects them and must never hash them.
create or replace function pg_temp.mkprepare(
  p_uuid text, p_version text, p_reason text default 'publication test'
) returns jsonb language plpgsql as $$
declare
  v_text text := pg_temp.mkcontent(p_uuid, p_version);
begin
  return jsonb_build_object(
    'table','processes','id',p_uuid,'version',p_version,
    'contentText',v_text,
    'contentSha256',encode(extensions.digest(convert_to(v_text,'UTF8'),'sha256'),'hex'),
    'sourceKind','manager_attestation',
    'source',jsonb_build_object(
      'candidateSetHash',repeat('a',64),
      'sourceManifestHash',repeat('b',64)),
    'audit',jsonb_build_object('reason',p_reason)
  );
end $$;

-- Execute-phase request: the prepare request plus the execute-only plan/approval hashes, the
-- idempotency key and the expected preparation hash taken from the real prepare response.
create or replace function pg_temp.mkreq(
  p_uuid text, p_version text, p_key text, p_reason text default 'publication test'
) returns jsonb language plpgsql as $$
declare
  v_prepare jsonb := pg_temp.mkprepare(p_uuid, p_version, p_reason);
  v_execute jsonb;
begin
  v_execute := jsonb_set(v_prepare,'{source}',(v_prepare->'source')||jsonb_build_object(
      'executablePlanHash',repeat('c',64),
      'approvalHash',repeat('d',64)));
  v_execute := jsonb_set(v_execute,'{idempotencyKey}',to_jsonb(p_key));
  return jsonb_set(v_execute,'{expectedPreparationHash}',to_jsonb(
    api.qry_result_process_publish_prepare_v1(v_prepare)#>>'{data,preparationHash}'));
end $$;

grant all on function pg_temp.mkprepare(text,text,text) to public;
grant all on function pg_temp.mkreq(text,text,text,text) to public;
grant all on function pg_temp.mkcontent(text,text) to public;
grant all on function pg_temp.mkcontent_dup_nested(text,text) to public;
grant all on function pg_temp.mkcontent_dup_root(text,text) to public;

-- Result identities used by this suite.
create temporary table pub_ids(label text primary key, id uuid not null) on commit drop;
insert into pub_ids values
  ('happy','64a00000-0000-4000-8000-000000000010'),
  ('retry','64a00000-0000-4000-8000-000000000011'),
  ('raw120','64a00000-0000-4000-8000-000000000012'),
  ('legacy100','64a00000-0000-4000-8000-000000000013'),
  ('rollback','64a00000-0000-4000-8000-000000000014'),
  ('revoke','64a00000-0000-4000-8000-000000000015'),
  ('other','64a00000-0000-4000-8000-000000000016');
grant select on pub_ids to public;

-- Pre-existing rows the publisher must never adopt: a raw Result with no receipt, and a
-- legacy published row at exactly 100.
insert into public.processes(id, version, state_code, user_id, json_ordered)
values
  ('64a00000-0000-4000-8000-000000000012','01.00.000',120,
   '64a00000-0000-4000-8000-000000000001',
   pg_temp.mkcontent('64a00000-0000-4000-8000-000000000012','01.00.000')::json),
  ('64a00000-0000-4000-8000-000000000013','01.00.000',100,
   '64a00000-0000-4000-8000-000000000001',
   pg_temp.mkcontent('64a00000-0000-4000-8000-000000000013','01.00.000')::json);

-- ------------------------------------------------------------- authorization surface

set local role anon;
select ok(
  not has_function_privilege('anon','api.qry_result_process_publish_prepare_v1(jsonb)','execute')
  and not has_function_privilege('anon','api.cmd_result_process_publish_v1(jsonb)','execute')
  and not has_function_privilege('anon','api.qry_result_process_publication_readback_v1(jsonb)','execute'),
  'anonymous callers cannot execute any publication entry point'
);
reset role;

select ok(
  not has_function_privilege('service_role','api.cmd_result_process_publish_v1(jsonb)','execute')
  and has_function_privilege('authenticated','api.cmd_result_process_publish_v1(jsonb)','execute'),
  'the publication command is actor-bound, not service-role bound'
);
select ok(
  not has_table_privilege('anon','private.result_process_publications','select')
  and not has_table_privilege('authenticated','private.result_process_publications','select')
  and not has_table_privilege('service_role','private.result_process_publications','insert')
  and not has_table_privilege('authenticated','private.result_process_publications','update'),
  'the attestation receipt has no browser read and no service write grant'
);
select ok(
  exists (
    select 1 from private.api_capability_grants
    where routine_identity = 'api.cmd_result_process_publish_v1(jsonb)'
      and capability_id = 'CLI-RPC-01'
      and allow_authenticated and not allow_anon and not allow_service_role
  )
  and exists (
    select 1 from private.api_capability_grants
    where routine_identity = 'api.qry_result_process_publish_prepare_v1(jsonb)'
  )
  and exists (
    select 1 from private.api_capability_grants
    where routine_identity = 'api.qry_result_process_publication_readback_v1(jsonb)'
  ),
  'all three exact signatures are classified in the capability manifest'
);

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','',true);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000010','01.00.000','anon-key')
  )->>'code',
  'auth_required',
  'a request with no actor identity is refused'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000002',true);
select is(
  api.cmd_result_process_publish_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000010','01.00.000','owner-key')
  )->>'code',
  'not_data_product_manager',
  'an ordinary owner cannot publish a Result'
);
reset role;

-- --------------------------------------------------------- happy path and readback

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000010','01.00.000')
  )#>>'{data,classification}',
  'absent',
  'prepare classifies an unpublished identity as absent'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000010','01.00.000')
  )#>>'{data,sourceKind}',
  'manager_attestation',
  'prepare reports the fixed server-side source kind'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000010','01.00.000')
  )#>>'{data,hashDomain}',
  'result-process-content.v1',
  'prepare reports the stored-byte content hash domain'
);

create temporary table happy_publish on commit drop as
select api.cmd_result_process_publish_v1(
  pg_temp.mkreq('64a00000-0000-4000-8000-000000000010','01.00.000','happy-key')
) as j;

select is((select j->>'ok' from happy_publish), 'true', 'a manager publishes a new Result');
select is((select j->>'reused' from happy_publish), 'false', 'the first publication is not a reuse');
select is((select j#>>'{data,stateCode}' from happy_publish), '120', 'the receipt records state 120');
select is((select j#>>'{data,role}' from happy_publish), 'result_process', 'the receipt records the Result role');
select is((select j#>>'{data,targetState}' from happy_publish), '120', 'the receipt records the server-fixed target');
select is((select j#>>'{data,actorUserId}' from happy_publish), '64a00000-0000-4000-8000-000000000001', 'the receipt binds the server-derived actor');
select is((select j#>>'{data,candidateSetHash}' from happy_publish), repeat('a',64), 'the receipt binds the attested candidate hash');
select is((select j#>>'{data,approvalHash}' from happy_publish), repeat('d',64), 'the receipt binds the attested approval hash');
select is(
  (select j#>>'{data,contentSha256}' from happy_publish),
  encode(extensions.digest(convert_to(
    pg_temp.mkcontent('64a00000-0000-4000-8000-000000000010','01.00.000'),'UTF8'),'sha256'),'hex'),
  'the receipt content hash is the stored-byte hash'
);

-- The remaining assertions are INTERNAL database facts, so they run as a privileged test
-- observer. Every user-facing API call above stayed under the authentic actor role; reading
-- the row directly as that actor would be hidden by the 120 isolation policy, which is
-- asserted as its own explicit expectation below rather than worked around.
reset role;

select is(
  (select state_code::text from public.processes where id='64a00000-0000-4000-8000-000000000010'),
  '120',
  'the row is created directly at 120 with no intermediate state'
);
select is(
  (select json_ordered::text from public.processes where id='64a00000-0000-4000-8000-000000000010'),
  pg_temp.mkcontent('64a00000-0000-4000-8000-000000000010','01.00.000'),
  'the stored json_ordered bytes are exactly the submitted bytes'
);
select is(
  (select count(*) from private.command_audit_log
   where command='cmd_result_process_publish_v1' and target_id='64a00000-0000-4000-8000-000000000010'),
  1::bigint,
  'exactly one attestation audit row is written'
);

-- The isolation policy is its own explicit expectation: the actor who just published the
-- Result still cannot read it back through the generic relation.
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);
select is(
  (select count(*) from public.processes where id='64a00000-0000-4000-8000-000000000010'),
  0::bigint,
  'a generic read by the publishing actor still cannot see the published Result'
);
-- Readback is a user-facing API call, so it stays under the authentic actor role. The
-- isolation assertion above proved the generic relation is hidden from that same actor,
-- which is exactly why this authorized readback path exists.
create temporary table happy_readback on commit drop as
select api.qry_result_process_publication_readback_v1(jsonb_build_object(
  'id','64a00000-0000-4000-8000-000000000010','version','01.00.000','idempotencyKey','happy-key'
)) as j;
reset role;

select is((select j->>'ok' from happy_readback), 'true', 'readback resolves the exact receipt binding');
select is((select j#>>'{data,verified,rowMatchesReceipt}' from happy_readback), 'true', 'readback confirms the row matches the receipt');
select is((select j#>>'{data,verified,receiptMatchesRequest}' from happy_readback), 'true', 'readback confirms the receipt matches the request');
select is((select j#>>'{data,verified,liveManager}' from happy_readback), 'true', 'readback reports the live manager recheck');
select is((select j#>>'{data,row,stateCode}' from happy_readback), '120', 'readback returns the live row state');
select is(
  (select j#>>'{data,row,contentText}' from happy_readback),
  pg_temp.mkcontent('64a00000-0000-4000-8000-000000000010','01.00.000'),
  'readback returns the exact stored content for independent verification'
);
select is(
  (select j#>>'{data,row,contentSha256}' from happy_readback),
  (select j#>>'{data,receipt,contentSha256}' from happy_readback),
  'the live content hash equals the attested content hash'
);

-- --------------------------------------------------------- retry and idempotency

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

-- The request is FROZEN before the first send and both sends use those identical bytes. A
-- lost-response retry is a retry of the SAME request, not a freshly built one: rebuilding it
-- after publication regenerates a preparation digest over the new precondition, which
-- correctly fails as a replay mismatch rather than demonstrating reuse.
create temporary table retry_frozen on commit drop as
select pg_temp.mkreq('64a00000-0000-4000-8000-000000000011','01.00.000','retry-key') as r;

create temporary table retry_first on commit drop as
select api.cmd_result_process_publish_v1((select r from retry_frozen)) as j;
select is((select j->>'ok' from retry_first), 'true', 'the retry fixture publishes once');

-- Replay the frozen bytes: the row is now at 120, so a recompute-first protocol would
-- wrongly reject this, while the receipt-first protocol must return the identical receipt.
create temporary table retry_second on commit drop as
select api.cmd_result_process_publish_v1((select r from retry_frozen)) as j;
select is((select j->>'ok' from retry_second), 'true', 'a lost-response retry succeeds');
select is((select j->>'reused' from retry_second), 'true', 'the retry is reported as reused');
select is(
  (select j#>>'{data,receiptId}' from retry_second),
  (select j#>>'{data,receiptId}' from retry_first),
  'the retry returns the identical receipt identity'
);
select is(
  (select j#>>'{data,preparationHash}' from retry_second),
  (select j#>>'{data,preparationHash}' from retry_first),
  'the retry returns the original preparation hash, not a recomputed one'
);
-- Internal receipt census: privileged observer, because the receipt table grants no browser
-- read at all. The API calls immediately above and below stay under the actor role.
reset role;
select is(
  (select count(*) from private.result_process_publications
   where dataset_id='64a00000-0000-4000-8000-000000000011'),
  1::bigint,
  'the retry creates no second receipt'
);
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

-- Same actor and key against a different identity must be rejected before any insert.
select is(
  api.cmd_result_process_publish_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000016','01.00.000','retry-key')
  )->>'code',
  'result_publication_replay_mismatch',
  'the same key against a different identity is a replay mismatch'
);
reset role;
select is(
  (select count(*) from public.processes where id='64a00000-0000-4000-8000-000000000016'),
  0::bigint,
  'the rejected mismatched identity created no row'
);

set local role authenticated;
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

-- Same key, same identity, different attested semantics.
select is(
  api.cmd_result_process_publish_v1(
    jsonb_set(
      pg_temp.mkreq('64a00000-0000-4000-8000-000000000011','01.00.000','retry-key'),
      '{source,approvalHash}', to_jsonb(repeat('e',64))
    )
  )->>'code',
  'result_publication_replay_mismatch',
  'a divergent attested hash under the same key is a replay mismatch'
);
-- A different key against an existing identity conflicts.
select is(
  api.cmd_result_process_publish_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000011','01.00.000','other-key')
  )->>'code',
  'result_publication_conflict',
  'a different idempotency key against an existing identity conflicts'
);
-- A stale preparation is refused when no receipt exists for the key.
select is(
  api.cmd_result_process_publish_v1(
    jsonb_set(
      pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','stale-key'),
      '{expectedPreparationHash}', to_jsonb(repeat('f',64))
    )
  )->>'code',
  'result_preparation_stale',
  'a stale preparation hash is refused'
);
reset role;
select is(
  (select count(*) from public.processes where id='64a00000-0000-4000-8000-000000000014'),
  0::bigint,
  'the stale attempt created no row'
);

-- ---------------------------------------------------- pre-existing rows and legacy state

-- Negative control: a DIFFERENT 55P03 must re-raise rather than be mislabelled as busy. The
-- handler matches the fence message exactly, so any other lock_not_available failure keeps its
-- own identity and is never converted into a retryable publication result.
create or replace function private.zz_publication_test_other_lock_failure() returns trigger
language plpgsql set search_path = '' as $other$
begin
  raise exception using
    errcode = '55P03',
    message = 'SOME_OTHER_LOCK_NOT_AVAILABLE';
end $other$;

create trigger zz_publication_test_other_lock_failure
  before insert on public.processes
  for each row
  when (new.id = '64a00000-0000-4000-8000-000000000016')
  execute function private.zz_publication_test_other_lock_failure();

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);
select throws_ok(
  $sql$ select api.cmd_result_process_publish_v1(
         pg_temp.mkreq('64a00000-0000-4000-8000-000000000016','01.00.000','other-lock-key')) $sql$,
  '55P03',
  'SOME_OTHER_LOCK_NOT_AVAILABLE',
  'an unrelated 55P03 re-raises instead of being reported as retryable busy'
);
reset role;

drop trigger zz_publication_test_other_lock_failure on public.processes;
drop function private.zz_publication_test_other_lock_failure();

select is(
  (select count(*) from public.processes where id='64a00000-0000-4000-8000-000000000016'),
  0::bigint,
  'the unrelated lock failure created no Process row'
);

set local role authenticated;
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000012','01.00.000')
  )#>>'{data,classification}',
  'candidate_content_matches_existing',
  'prepare reports content candidacy for a raw Result that already matches'
);
select is(
  api.cmd_result_process_publish_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000012','01.00.000','raw120-key')
  )->>'code',
  'result_publication_conflict',
  'a raw 120 row without a receipt cannot be adopted'
);
reset role;
select is(
  (select count(*) from private.result_process_publications
   where dataset_id='64a00000-0000-4000-8000-000000000012'),
  0::bigint,
  'the refused raw Result gained no receipt'
);
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000013','01.00.000')
  )#>>'{data,classification}',
  'conflict',
  'prepare classifies a legacy 100 identity as a conflict, never as absent'
);
select is(
  api.cmd_result_process_publish_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000013','01.00.000','legacy-key')
  )->>'code',
  'result_publication_conflict',
  'a legacy 100 row is never auto-upgraded to 120'
);
reset role;
select is(
  (select state_code::text from public.processes where id='64a00000-0000-4000-8000-000000000013'),
  '100',
  'the legacy row keeps its original state'
);

-- ------------------------------------------------------------ malformed and mutation

set local role authenticated;
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad1')||jsonb_build_object('bogus',1)
  )->>'code',
  'result_publish_request_invalid',
  'an unknown request field is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad2')||jsonb_build_object('role','result_process')
  )->>'code',
  'result_publish_request_invalid',
  'a client-supplied role is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad3')||jsonb_build_object('targetState',120)
  )->>'code',
  'result_publish_request_invalid',
  'a client-supplied target state is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad4')||jsonb_build_object('idempotencyKey','x')
  )->>'code',
  'result_publish_request_invalid',
  'an execute-only field is rejected during prepare'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad5')
    ||jsonb_build_object('source',(pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad5')->'source')
      ||jsonb_build_object('approvalHash',repeat('d',64)))
  )->>'code',
  'result_publish_request_invalid',
  'an approval hash is rejected during prepare so it cannot enter a preparation hash'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    jsonb_set(pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad6'),'{contentSha256}',to_jsonb(12345))
  )->>'code',
  'result_publish_request_invalid',
  'a numeric content hash is rejected instead of being coerced'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    jsonb_set(pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad7'),'{contentText}','{"a":1}'::jsonb)
  )->>'code',
  'result_publish_request_invalid',
  'an object contentText is rejected instead of being coerced to text'
);
select is(
  api.cmd_result_process_publish_v1(
    jsonb_set(pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad8'),'{idempotencyKey}',to_jsonb(7))
  )->>'code',
  'result_publish_request_invalid',
  'a numeric idempotency key is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad9')-'source'
  )->>'code',
  'result_publish_request_invalid',
  'a missing source block is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    jsonb_set(pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad10'),
      '{audit}', to_jsonb('{"reason":99}'::text))
  )->>'code',
  'result_publish_request_invalid',
  'a non-string audit reason is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    jsonb_set(pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad11'),
      '{audit}', jsonb_build_object('reason','ok','extra',1))
  )->>'code',
  'result_publish_request_invalid',
  'an unknown audit field is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad12')||jsonb_build_object('table','flows')
  )->>'code',
  'result_publish_request_invalid',
  'only processes can publish a Result'
);
select is(
  api.qry_result_process_publish_prepare_v1(
    jsonb_set(pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','bad13'),
      '{sourceKind}', to_jsonb('machine_lineage'::text))
  )->>'code',
  'result_publish_request_invalid',
  'a non-attested source kind is rejected'
);

-- Content-envelope negatives, driven through prepare so the real validator runs.
select is(
  api.qry_result_process_publish_prepare_v1(jsonb_set(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000014','01.00.000'),
    '{contentText}', to_jsonb(pg_temp.mkcontent_dup_root('64a00000-0000-4000-8000-000000000014','01.00.000'))))->>'code',
  'result_publish_content_invalid',
  'duplicate keys at the root are rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(jsonb_set(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000014','01.00.000'),
    '{contentText}', to_jsonb(pg_temp.mkcontent_dup_nested('64a00000-0000-4000-8000-000000000014','01.00.000'))))->>'code',
  'result_publish_content_invalid',
  'duplicate keys nested one level deep are rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(jsonb_set(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000014','01.00.000'),
    '{contentText}', to_jsonb(pg_temp.mkcontent('64a00000-0000-4000-8000-000000000099','01.00.000'))))->>'code',
  'result_publish_content_invalid',
  'a content UUID that disagrees with the request identity is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(jsonb_set(pg_temp.mkprepare('64a00000-0000-4000-8000-000000000014','01.00.000'),
    '{contentText}', to_jsonb('not json at all'::text)))->>'code',
  'result_publish_content_invalid',
  'malformed JSON text is rejected'
);
select is(
  api.qry_result_process_publish_prepare_v1(jsonb_set(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000014','01.00.000'),
    '{contentText}', to_jsonb('{"processDataSet":"not an object"}'::text)))->>'code',
  'result_publish_content_invalid',
  'a non-object processDataSet is rejected'
);
-- Content hash must match the submitted bytes.
select is(
  api.qry_result_process_publish_prepare_v1(jsonb_set(
    pg_temp.mkprepare('64a00000-0000-4000-8000-000000000014','01.00.000'),
    '{contentSha256}', to_jsonb(repeat('9',64))))->>'code',
  'result_content_hash_mismatch',
  'a content hash that does not match the submitted bytes is rejected'
);

-- ------------------------------------------------------------- readback negatives

select is(
  api.qry_result_process_publication_readback_v1(
    '{"id":"not-a-uuid","version":"01.00.000","idempotencyKey":"happy-key"}'::jsonb
  )->>'code',
  'result_publish_request_invalid',
  'readback rejects an invalid UUID with the promised envelope, not a raw cast error'
);
select is(
  api.qry_result_process_publication_readback_v1(jsonb_build_object(
    'id','64a00000-0000-4000-8000-000000000010','version','01.00.000',
    'idempotencyKey',repeat('k',201)))->>'code',
  'result_publish_request_invalid',
  'readback rejects an oversized idempotency key'
);
select is(
  api.qry_result_process_publication_readback_v1(jsonb_build_object(
    'id','64a00000-0000-4000-8000-000000000010','version','1.0.0','idempotencyKey','happy-key'
  ))->>'code',
  'result_publish_request_invalid',
  'readback rejects a wrong version format'
);
select is(
  api.qry_result_process_publication_readback_v1(jsonb_build_object(
    'id','64a00000-0000-4000-8000-000000000010','version','01.00.000',
    'idempotencyKey','happy-key','extra',1))->>'code',
  'result_publish_request_invalid',
  'readback rejects an unknown field'
);
select is(
  api.qry_result_process_publication_readback_v1(
    '{"id":"64a00000-0000-4000-8000-000000000010","version":"01.00.000","idempotencyKey":"missing-key"}'::jsonb
  )->>'code',
  'result_publication_not_found',
  'readback reports a missing receipt binding'
);
-- A receipt belonging to another actor is not reachable.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000002',true);
select is(
  api.qry_result_process_publication_readback_v1(jsonb_build_object(
    'id','64a00000-0000-4000-8000-000000000010','version','01.00.000','idempotencyKey','happy-key'
  ))->>'code',
  'not_data_product_manager',
  'a non-manager cannot read back another actor publication'
);
reset role;

-- ------------------------------------------------------- revocation on every path

insert into private.roles(user_id, team_id, role)
values ('64a00000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','member')
on conflict (user_id, team_id) do update set role = excluded.role;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000003',true);
-- Role removed before any call: prepare, execute and readback must all refuse.
select is(
  api.qry_result_process_publish_prepare_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000015','01.00.000','revoke-key')
  )->>'code',
  'not_data_product_manager',
  'a revoked manager cannot prepare'
);
select is(
  api.cmd_result_process_publish_v1(
    pg_temp.mkreq('64a00000-0000-4000-8000-000000000015','01.00.000','revoke-key')
  )->>'code',
  'not_data_product_manager',
  'a revoked manager cannot execute'
);
select is(
  api.qry_result_process_publication_readback_v1(jsonb_build_object(
    'id','64a00000-0000-4000-8000-000000000010','version','01.00.000','idempotencyKey','happy-key'
  ))->>'code',
  'not_data_product_manager',
  'a revoked manager cannot read back'
);
reset role;

-- Granting the role back does not resurrect a refused request, and the original actor's
-- already-recorded receipt is intact and still fully readable.
insert into private.roles(user_id, team_id, role)
values ('64a00000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','data_product_manager')
on conflict (user_id, team_id) do update set role = excluded.role;
select is(
  (select count(*) from private.result_process_publications
   where dataset_id='64a00000-0000-4000-8000-000000000015'),
  0::bigint,
  'revoked attempts recorded nothing'
);
select isnt(
  (select request_binding from private.result_process_publications
   where dataset_id='64a00000-0000-4000-8000-000000000010'),
  null::jsonb,
  'the earlier attestation receipt is unchanged by the revocation window'
);

-- --------------------------------------------------------------- cache and lifecycle

select is(
  (select count(*) from private.lcia_scope_closure_candidate_document_hashes
   where dataset_type='processes' and dataset_id='64a00000-0000-4000-8000-000000000010'),
  0::bigint,
  'a published Result never enters the numeric candidate cache'
);
select is(
  -- Identity 013 is deliberately a state-100 legacy row, so it is NOT excluded: a published
  -- state-100 process is exactly what the numeric candidate cache admits, with the
  -- unit_process role. Only the Result-derived identities must be absent.
  (select count(*) from private.lcia_scope_closure_candidate_document_hashes
   where dataset_type='processes'
     and dataset_id in ('64a00000-0000-4000-8000-000000000011',
                        '64a00000-0000-4000-8000-000000000014')),
  0::bigint,
  'no Result-derived fixture identity entered the numeric candidate cache'
);
select is(
  -- The legacy row stays numerically eligible: publication never removed its candidacy, and
  -- the isolation slices must not have touched state 100.
  (select role from private.lcia_scope_closure_candidate_document_hashes
   where dataset_type='processes'
     and dataset_id='64a00000-0000-4000-8000-000000000013'),
  'unit_process',
  'the legacy state-100 fixture remains a numeric unit_process candidate'
);
select is(
  (select count(*) from jsonb_array_elements(
     api.lcia_result_current_eligible_manifest()->'inputManifest'->'processes') as entry(value)
   where entry.value->>'id' in ('64a00000-0000-4000-8000-000000000010',
                                '64a00000-0000-4000-8000-000000000011')),
  0::bigint,
  'a published Result is absent from the current eligible input manifest'
);

-- The lifecycle guard still freezes the published Result.
select throws_ok(
  $sql$ update public.processes set state_code = 0
         where id = '64a00000-0000-4000-8000-000000000010'
           and version = '01.00.000' $sql$,
  '55000',
  'RESULT_PROCESS_LIFECYCLE_IMMUTABLE',
  'the lifecycle guard still refuses to unfreeze a published Result'
);
select throws_ok(
  $sql$ update private.result_process_publications
          set content_sha256 = repeat('0',64)
        where dataset_id = '64a00000-0000-4000-8000-000000000010' $sql$,
  '55000',
  'RESULT_PROCESS_ATTESTATION_IMMUTABLE',
  'the attestation receipt is append-only'
);

-- ------------------------------------------------------------- late-failure atomicity

-- ------------------------------------------------- actor-fence contention and 55P03

-- The governed row fence raises SQLSTATE 55P03 with the exact message
-- FLOW_IDENTITY_ACTIVE_SCOPE_ACTOR_FENCE_BUSY when another transaction holds the actor's own
-- row-domain lock. A single rollback-only session cannot hold an advisory lock against itself
-- (advisory locks are re-entrant per backend), so genuine two-session contention is proven in
-- the companion concurrency harness. What this suite proves is the HANDLER: the exact busy
-- message is converted to a typed retryable envelope, its insert rolls back, and a DIFFERENT
-- 55P03 re-raises rather than being mislabelled.
create or replace function private.zz_publication_test_actor_fence_busy() returns trigger
language plpgsql set search_path = '' as $fence$
begin
  raise exception using
    errcode = '55P03',
    message = 'FLOW_IDENTITY_ACTIVE_SCOPE_ACTOR_FENCE_BUSY';
end $fence$;

create trigger zz_publication_test_actor_fence_busy
  before insert on public.processes
  for each row
  when (new.id = '64a00000-0000-4000-8000-000000000014')
  execute function private.zz_publication_test_actor_fence_busy();

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

create temporary table busy_attempt on commit drop as
select api.cmd_result_process_publish_v1(
  pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','fence-busy-key')
) as j;

select is(
  (select j->>'ok' from busy_attempt),
  'false',
  'actor-fence contention does not report success'
);
select is(
  (select j->>'code' from busy_attempt),
  'result_publication_busy',
  'actor-fence contention is reported as a typed retryable busy code'
);
select is(
  (select j->>'status' from busy_attempt),
  '409',
  'the busy envelope carries the conflict class'
);
select isnt(
  (select j->>'message' from busy_attempt),
  null::text,
  'the busy envelope carries bounded retry guidance'
);
-- The remaining checks are INTERNAL database facts, so they run as a privileged test observer.
-- Reading a state-120 row or the receipt table as the actor would be hidden by the isolation
-- policy and by the receipt ACL, which are separate contracts asserted elsewhere.
reset role;
select is(
  (select count(*) from public.processes where id='64a00000-0000-4000-8000-000000000014'),
  0::bigint,
  'the contended insert left no Process row'
);
select is(
  (select count(*) from private.result_process_publications
   where dataset_id='64a00000-0000-4000-8000-000000000014'),
  0::bigint,
  'the contended insert left no attestation receipt'
);
select is(
  (select count(*) from private.command_audit_log
   where command='cmd_result_process_publish_v1'
     and target_id='64a00000-0000-4000-8000-000000000014'),
  0::bigint,
  'the contended insert left no audit row'
);

-- Once the contention clears, the identical frozen request succeeds and a repeat returns the
-- same receipt. In this single session that is shown by removing the injected fence.
drop trigger zz_publication_test_actor_fence_busy on public.processes;
drop function private.zz_publication_test_actor_fence_busy();

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

create temporary table busy_frozen on commit drop as
select pg_temp.mkreq('64a00000-0000-4000-8000-000000000014','01.00.000','fence-busy-key') as r;
create temporary table busy_released on commit drop as
select api.cmd_result_process_publish_v1((select r from busy_frozen)) as j;
select is(
  (select j->>'ok' from busy_released),
  'true',
  'the identical request succeeds once the contention clears'
);
create temporary table busy_repeat on commit drop as
select api.cmd_result_process_publish_v1((select r from busy_frozen)) as j;
select is(
  (select j->>'reused' from busy_repeat),
  'true',
  'repeating the same frozen request returns the same receipt'
);
select is(
  (select j#>>'{data,receiptId}' from busy_repeat),
  (select j#>>'{data,receiptId}' from busy_released),
  'the repeated receipt identity is unchanged'
);
reset role;

-- A failure after the Process insert must roll back the row, the receipt and the audit
-- together, and must RAISE rather than returning a false error with an orphan row.
--
-- The audit write is the last step, so failing it exercises exactly that window. A
-- temporary trigger on the audit table makes that write fail only for this fixture, and is
-- the real code path rather than a simulated post-hoc raise.
-- The trigger function is created in `private` rather than pg_temp: a trigger on a
-- permanent table referencing a temporary-schema function is not reliably supported, and
-- this whole suite runs inside one rollback-only transaction, so the function disappears
-- with the test. The name is test-only and prefixed to avoid any real object.
create or replace function private.zz_publication_test_fail_audit() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.command = 'cmd_result_process_publish_v1'
     and new.target_id = '64a00000-0000-4000-8000-000000000017' then
    raise exception using errcode = '55000', message = 'simulated audit failure';
  end if;
  return new;
end $$;

create trigger fail_publication_audit
  before insert on private.command_audit_log
  for each row execute function private.zz_publication_test_fail_audit();

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','64a00000-0000-4000-8000-000000000001',true);

select throws_ok(
  $sql$ select api.cmd_result_process_publish_v1(pg_temp.mkreq(
        '64a00000-0000-4000-8000-000000000017','01.00.000','late-fail-key')) $sql$,
  '55000',
  null,
  'a late audit failure raises instead of returning a false error'
);
reset role;

drop trigger fail_publication_audit on private.command_audit_log;
drop function private.zz_publication_test_fail_audit();

select is(
  (select count(*) from public.processes where id='64a00000-0000-4000-8000-000000000017'),
  0::bigint,
  'no Process row survives the late failure'
);
select is(
  (select count(*) from private.result_process_publications
   where dataset_id='64a00000-0000-4000-8000-000000000017'),
  0::bigint,
  'no attestation receipt survives the late failure'
);
select is(
  (select count(*) from private.command_audit_log
   where command='cmd_result_process_publish_v1'
     and target_id='64a00000-0000-4000-8000-000000000017'),
  0::bigint,
  'no audit row survives the late failure'
);

select * from finish();
rollback;
