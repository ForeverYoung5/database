-- Foundry #60 / Database #673 — versioned protected lifecycle for the v2 Time repair.
--
-- A version-separated copy of the frozen v1 protected execution lifecycle (20260715142000): its own
-- preflight/gate/admit/read endpoints in `api`, its own receipt/request/preflight tables in `util`, its own
-- service-only execute callback, and the same protective mechanics — the rollback-only preflight simulation
-- with a server-clock 180-second window, the three stored gate receipts with their captured timestamps, the
-- exact five-key admission envelope, the single-attempt dispatch ledger, the service-role/nonce-bound
-- callback and a fresh current readback. The private executor runs the v2 plan executor, whose expectations
-- come from the plan's own ten flat expected counts plus the versioned text-action count and the six-key
-- derivative targets; nothing here trusts a declaration the run does not prove.
--
-- v1 stays byte-identical: this file creates only *_v2_* objects and the CLI-ALIAS-02 capability rows.

-- Protected one-shot execution for the fixed owner-draft alias profile.
--
-- Preflight executes the complete alias plan and derivative-batch admission in
-- a subtransaction, then deliberately rolls that subtransaction back.  The
-- durable preflight row is therefore a bounded, server-clock proof that the
-- exact plan was executable without changing business data.  Admission
-- consumes that proof once and queues exactly one service-role executor call.

create table util.dataset_alias_execution_v2_preflights (
  id uuid primary key,
  actor_user_id uuid not null,
  actor_email text not null,
  environment text not null,
  project_ref text not null,
  target_visibility text not null default 'owner_draft',
  plan jsonb not null,
  freeze_envelope jsonb not null,
  approval_envelope jsonb not null,
  plan_sha256 text not null,
  operation_id text not null,
  plan_request_sha256 text not null,
  bindings jsonb not null,
  bindings_sha256 text not null,
  expected jsonb not null,
  expected_sha256 text not null,
  derivative_targets jsonb not null,
  derivative_targets_sha256 text not null,
  gate_expectations jsonb not null,
  gate_expectations_sha256 text not null,
  failure_baseline_sha256 text not null,
  preflight_request_sha256 text not null,
  preflight_proof_sha256 text not null,
  freeze_sha256 text not null,
  approval_identity_sha256 text not null,
  token_sha256 text not null,
  completed_at timestamp with time zone not null,
  expires_at timestamp with time zone not null,
  consumed_at timestamp with time zone,
  created_at timestamp with time zone not null default pg_catalog.clock_timestamp(),
  constraint dataset_alias_execution_v2_preflight_visibility_check
    check (target_visibility = 'owner_draft'),
  constraint dataset_alias_execution_v2_preflight_environment_check
    check (environment in ('production', 'preview', 'local')),
  constraint dataset_alias_execution_v2_preflight_hashes_check
    check (
      plan_sha256 ~ '^[a-f0-9]{64}$'
      and plan_request_sha256 ~ '^[a-f0-9]{64}$'
      and bindings_sha256 ~ '^[a-f0-9]{64}$'
      and expected_sha256 ~ '^[a-f0-9]{64}$'
      and derivative_targets_sha256 ~ '^[a-f0-9]{64}$'
      and gate_expectations_sha256 ~ '^[a-f0-9]{64}$'
      and failure_baseline_sha256 ~ '^[a-f0-9]{64}$'
      and preflight_request_sha256 ~ '^[a-f0-9]{64}$'
      and preflight_proof_sha256 ~ '^[a-f0-9]{64}$'
      and freeze_sha256 ~ '^[a-f0-9]{64}$'
      and approval_identity_sha256 ~ '^[a-f0-9]{64}$'
      and token_sha256 ~ '^[a-f0-9]{64}$'
    ),
  constraint dataset_alias_execution_v2_preflight_window_check
    check (
      expires_at = completed_at + interval '180 seconds'
      and (consumed_at is null or consumed_at between completed_at and expires_at)
    )
);

create unique index dataset_alias_execution_v2_preflight_actor_request_uidx
  on util.dataset_alias_execution_v2_preflights (
    actor_user_id,
    preflight_request_sha256
  );

create unique index dataset_alias_execution_v2_preflight_token_uidx
  on util.dataset_alias_execution_v2_preflights (token_sha256);

create unique index dataset_alias_execution_v2_preflight_approval_uidx
  on util.dataset_alias_execution_v2_preflights (
    actor_user_id,
    approval_identity_sha256
  );

create index dataset_alias_execution_v2_preflight_actor_read_idx
  on util.dataset_alias_execution_v2_preflights (
    actor_user_id,
    completed_at desc
  );

create table util.dataset_alias_execution_v2_gate_receipts (
  preflight_id uuid not null
    references util.dataset_alias_execution_v2_preflights(id) on delete cascade,
  actor_user_id uuid not null,
  gate_name text not null,
  expected_sha256 text not null,
  observed_sha256 text not null,
  material jsonb not null,
  status text not null,
  captured_at timestamp with time zone not null,
  receipt_sha256 text not null,
  primary key (preflight_id, gate_name),
  constraint dataset_alias_execution_v2_gate_name_check
    check (gate_name in (
      'primary_support_plan',
      'execution_unused',
      'derivative_quiescence'
    )),
  constraint dataset_alias_execution_v2_gate_status_check
    check (status = 'passed'),
  constraint dataset_alias_execution_v2_gate_hashes_check
    check (
      expected_sha256 ~ '^[a-f0-9]{64}$'
      and observed_sha256 ~ '^[a-f0-9]{64}$'
      and receipt_sha256 ~ '^[a-f0-9]{64}$'
    )
);

create index dataset_alias_execution_v2_gate_actor_read_idx
  on util.dataset_alias_execution_v2_gate_receipts (
    actor_user_id,
    preflight_id,
    captured_at
  );

create table util.dataset_alias_execution_v2_requests (
  id uuid primary key
    references util.dataset_alias_execution_v2_preflights(id),
  actor_user_id uuid not null,
  plan_sha256 text not null,
  operation_id text not null,
  plan_request_sha256 text not null,
  freeze_sha256 text not null,
  approval_identity_sha256 text not null,
  approval_text_sha256 text not null,
  derivative_target_set_sha256 text not null,
  preflight_proof_sha256 text not null,
  admission_request_sha256 text not null,
  gate_results jsonb not null,
  gate_results_sha256 text not null,
  nonce_sha256 text not null,
  attempt_count smallint not null default 1,
  dispatch_count smallint not null default 0,
  net_request_id bigint,
  status text not null default 'dispatching',
  admitted_at timestamp with time zone not null,
  dispatched_at timestamp with time zone,
  started_at timestamp with time zone,
  primary_committed_at timestamp with time zone,
  terminal_at timestamp with time zone,
  alias_result jsonb,
  derivative_admission jsonb,
  terminal_proof jsonb,
  last_error jsonb,
  created_at timestamp with time zone not null default pg_catalog.clock_timestamp(),
  updated_at timestamp with time zone not null default pg_catalog.clock_timestamp(),
  constraint dataset_alias_execution_v2_request_hashes_check
    check (
      plan_sha256 ~ '^[a-f0-9]{64}$'
      and plan_request_sha256 ~ '^[a-f0-9]{64}$'
      and freeze_sha256 ~ '^[a-f0-9]{64}$'
      and approval_identity_sha256 ~ '^[a-f0-9]{64}$'
      and approval_text_sha256 ~ '^[a-f0-9]{64}$'
      and derivative_target_set_sha256 ~ '^[a-f0-9]{64}$'
      and preflight_proof_sha256 ~ '^[a-f0-9]{64}$'
      and admission_request_sha256 ~ '^[a-f0-9]{64}$'
      and gate_results_sha256 ~ '^[a-f0-9]{64}$'
      and nonce_sha256 ~ '^[a-f0-9]{64}$'
    ),
  constraint dataset_alias_execution_v2_request_attempt_check
    check (
      attempt_count = 1
      and dispatch_count in (0, 1)
      and (
        (dispatch_count = 0 and net_request_id is null and dispatched_at is null)
        or (dispatch_count = 1 and net_request_id is not null and dispatched_at is not null)
      )
    ),
  constraint dataset_alias_execution_v2_request_status_check
    check (status in (
      'dispatching',
      'dispatched',
      'running',
      'derivatives_pending',
      'completed',
      'failed',
      'indeterminate'
    )),
  constraint dataset_alias_execution_v2_request_terminal_check
    check (
      (status in ('completed', 'failed', 'indeterminate') and terminal_at is not null)
      or (status not in ('completed', 'failed', 'indeterminate') and terminal_at is null)
    )
);

create unique index dataset_alias_execution_v2_sealed_attempt_uidx
  on util.dataset_alias_execution_v2_requests (
    actor_user_id,
    approval_identity_sha256
  );

create unique index dataset_alias_execution_v2_net_request_uidx
  on util.dataset_alias_execution_v2_requests (net_request_id)
  where net_request_id is not null;

create index dataset_alias_execution_v2_actor_read_idx
  on util.dataset_alias_execution_v2_requests (
    actor_user_id,
    admitted_at desc
  );

revoke all on table util.dataset_alias_execution_v2_preflights
  from public, anon, authenticated, service_role;
revoke all on table util.dataset_alias_execution_v2_gate_receipts
  from public, anon, authenticated, service_role;
revoke all on table util.dataset_alias_execution_v2_requests
  from public, anon, authenticated, service_role;

comment on table util.dataset_alias_execution_v2_preflights is
  'Private server-clock proofs for rollback-only validation of one immutable owner-draft alias plan and its exact derivative target set.';
comment on table util.dataset_alias_execution_v2_gate_receipts is
  'Private, one-per-name server receipts for the three post-preflight live gates. Admission accepts only exact receipts persisted inside the same 180-second window.';
comment on table util.dataset_alias_execution_v2_requests is
  'Private one-attempt ledger. A sealed approval identity can create at most one row and at most one pg_net dispatch; status/readback never redispatches.';

create or replace function util.dataset_alias_execution_v2_sha256(
  p_value text
) returns text
language sql
immutable
strict
set search_path = ''
as $$
  select pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_value, 'UTF8'), 'sha256'),
    'hex'
  )
$$;

alter function util.dataset_alias_execution_v2_sha256(text)
  owner to postgres;
revoke all on function util.dataset_alias_execution_v2_sha256(text)
  from public, anon, authenticated, service_role;

create or replace function util.dataset_alias_execution_v2_artifact_sha256(
  p_value jsonb
) returns text
language sql
stable
strict
set search_path = ''
as $$
  select util.dataset_alias_execution_v2_sha256(
    private.dataset_alias_canonical_jsonb_v1(p_value)
  )
$$;

alter function util.dataset_alias_execution_v2_artifact_sha256(jsonb)
  owner to postgres;
revoke all on function util.dataset_alias_execution_v2_artifact_sha256(jsonb)
  from public, anon, authenticated, service_role;

comment on function util.dataset_alias_execution_v2_artifact_sha256(jsonb) is
  'Hashes parsed JSON with the same recursive key ordering and compact serialization as CLI stableJsonText. Private protected-execution artifact verifier only.';


-- ------------------------------------------------------------------------------------------------
-- The versioned derivative orchestration: the approved target set is partitioned deterministically
-- into bounded sub-batches so the reviewed full-size cohort can be admitted through the existing
-- fifty-target derivative owner without changing that owner, its constraints or any of its callers.
-- Chunk identities are derived from the approved parent request and plan digest, so the partition is
-- reproducible, bound to one parent, and cannot be chosen by a caller.
-- ------------------------------------------------------------------------------------------------
create or replace function private.dataset_alias_v2_derivative_chunks(
  p_request_id uuid,
  p_plan_sha256 text,
  p_targets jsonb
) returns jsonb
language sql
immutable
as $$
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

alter function private.dataset_alias_v2_derivative_chunks(uuid, text, jsonb) owner to postgres;
revoke all on function private.dataset_alias_v2_derivative_chunks(uuid, text, jsonb) from public;
comment on function private.dataset_alias_v2_derivative_chunks(uuid, text, jsonb) is
  'Deterministic partition of the approved ordered derivative targets into sub-batches of at most fifty, with chunk identities bound to the parent request and plan digest.';

-- Admits every chunk through the existing bounded derivative owner and returns the complete child
-- mapping. Any chunk refusal is reported as a refusal of the whole orchestration: the caller raises
-- and its enclosing transaction rolls back the primary writes, the audits and every earlier chunk.
create or replace function util.admit_dataset_alias_v2_derivative_chunks(
  p_actor_user_id uuid,
  p_request_id uuid,
  p_plan_sha256 text,
  p_operation_id text,
  p_scope text,
  p_targets jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chunks jsonb;
  v_chunk jsonb;
  v_admitted jsonb := '[]'::jsonb;
  v_result jsonb;
  v_target_count integer := 0;
  v_flow_count integer := 0;
  v_process_count integer := 0;
  v_detail text;
  v_hint text;
  v_current_ordinal integer;
begin
  v_chunks := private.dataset_alias_v2_derivative_chunks(p_request_id, p_plan_sha256, p_targets);

  -- The partition must be exact: every approved target exactly once, no chunk above the bound, no
  -- chunk without targets, distinct deterministic identities.
  if (select count(*) from jsonb_array_elements(v_chunks) as chunk
        where (chunk->>'target_count')::integer not between 1 and 50) <> 0
    or (select count(distinct chunk->>'batch_id') from jsonb_array_elements(v_chunks) as chunk)
      <> jsonb_array_length(v_chunks)
    or (select coalesce(sum((chunk->>'target_count')::integer), 0) from jsonb_array_elements(v_chunks) as chunk)
      <> jsonb_array_length(coalesce(p_targets, '[]'::jsonb)) then
    return jsonb_build_object('ok', false, 'code', 'ALIAS_EXECUTION_DERIVATIVE_PARTITION_INVALID',
      'message', 'The derivative target partition is not an exact bounded cover of the approved targets');
  end if;

  -- The whole orchestration is one unit of work: a refusal raised inside this block takes every
  -- earlier chunk admission, its child rows and its audit effects down with it, so a caller can never
  -- observe a partially admitted target set.
  begin
    for v_chunk in select * from jsonb_array_elements(v_chunks) as chunk loop
      v_current_ordinal := (v_chunk->>'ordinal')::integer;
      v_result := util.admit_dataset_derivative_rebuild_batch(
        p_actor_user_id,
        (v_chunk->>'batch_id')::uuid,
        p_plan_sha256,
        p_operation_id,
        p_scope,
        v_chunk->'targets'
      );
      if coalesce((v_result->>'ok')::boolean, false) is not true
        or (v_result->>'target_count')::integer is distinct from (v_chunk->>'target_count')::integer then
        raise exception using
          errcode = 'P0001',
          message = 'ALIAS_EXECUTION_DERIVATIVE_CHUNK_REFUSED',
          detail = 'A derivative sub-batch of the approved target set was refused',
          hint = jsonb_build_object(
            'ordinal', (v_chunk->>'ordinal')::integer,
            'batch_id', v_chunk->>'batch_id',
            'result', coalesce(v_result, '{}'::jsonb))::text;
      end if;
      v_target_count := v_target_count + (v_result->>'target_count')::integer;
      v_flow_count := v_flow_count + coalesce((v_result->>'flow_count')::integer, 0);
      v_process_count := v_process_count + coalesce((v_result->>'process_count')::integer, 0);
      v_admitted := v_admitted || jsonb_build_array(jsonb_build_object(
        'ordinal', (v_chunk->>'ordinal')::integer,
        'batch_id', v_chunk->>'batch_id',
        'target_count', (v_chunk->>'target_count')::integer,
        'summary_audit_id', v_result->>'summary_audit_id',
        'child_request_ids', coalesce(v_result->'child_request_ids', '[]'::jsonb)));
    end loop;
  exception
    when others then
      -- The subtransaction is already rolled back here, so every earlier chunk admission and its child
      -- rows are gone: the orchestration refuses as a whole. The owner's own refusal classes and any
      -- unexpected error both surface as this envelope, with the raising sqlstate kept for diagnosis —
      -- fail closed, never partially admitted.
      get stacked diagnostics v_detail = pg_exception_detail, v_hint = pg_exception_hint;
      return jsonb_build_object(
        'ok', false,
        'code', coalesce(nullif(sqlerrm, ''), 'ALIAS_EXECUTION_DERIVATIVE_CHUNK_REFUSED'),
        'sqlstate', sqlstate,
        'ordinal', v_current_ordinal,
        'chunks_admitted_before_refusal', coalesce(v_current_ordinal, 1) - 1,
        'message', coalesce(nullif(v_detail, ''), 'A derivative sub-batch of the approved target set was refused'))
        || coalesce(nullif(v_hint, '')::jsonb, '{}'::jsonb);
  end;

  return jsonb_build_object(
    'ok', true,
    'code', 'ALIAS_EXECUTION_DERIVATIVE_CHUNKS_ADMITTED',
    'chunk_count', jsonb_array_length(v_chunks),
    'chunk_target_bound', 50,
    'target_count', v_target_count,
    'flow_count', v_flow_count,
    'process_count', v_process_count,
    'chunks', v_admitted);
end
$$;

alter function util.admit_dataset_alias_v2_derivative_chunks(uuid, uuid, text, text, text, jsonb) owner to postgres;
revoke all on function util.admit_dataset_alias_v2_derivative_chunks(uuid, uuid, text, text, text, jsonb)
  from public, anon, authenticated, service_role;
comment on function util.admit_dataset_alias_v2_derivative_chunks(uuid, uuid, text, text, text, jsonb) is
  'Versioned derivative orchestration: partitions the approved targets deterministically, admits every chunk through the existing bounded derivative owner inside the caller transaction, and returns the complete child-batch mapping.';


-- Reads the complete child mapping of one versioned derivative orchestration: every chunk through the
-- existing bounded reader, aggregated into the exact membership, counts and terminal status of the
-- approved target set. A terminal proof exists only when every chunk reports its own causal terminal
-- proof over exactly its own targets — no chunk, no success.
create or replace function util.read_dataset_alias_v2_derivative_chunks(
  p_actor_user_id uuid,
  p_request_id uuid,
  p_plan_sha256 text,
  p_targets jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_chunks jsonb;
  v_chunk jsonb;
  v_proof jsonb;
  v_chunk_proofs jsonb := '[]'::jsonb;
  v_target_count integer := 0;
  v_flow_count integer := 0;
  v_process_count integer := 0;
  v_completed_count integer := 0;
  v_nonterminal_count integer := 0;
  v_failed_count integer := 0;
  v_invalid_proof_count integer := 0;
  v_all_terminal boolean := true;
  v_any_failed boolean := false;
begin
  v_chunks := private.dataset_alias_v2_derivative_chunks(p_request_id, p_plan_sha256, p_targets);

  for v_chunk in select * from jsonb_array_elements(v_chunks) as chunk loop
    v_proof := util.read_dataset_derivative_rebuild_batch_any(
      p_actor_user_id,
      (v_chunk->>'batch_id')::uuid
    );
    v_target_count := v_target_count + coalesce((v_proof->>'target_count')::integer, 0);
    v_flow_count := v_flow_count + coalesce((v_proof->>'flow_count')::integer, 0);
    v_process_count := v_process_count + coalesce((v_proof->>'process_count')::integer, 0);
    v_completed_count := v_completed_count + coalesce((v_proof->>'completed_count')::integer, 0);
    v_nonterminal_count := v_nonterminal_count + coalesce((v_proof->>'nonterminal_count')::integer, 0);
    v_failed_count := v_failed_count + coalesce((v_proof->>'failed_count')::integer, 0);
    v_invalid_proof_count := v_invalid_proof_count + coalesce((v_proof->>'invalid_proof_count')::integer, 0);
    if coalesce((v_proof->>'causal_terminal_proof')::boolean, false) is not true then
      v_all_terminal := false;
    end if;
    if (v_proof->>'status') = 'failed' then
      v_any_failed := true;
    end if;
    v_chunk_proofs := v_chunk_proofs || jsonb_build_array(jsonb_build_object(
      'ordinal', (v_chunk->>'ordinal')::integer,
      'batch_id', v_chunk->>'batch_id',
      'status', v_proof->>'status',
      'code', v_proof->>'code',
      'target_count', coalesce((v_proof->>'target_count')::integer, 0),
      'completed_count', coalesce((v_proof->>'completed_count')::integer, 0),
      'nonterminal_count', coalesce((v_proof->>'nonterminal_count')::integer, 0),
      'failed_count', coalesce((v_proof->>'failed_count')::integer, 0),
      'causal_terminal_proof', coalesce((v_proof->>'causal_terminal_proof')::boolean, false)));
  end loop;

  return jsonb_build_object(
    'schema_version', 'dataset-alias-v2-derivative-orchestration.v1',
    'request_id', p_request_id,
    'chunk_count', jsonb_array_length(v_chunks),
    'chunk_target_bound', 50,
    'target_count', v_target_count,
    'approved_target_count', jsonb_array_length(coalesce(p_targets, '[]'::jsonb)),
    'membership_exact', v_target_count = jsonb_array_length(coalesce(p_targets, '[]'::jsonb)),
    'flow_count', v_flow_count,
    'process_count', v_process_count,
    'completed_count', v_completed_count,
    'nonterminal_count', v_nonterminal_count,
    'failed_count', v_failed_count,
    'invalid_proof_count', v_invalid_proof_count,
    'causal_terminal_proof', v_all_terminal and v_target_count = jsonb_array_length(coalesce(p_targets, '[]'::jsonb)),
    'status', case
      when v_any_failed then 'failed'
      when v_all_terminal and v_target_count = jsonb_array_length(coalesce(p_targets, '[]'::jsonb)) then 'completed'
      else 'pending'
    end,
    'chunks', v_chunk_proofs);
end
$$;

alter function util.read_dataset_alias_v2_derivative_chunks(uuid, uuid, text, jsonb) owner to postgres;
revoke all on function util.read_dataset_alias_v2_derivative_chunks(uuid, uuid, text, jsonb)
  from public, anon, authenticated, service_role;
comment on function util.read_dataset_alias_v2_derivative_chunks(uuid, uuid, text, jsonb) is
  'Aggregated readback of one versioned derivative orchestration: every chunk read through the existing bounded reader, with exact membership, counts and a terminal proof only when every chunk proves its own closure.';


-- ------------------------------------------------------------------------------------------------
-- The strict terminal proof of an execution: emitted only when the live primary closure and every
-- derivative child causal terminal proof pass. Every observation in it is read from the CURRENT rows
-- and the ACTUAL audit ledger — never copied from the plan's desired claims — and the scientific batch
-- identity is the plan's own batch count, not the number of tables and not the derivative chunk count.
-- ------------------------------------------------------------------------------------------------
create or replace function util.read_dataset_alias_execution_v2_terminal_proof(
  p_actor_user_id uuid,
  p_plan jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_expected jsonb := coalesce(p_plan->'expected', '{}'::jsonb);
  v_plan_sha256 text := p_plan->>'plan_sha256';
  v_row_audits jsonb;
  v_readback_rows jsonb := '[]'::jsonb;
  v_action jsonb;
  v_row jsonb;
  v_plan_summary_id bigint;
  v_batch_summary_id bigint;
begin
  -- Per-row audit identity and observation come from the committed ledger rows of this plan identity.
  select coalesce(jsonb_agg(jsonb_build_object(
      'audit_id', audit.id,
      'action_id', audit.payload->>'action_id',
      'table', audit.target_table,
      'id', audit.target_id,
      'version', audit.target_version,
      'after_sha256', audit.payload->>'after_sha256') order by audit.id), '[]'::jsonb)
    into v_row_audits
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_alias_batch_v2_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'row';

  select audit.id into v_batch_summary_id
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_alias_batch_v2_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'plan'
  order by audit.id desc limit 1;

  select audit.id into v_plan_summary_id
  from private.command_audit_log as audit
  where audit.command = 'cmd_dataset_alias_plan_v2_guarded'
    and audit.actor_user_id = p_actor_user_id
    and audit.payload->>'plan_sha256' = v_plan_sha256
    and audit.payload->>'record_type' = 'plan_summary'
  order by audit.id desc limit 1;

  -- Fresh per-row observations: the canonical digest of the row as it stands now, plus the
  -- functional-unit text leaf the row currently carries.
  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) loop
    v_row := null;
    if v_action->>'table' = 'flows' then
      select jsonb_build_object(
          'table', 'flows', 'id', flow.id, 'version', btrim(flow.version::text),
          'observed_sha256', private.dataset_alias_v2_payload_sha256(flow.json_ordered::jsonb),
          'functional_unit_text', null)
        into v_row
      from public.flows as flow
      where flow.id = (v_action->>'id')::uuid
        and btrim(flow.version::text) = v_action->>'version'
        and flow.user_id = p_actor_user_id
        and flow.state_code = 0;
    elsif v_action->>'table' = 'processes' then
      select jsonb_build_object(
          'table', 'processes', 'id', process.id, 'version', btrim(process.version::text),
          'observed_sha256', private.dataset_alias_v2_payload_sha256(process.json_ordered::jsonb),
          'functional_unit_text',
            process.json_ordered::jsonb #>> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther,#text}')
        into v_row
      from public.processes as process
      where process.id = (v_action->>'id')::uuid
        and btrim(process.version::text) = v_action->>'version'
        and process.user_id = p_actor_user_id
        and process.state_code = 0;
    end if;
    if v_row is not null then
      v_readback_rows := v_readback_rows || jsonb_build_array(v_row);
    end if;
  end loop;

  return jsonb_build_object(
    'status', 'applied',
    'plan_sha256', v_plan_sha256,
    'counts', v_expected,
    'audit', jsonb_build_object(
      'batch_count', coalesce((v_expected->>'batch_count')::integer, 1),
      'row_audit_count', coalesce(jsonb_array_length(v_row_audits), 0),
      'plan_summary_audit_id', v_plan_summary_id,
      'batch_summary_audit_id', v_batch_summary_id,
      'row_audits', coalesce(v_row_audits, '[]'::jsonb)),
    'readback', jsonb_build_object(
      'row_count', jsonb_array_length(v_readback_rows),
      'exchange_count', coalesce((v_expected->>'exchange_count')::integer, 0),
      'rows', v_readback_rows));
end
$$;

alter function util.read_dataset_alias_execution_v2_terminal_proof(uuid, jsonb) owner to postgres;
revoke all on function util.read_dataset_alias_execution_v2_terminal_proof(uuid, jsonb)
  from public, anon, authenticated, service_role;
comment on function util.read_dataset_alias_execution_v2_terminal_proof(uuid, jsonb) is
  'Strict 5-key terminal proof (status/plan_sha256/counts/audit/readback) built from the committed ledger identifiers and fresh current-row observations. Callers emit it only after the live primary closure and every derivative child causal terminal proof pass.';

create or replace function util.dataset_alias_execution_v2_server_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_project_url text;
  v_host text;
  v_project_ref text;
  v_environment text;
begin
  v_project_url := btrim(util.project_url());
  v_host := lower(
    pg_catalog.regexp_replace(
      v_project_url,
      '^https?://([^/:]+).*$'::text,
      '\1'::text
    )
  );

  if nullif(v_host, '') is null or v_host = lower(v_project_url) then
    raise exception using
      errcode = '22023',
      message = 'Branch-local project_url is not a valid HTTP(S) project URL';
  end if;

  if v_host in ('127.0.0.1', 'localhost', 'kong', 'host.docker.internal') then
    v_project_ref := 'local';
    v_environment := 'local';
  elsif v_host ~ '^[a-z0-9-]+\.supabase\.co$' then
    v_project_ref := pg_catalog.split_part(v_host, '.', 1);
    v_environment := case
      when v_project_ref = 'qgzvkongdjqiiamzbbts' then 'production'
      else 'preview'
    end;
  else
    v_project_ref := v_host;
    v_environment := 'preview';
  end if;

  return jsonb_build_object(
    'environment', v_environment,
    'project_ref', v_project_ref,
    'project_url_sha256', util.dataset_alias_execution_v2_sha256(v_project_url)
  );
end;
$$;

alter function util.dataset_alias_execution_v2_server_context()
  owner to postgres;
revoke all on function util.dataset_alias_execution_v2_server_context()
  from public, anon, authenticated, service_role;

comment on function util.dataset_alias_execution_v2_server_context() is
  'Derives protected-execution environment and project identity from the branch-local Vault project_url. Only the production project ref qgzvkongdjqiiamzbbts is classified as production.';

create or replace function api.cmd_dataset_alias_execution_preflight_v2_guarded(
  p_request jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set statement_timeout = '60s'
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_email text := auth.email();
  v_schema_version constant text := 'dataset-alias-execution-preflight.v2';
  v_request_id uuid;
  v_environment text;
  v_project_ref text;
  v_server_context jsonb;
  v_request_actor jsonb;
  v_plan jsonb;
  v_freeze jsonb;
  v_approval jsonb;
  v_expected_freeze jsonb;
  v_expected_approval jsonb;
  v_bindings jsonb;
  v_expected jsonb;
  v_input_targets jsonb;
  v_targets jsonb;
  v_sorted_targets jsonb;
  v_gate_expectations jsonb;
  v_primary_gate_material jsonb;
  v_unused_gate_material jsonb;
  v_quiescence_gate_material jsonb;
  v_plan_sha256 text;
  v_operation_id text;
  v_plan_request_sha256 text;
  v_alias_plan_request_sha256 text;
  v_derivative_target_set_sha256 text;
  v_derivative_baseline_set_sha256 text;
  v_bindings_sha256 text;
  v_expected_sha256 text;
  v_targets_sha256 text;
  v_gate_expectations_sha256 text;
  v_failure_baseline_material jsonb;
  v_failure_baseline_sha256 text;
  v_request_sha256 text;
  v_token text;
  v_token_sha256 text;
  v_proof_material jsonb;
  v_proof_sha256 text;
  v_completed_at timestamp with time zone;
  v_expires_at timestamp with time zone;
  v_target jsonb;
  v_snapshot jsonb;
  v_alias_result jsonb;
  v_batch_result jsonb;
  v_simulation_passed boolean := false;
  v_simulation_error jsonb;
  v_existing_id uuid;
  v_execution_count integer := 0;
  v_alias_audit_count integer := 0;
  v_derivative_child_count integer := 0;
  v_snapshot_drift_count integer := 0;
  v_active_rebuild_count integer := 0;
  v_http_count integer := 0;
  v_extraction_count integer := 0;
  v_embedding_count integer := 0;
  v_pending_count integer := 0;
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if nullif(v_actor_email, '') is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_EMAIL_REQUIRED',
      'status', 401,
      'message', 'Authenticated email claim is required'
    );
  end if;

  if p_request is not null and pg_column_size(p_request) > 67108864 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TOO_LARGE',
      'status', 413,
      'message', 'Protected preflight request exceeds 64 MiB'
    );
  end if;

  if jsonb_typeof(p_request) is distinct from 'object'
    or not (p_request ?& array[
      'schema_version',
      'request_id',
      'environment',
      'project_ref',
      'actor',
      'target_visibility',
      'plan',
      'freeze',
      'approval',
      'bindings',
      'expected',
      'derivative_targets'
    ])
    or exists (
      select 1
      from jsonb_object_keys(p_request) as request_key(key)
      where request_key.key <> all (array[
        'schema_version',
        'request_id',
        'environment',
        'project_ref',
        'actor',
        'target_visibility',
        'plan',
        'freeze',
        'approval',
        'bindings',
        'expected',
        'derivative_targets'
      ])
    )
    or p_request->>'schema_version' is distinct from v_schema_version
    or jsonb_typeof(p_request->'request_id') is distinct from 'string'
    or (p_request->>'request_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or p_request->>'environment' not in ('production', 'preview', 'local')
    or jsonb_typeof(p_request->'project_ref') is distinct from 'string'
    or nullif(btrim(p_request->>'project_ref'), '') is null
    or octet_length(p_request->>'project_ref') > 128
    or p_request->>'target_visibility' is distinct from 'owner_draft'
    or jsonb_typeof(p_request->'actor') is distinct from 'object'
    or jsonb_typeof(p_request->'plan') is distinct from 'object'
    or jsonb_typeof(p_request->'freeze') is distinct from 'object'
    or jsonb_typeof(p_request->'approval') is distinct from 'object'
    or jsonb_typeof(p_request->'bindings') is distinct from 'object'
    or jsonb_typeof(p_request->'expected') is distinct from 'object'
    or jsonb_typeof(p_request->'derivative_targets') is distinct from 'array' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_REQUEST',
      'status', 400,
      'message', 'Preflight request must match dataset-alias-execution-preflight.v1 exactly'
    );
  end if;

  v_request_id := (p_request->>'request_id')::uuid;
  v_environment := p_request->>'environment';
  v_project_ref := btrim(p_request->>'project_ref');
  v_request_actor := p_request->'actor';
  v_plan := p_request->'plan';
  v_freeze := p_request->'freeze';
  v_approval := p_request->'approval';
  v_bindings := p_request->'bindings';
  v_expected := p_request->'expected';
  v_input_targets := p_request->'derivative_targets';

  begin
    v_server_context := util.dataset_alias_execution_v2_server_context();
  exception
    when others then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_SERVER_CONTEXT_UNAVAILABLE',
        'status', 409,
        'message', 'Branch-local project identity could not be derived from trusted server configuration'
      );
  end;

  if v_environment is distinct from v_server_context->>'environment'
    or v_project_ref is distinct from v_server_context->>'project_ref' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_SERVER_CONTEXT_MISMATCH',
      'status', 409,
      'message', 'Requested environment and project_ref do not match the connected database'
    );
  end if;

  if not (v_request_actor ?& array['user_id', 'email'])
    or exists (
      select 1
      from jsonb_object_keys(v_request_actor) as actor_key(key)
      where actor_key.key <> all (array['user_id', 'email'])
    )
    or jsonb_typeof(v_request_actor->'user_id') is distinct from 'string'
    or v_request_actor->>'user_id' is distinct from v_actor::text
    or jsonb_typeof(v_request_actor->'email') is distinct from 'string'
    or lower(btrim(v_request_actor->>'email'))
      is distinct from lower(btrim(v_actor_email))
    or octet_length(v_request_actor->>'email') > 320 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_ACTOR_MISMATCH',
      'status', 403,
      'message', 'Preflight actor must match the authenticated user and email'
    );
  end if;

  if not (v_bindings ?& array[
      'plan_file_sha256',
      'freeze_file_sha256',
      'freeze_sha256',
      'approval_file_sha256',
      'approval_identity_sha256',
      'approval_text_sha256',
      'alias_plan_request_sha256',
      'before_hash_set_sha256',
      'desired_hash_set_sha256',
      'exchange_rewrite_set_sha256',
      'support_snapshot_set_sha256',
      'derivative_baseline_set_sha256',
      'derivative_target_set_sha256',
      'toolchain_evidence_sha256'
    ])
    or exists (
      select 1
      from jsonb_object_keys(v_bindings) as binding_key(key)
      where binding_key.key <> all (array[
        'plan_file_sha256',
        'freeze_file_sha256',
        'freeze_sha256',
        'approval_file_sha256',
        'approval_identity_sha256',
        'approval_text_sha256',
        'alias_plan_request_sha256',
        'before_hash_set_sha256',
        'desired_hash_set_sha256',
        'exchange_rewrite_set_sha256',
        'support_snapshot_set_sha256',
        'derivative_baseline_set_sha256',
        'derivative_target_set_sha256',
        'toolchain_evidence_sha256'
      ])
    )
    or exists (
      select 1
      from jsonb_each(v_bindings) as binding_item(key, value)
      where jsonb_typeof(binding_item.value) is distinct from 'string'
        or (binding_item.value #>> '{}') !~ '^[a-f0-9]{64}$'
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_BINDINGS',
      'status', 400,
      'message', 'All protected artifact bindings must be exact SHA-256 values'
    );
  end if;

  -- The protected expected block is the versioned plan's own claim block: the ten flat v1 counts plus
  -- the versioned text-action count, as JSON numbers on the external wire.
  if not (v_expected ?& array[
      'action_count',
      'batch_count',
      'exchange_count',
      'amount_field_count',
      'unrelated_exchange_count',
      'audit_count',
      'flowproperty_count',
      'flow_count',
      'process_count',
      'derivative_target_count',
      'text_action_count'
    ])
    or exists (
      select 1
      from jsonb_object_keys(v_expected) as expected_key(key)
      where expected_key.key <> all (array[
        'action_count',
        'batch_count',
        'exchange_count',
        'amount_field_count',
        'unrelated_exchange_count',
        'audit_count',
        'flowproperty_count',
        'flow_count',
        'process_count',
        'derivative_target_count',
        'text_action_count'
      ])
    )
    or exists (
      select 1
      from jsonb_each(v_expected) as expected_item(key, value)
      where jsonb_typeof(expected_item.value) is distinct from 'number'
    )
    or v_expected is distinct from (v_plan->'expected') then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_COUNTS',
      'status', 400,
      'message', 'Protected profile requires the plan-derived expected counts, and nothing else'
    );
  end if;

  if jsonb_array_length(v_input_targets) <> (v_plan #>> '{expected,derivative_target_count}')::integer
    or exists (
      select 1
      from jsonb_array_elements(v_input_targets) as target_item(value)
      where jsonb_typeof(target_item.value) is distinct from 'object'
        or not (target_item.value ?& array[
          'table',
          'id',
          'version',
          'user_id',
          'state_code',
          'baseline_snapshot_sha256'
        ])
        or exists (
          select 1
          from jsonb_object_keys(target_item.value) as target_key(key)
          where target_key.key <> all (array[
            'table',
            'id',
            'version',
            'user_id',
            'state_code',
            'baseline_snapshot_sha256'
          ])
        )
        or target_item.value->>'table' not in ('flows', 'processes')
        or jsonb_typeof(target_item.value->'table') is distinct from 'string'
        or jsonb_typeof(target_item.value->'id') is distinct from 'string'
        or (target_item.value->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or jsonb_typeof(target_item.value->'version') is distinct from 'string'
        or (target_item.value->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
        or jsonb_typeof(target_item.value->'user_id') is distinct from 'string'
        or target_item.value->>'user_id' is distinct from v_actor::text
        or jsonb_typeof(target_item.value->'state_code') is distinct from 'number'
        or target_item.value->>'state_code' is distinct from '0'
        or jsonb_typeof(target_item.value->'baseline_snapshot_sha256')
          is distinct from 'string'
        or (target_item.value->>'baseline_snapshot_sha256') !~ '^[a-f0-9]{64}$'
    )
    or (
      select count(*)
      from jsonb_array_elements(v_input_targets) as target_item(value)
      where target_item.value->>'table' = 'flows'
    ) <> (select count(*) from jsonb_array_elements(v_plan->'actions') as action_item(value) where action_item.value->>'table' = 'flows')
    or (
      select count(*)
      from jsonb_array_elements(v_input_targets) as target_item(value)
      where target_item.value->>'table' = 'processes'
    ) <> (select count(*) from jsonb_array_elements(v_plan->'actions') as action_item(value) where action_item.value->>'table' = 'processes')
    or (
      select count(distinct (
        target_item.value->>'table',
        target_item.value->>'id',
        target_item.value->>'version'
      ))
      from jsonb_array_elements(v_input_targets) as target_item(value)
    ) <> (v_plan #>> '{expected,derivative_target_count}')::integer then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_TARGETS',
      'status', 400,
      'message', 'Derivative targets must be the declared unique flows and processes owned by the actor at state_code 0'
    );
  end if;

  select jsonb_agg(target_item.value order by
    target_item.value->>'table',
    target_item.value->>'id',
    target_item.value->>'version'
  )
  into v_sorted_targets
  from jsonb_array_elements(v_input_targets) as target_item(value);

  if v_input_targets is distinct from v_sorted_targets then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TARGET_ORDER',
      'status', 400,
      'message', 'Derivative targets must use stable table/id/version order'
    );
  end if;

  if v_plan->>'schema_version' is distinct from 'dataset-alias-plan.v2'
    or v_plan->>'target_visibility' is distinct from 'owner_draft'
    or (v_plan->>'plan_sha256') !~ '^[a-f0-9]{64}$'
    -- The claimed plan digest is the producer's canonical self-hash of the plan document minus its
    -- own binding; admission verifies it before anything downstream reuses the label.
    or util.dataset_alias_execution_v2_artifact_sha256(v_plan - 'plan_sha256')
      is distinct from (v_plan->>'plan_sha256')
    then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_INVALID_PLAN',
      'status', 400,
      'message', 'Protected preflight requires one owner-draft dataset-alias-plan.v1 request'
    );
  end if;

  v_plan_sha256 := v_plan->>'plan_sha256';
  v_operation_id := v_plan->>'plan_sha256';

  select jsonb_agg(
    jsonb_build_object(
      'table', target_item.value->>'table',
      'id', target_item.value->>'id',
      'version', target_item.value->>'version',
      'expected_json_ordered_sha256',
        util.dataset_alias_execution_v2_sha256(
          (action_item.value->'desired_json_ordered')::text
        ),
      'baseline_snapshot_sha256',
        target_item.value->>'baseline_snapshot_sha256'
    ) order by
      target_item.value->>'table',
      target_item.value->>'id',
      target_item.value->>'version'
  )
  into v_targets
  from jsonb_array_elements(v_plan->'actions') as action_item(value)
  join jsonb_array_elements(v_input_targets) as target_item(value)
    on target_item.value->>'table' = action_item.value->>'table'
   and target_item.value->>'id' = action_item.value->>'id'
   and target_item.value->>'version' = action_item.value->>'version'
  where action_item.value->>'table' in ('flows', 'processes');

  if jsonb_typeof(v_targets) is distinct from 'array'
    or jsonb_array_length(v_targets) <> (v_plan #>> '{expected,derivative_target_count}')::integer then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TARGET_PLAN_MISMATCH',
      'status', 409,
      'message', 'Derivative target identities must exactly match the declared flow/process plan actions'
    );
  end if;

  -- The reviewed producer defines the plan request hash as the plan document with its own
  -- `plan_sha256` binding removed (the plan's self-digest is exactly that value), the derivative
  -- target set as the sorted `table:id@version` identity strings and the baseline set as the
  -- sorted baseline digests. All three are recomputed here with the same canonical artifact
  -- algorithm the producer uses, so neither side can drift without the other refusing.
  v_alias_plan_request_sha256 :=
    util.dataset_alias_execution_v2_artifact_sha256(v_plan - 'plan_sha256');

  select util.dataset_alias_execution_v2_artifact_sha256(
    jsonb_agg(target_identity order by target_identity collate "C")
  )
  into v_derivative_target_set_sha256
  from (
    select (target_item.value->>'table') || ':' || (target_item.value->>'id') || '@'
      || (target_item.value->>'version') as target_identity
    from jsonb_array_elements(v_input_targets) as target_item(value)
  ) as target_identities;

  select util.dataset_alias_execution_v2_artifact_sha256(
    jsonb_agg(baseline order by baseline collate "C")
  )
  into v_derivative_baseline_set_sha256
  from (
    select target_item.value->>'baseline_snapshot_sha256' as baseline
    from jsonb_array_elements(v_input_targets) as target_item(value)
  ) as target_baselines;

  if v_bindings->>'alias_plan_request_sha256'
      is distinct from v_alias_plan_request_sha256
    or v_bindings->>'derivative_target_set_sha256'
      is distinct from v_derivative_target_set_sha256
    or v_bindings->>'derivative_baseline_set_sha256'
      is distinct from v_derivative_baseline_set_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_ARTIFACT_SET_MISMATCH',
      'status', 409,
      'message', 'The approved alias request or derivative target sets do not match server recomputation'
    );
  end if;

  v_expected_freeze := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-freeze.v2',
    'environment', v_environment,
    'project_ref', v_project_ref,
    'account', v_request_actor,
    'target_visibility', 'owner_draft',
    -- The freeze binds the plan file, the plan digest and the plan's own versioned content. The
    -- internal operation identity is the plan digest and stays server-side: the approved envelope
    -- carries no separate operation id.
    'plan', jsonb_build_object(
      'plan_file_sha256', v_bindings->>'plan_file_sha256',
      'plan_sha256', v_plan_sha256
    ),
    'target_snapshots', v_plan->'target_snapshots',
    'source_evidence', v_plan->'source_evidence',
    'sets', jsonb_build_object(
      'alias_plan_request_sha256',
        v_bindings->>'alias_plan_request_sha256',
      'before_hash_set_sha256',
        v_bindings->>'before_hash_set_sha256',
      'desired_hash_set_sha256',
        v_bindings->>'desired_hash_set_sha256',
      'exchange_rewrite_set_sha256',
        v_bindings->>'exchange_rewrite_set_sha256',
      'support_snapshot_set_sha256',
        v_bindings->>'support_snapshot_set_sha256',
      'derivative_baseline_set_sha256',
        v_bindings->>'derivative_baseline_set_sha256',
      'derivative_target_set_sha256',
        v_bindings->>'derivative_target_set_sha256',
      'toolchain_evidence_sha256',
        v_bindings->>'toolchain_evidence_sha256'
    ),
    'expected', v_expected,
    'derivative_targets', v_input_targets,
    'policy', jsonb_build_object(
      'state_code_changes', 0,
      'save_draft', 0,
      'deletes', 0,
      'rebuild_derivatives', 0,
      'unitgroup_actions', 0,
      'person_distance_actions', 0,
      'max_admit_posts', 1,
      'automatic_retry', false
    ),
    'freeze_sha256', v_bindings->>'freeze_sha256'
  );

  if v_freeze is distinct from v_expected_freeze
    or util.dataset_alias_execution_v2_artifact_sha256(
      v_freeze - 'freeze_sha256'
    ) is distinct from v_bindings->>'freeze_sha256' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_FREEZE_MISMATCH',
      'status', 409,
      'message', 'The production freeze envelope or canonical freeze hash is invalid'
    );
  end if;

  begin
    perform (v_approval->>'approved_at_utc')::timestamp with time zone;
  exception
    when others then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_PREFLIGHT_APPROVAL_MISMATCH',
        'status', 409,
        'message', 'The exact approval timestamp is invalid'
      );
  end;

  v_expected_approval := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-approval.v2',
    'approved_at_utc', v_approval->>'approved_at_utc',
    'environment', v_environment,
    'project_ref', v_project_ref,
    'account', v_request_actor,
    'target_visibility', 'owner_draft',
    'plan_sha256', v_plan_sha256,
    'plan_file_sha256', v_bindings->>'plan_file_sha256',
    'freeze_file_sha256', v_bindings->>'freeze_file_sha256',
    'freeze_sha256', v_bindings->>'freeze_sha256',
    'approval_text_sha256', v_bindings->>'approval_text_sha256',
    'max_admit_posts', 1,
    'automatic_retry', false,
    'approval_identity_sha256', v_bindings->>'approval_identity_sha256'
  );

  if v_approval is distinct from v_expected_approval
    or util.dataset_alias_execution_v2_artifact_sha256(
      v_approval - 'approval_identity_sha256'
    ) is distinct from v_bindings->>'approval_identity_sha256' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_APPROVAL_MISMATCH',
      'status', 409,
      'message', 'The approval identity does not bind this exact production freeze and alias request'
    );
  end if;

  select preflight.id
  into v_existing_id
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = v_request_id
     or (
       preflight.actor_user_id = v_actor
       and preflight.approval_identity_sha256 =
         v_bindings->>'approval_identity_sha256'
     )
  limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_APPROVAL_ALREADY_USED',
      'status', 409,
      'message', 'This request ID or exact approval identity already created a protected preflight; freeze and approve again'
    );
  end if;

  for v_target in
    select target_item.value
    from jsonb_array_elements(v_targets) as target_item(value)
  loop
    begin
      v_snapshot := util.dataset_derivative_rebuild_snapshot(
        v_target->>'table',
        (v_target->>'id')::uuid,
        v_target->>'version'
      );
    exception
      when others then
        v_snapshot := null;
    end;

    if v_snapshot is null
      or v_snapshot->>'user_id' is distinct from v_actor::text
      or v_snapshot->>'state_code' is distinct from '0'
      or v_snapshot->>'json_sha256' is distinct from v_snapshot->>'json_ordered_sha256'
      or v_snapshot->>'snapshot_sha256'
        is distinct from v_target->>'baseline_snapshot_sha256' then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_PREFLIGHT_BASELINE_DRIFT',
        'status', 409,
        'message', 'A derivative target no longer matches its owner-draft baseline snapshot'
      );
    end if;
  end loop;

  v_plan_request_sha256 := util.dataset_alias_execution_v2_sha256(v_plan::text);
  v_bindings_sha256 := util.dataset_alias_execution_v2_sha256(v_bindings::text);
  v_expected_sha256 := util.dataset_alias_execution_v2_sha256(v_expected::text);
  v_targets_sha256 := util.dataset_alias_execution_v2_sha256(v_targets::text);
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', failure.id,
        'queue_name', failure.queue_name,
        'msg_id', failure.msg_id,
        'read_count', failure.read_count,
        'reason', failure.reason,
        'message', failure.message,
        'failed_at', failure.failed_at
      ) order by failure.id
    ),
    '[]'::jsonb
  )
  into v_failure_baseline_material
  from util.embedding_job_failures as failure
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where failure.message->>'table' = target_item.value->>'table'
      and failure.message->>'id' = target_item.value->>'id'
      and btrim(failure.message->>'version') = target_item.value->>'version'
  );
  v_failure_baseline_sha256 :=
    util.dataset_alias_execution_v2_sha256(v_failure_baseline_material::text);
  v_request_sha256 := util.dataset_alias_execution_v2_sha256(p_request::text);

  -- The simulation creates all normal alias writes, audits, webhook work, and
  -- derivative fences inside this exception block.  The controlled P0002
  -- exception always rolls those effects back before a durable token exists.
  begin
    v_alias_result := private.cmd_dataset_alias_plan_v2_guarded(v_plan);
    if coalesce((v_alias_result->>'ok')::boolean, false) is not true
      or coalesce((v_alias_result->>'idempotent_replay')::boolean, true)
      or (v_alias_result #>> '{counts,action_count}') is distinct from (v_plan #>> '{expected,action_count}')
      or (v_alias_result #>> '{counts,exchange_count}') is distinct from (v_plan #>> '{expected,exchange_count}') then
      v_simulation_error := jsonb_build_object(
        'phase', 'alias',
        'result', coalesce(v_alias_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected alias simulation rejected';
    end if;

    v_batch_result := util.admit_dataset_alias_v2_derivative_chunks(
      v_actor,
      v_request_id,
      v_plan_sha256,
      v_operation_id,
      'PROTECTED_ALIAS_DERIVATIVE_CLOSURE',
      v_targets
    );

    if coalesce((v_batch_result->>'ok')::boolean, false) is not true
      or (v_batch_result->>'target_count')::integer is distinct from (v_plan #>> '{expected,derivative_target_count}')::integer
      or (v_batch_result->>'flow_count')::integer is distinct from (select count(*) from jsonb_array_elements(v_targets) as target where target->>'table' = 'flows')
      or (v_batch_result->>'process_count')::integer is distinct from (select count(*) from jsonb_array_elements(v_targets) as target where target->>'table' = 'processes') then
      v_simulation_error := jsonb_build_object(
        'phase', 'derivative_batch',
        'result', coalesce(v_batch_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected derivative batch simulation rejected';
    end if;

    raise exception using
      errcode = 'P0002',
      message = 'Protected execution preflight simulation rollback';
  exception
    when sqlstate 'P0002' then
      v_simulation_passed := true;
    when others then
      v_simulation_passed := false;
      if v_simulation_error is null then
        v_simulation_error := jsonb_build_object(
          'phase', 'unexpected',
          'sqlstate', sqlstate,
          'message', sqlerrm
        );
      end if;
  end;

  if not v_simulation_passed then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_SIMULATION_FAILED',
      'status', 409,
      'message', 'The exact protected plan failed rollback-only server simulation',
      'evidence', v_simulation_error
    );
  end if;

  select count(*)::integer
  into v_execution_count
  from util.dataset_alias_execution_v2_requests as request
  where request.actor_user_id = v_actor
    and request.approval_identity_sha256 =
      v_bindings->>'approval_identity_sha256';

  select count(*)::integer
  into v_alias_audit_count
  from private.command_audit_log as audit
  where audit.actor_user_id = v_actor
    and (
      (
        audit.command = 'cmd_dataset_alias_batch_v2_guarded'
        and audit.payload->>'plan_sha256' = v_plan_sha256
        and audit.payload->>'operation_id' = v_operation_id
      )
      or (
        audit.command = 'cmd_dataset_alias_plan_v2_guarded'
        and audit.payload->>'plan_request_sha256' = v_plan_request_sha256
      )
    );

  select count(*)::integer
  into v_derivative_child_count
  from util.dataset_derivative_rebuild_requests as request
  where request.actor_user_id = v_actor
    and request.batch_id = v_request_id;

  for v_target in
    select target_item.value
    from jsonb_array_elements(v_targets) as target_item(value)
  loop
    begin
      v_snapshot := util.dataset_derivative_rebuild_snapshot(
        v_target->>'table',
        (v_target->>'id')::uuid,
        v_target->>'version'
      );
    exception
      when others then
        v_snapshot := null;
    end;

    if v_snapshot is null
      or v_snapshot->>'user_id' is distinct from v_actor::text
      or v_snapshot->>'state_code' is distinct from '0'
      or v_snapshot->>'snapshot_sha256'
        is distinct from v_target->>'baseline_snapshot_sha256' then
      v_snapshot_drift_count := v_snapshot_drift_count + 1;
    end if;
  end loop;

  select count(*)::integer
  into v_active_rebuild_count
  from util.dataset_derivative_rebuild_requests as request
  where request.status not in ('completed', 'stale', 'failed')
    and exists (
      select 1
      from jsonb_array_elements(v_targets) as target_item(value)
      where request.target_table = target_item.value->>'table'
        and request.target_id = (target_item.value->>'id')::uuid
        and request.target_version = target_item.value->>'version'
    );

  select count(*)::integer
  into v_http_count
  from net.http_request_queue as request
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where util.dataset_derivative_rebuild_http_body_matches(
      request.body,
      target_item.value->>'table',
      (target_item.value->>'id')::uuid,
      target_item.value->>'version'
    )
  );

  select count(*)::integer
  into v_extraction_count
  from pgmq.q_dataset_extraction_jobs as job
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where job.message->>'schema' = 'public'
      and job.message->>'table' = target_item.value->>'table'
      and job.message->>'id' = target_item.value->>'id'
      and btrim(job.message->>'version') = target_item.value->>'version'
  );

  select count(*)::integer
  into v_embedding_count
  from pgmq.q_embedding_jobs as job
  where exists (
    select 1
    from jsonb_array_elements(v_targets) as target_item(value)
    where job.message->>'schema' = 'public'
      and job.message->>'table' = target_item.value->>'table'
      and job.message->>'id' = target_item.value->>'id'
      and btrim(job.message->>'version') = target_item.value->>'version'
      and job.message->>'embeddingColumn' = 'embedding_ft'
  );

  select count(*)::integer
  into v_pending_count
  from util.pending_embedding_jobs as pending
  where pending.schema_name = 'public'
    and pending.embedding_column = 'embedding_ft'
    and pending.status = 'pending'
    and exists (
      select 1
      from jsonb_array_elements(v_targets) as target_item(value)
      where pending.table_name = target_item.value->>'table'
        and pending.record_id = target_item.value->>'id'
        and btrim(pending.record_version) = target_item.value->>'version'
    );

  if v_execution_count <> 0
    or v_alias_audit_count <> 0
    or v_derivative_child_count <> 0
    or v_snapshot_drift_count <> 0
    or v_active_rebuild_count <> 0
    or v_http_count <> 0
    or v_extraction_count <> 0
    or v_embedding_count <> 0
    or v_pending_count <> 0 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_NOT_QUIESCENT',
      'status', 409,
      'message', 'The exact approval identity, targets, or derivative queues are not unused and quiescent'
    );
  end if;

  v_primary_gate_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-material.v2',
    'gate', 'primary_support_plan',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'plan_request_sha256', v_plan_request_sha256,
    'derivative_targets_sha256', v_targets_sha256,
    'plan_rows', jsonb_array_length(v_plan->'actions'),
    'plan_exchanges', (v_plan #>> '{expected,exchange_count}')::integer,
    'alias_audits', (v_plan #>> '{expected,audit_count}')::integer,
    'derivative_targets', jsonb_array_length(v_input_targets),
    'rollback_simulation_passed', true
  );
  v_unused_gate_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-material.v2',
    'gate', 'execution_unused',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'plan_request_sha256', v_plan_request_sha256,
    'sealed_execution_rows', v_execution_count,
    'alias_audit_rows', v_alias_audit_count,
    'derivative_child_rows', v_derivative_child_count
  );
  v_quiescence_gate_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-material.v2',
    'gate', 'derivative_quiescence',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'derivative_targets_sha256', v_targets_sha256,
    'snapshot_drift_count', v_snapshot_drift_count,
    'active_rebuild_count', v_active_rebuild_count,
    'http_request_count', v_http_count,
    'extraction_job_count', v_extraction_count,
    'embedding_job_count', v_embedding_count,
    'pending_embedding_count', v_pending_count,
    'failure_baseline_sha256', v_failure_baseline_sha256
  );
  v_gate_expectations := jsonb_build_object(
    'primary_support_plan_sha256',
      util.dataset_alias_execution_v2_sha256(v_primary_gate_material::text),
    'execution_unused_sha256',
      util.dataset_alias_execution_v2_sha256(v_unused_gate_material::text),
    'derivative_quiescence_sha256',
      util.dataset_alias_execution_v2_sha256(v_quiescence_gate_material::text)
  );
  v_gate_expectations_sha256 :=
    util.dataset_alias_execution_v2_sha256(v_gate_expectations::text);

  select preflight.id
  into v_existing_id
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = v_request_id
     or (
       preflight.actor_user_id = v_actor
       and preflight.preflight_request_sha256 = v_request_sha256
     )
  limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_ALREADY_EXISTS',
      'status', 409,
      'message', 'A preflight request ID or exact request was already used; tokens are never replayed'
    );
  end if;

  v_completed_at := pg_catalog.clock_timestamp();
  v_expires_at := v_completed_at + interval '180 seconds';
  v_token := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
  v_token_sha256 := util.dataset_alias_execution_v2_sha256(v_token);
  v_proof_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-preflight-proof.v2',
    'request_id', v_request_id,
    'actor_user_id', v_actor,
    'environment', v_environment,
    'project_ref', v_project_ref,
    'server_context_sha256',
      util.dataset_alias_execution_v2_sha256(v_server_context::text),
    'plan_sha256', v_plan_sha256,
    'operation_id', v_operation_id,
    'alias_plan_request_sha256', v_alias_plan_request_sha256,
    'freeze_sha256', v_bindings->>'freeze_sha256',
    'approval_identity_sha256',
      v_bindings->>'approval_identity_sha256',
    'plan_request_sha256', v_plan_request_sha256,
    'bindings_sha256', v_bindings_sha256,
    'expected_sha256', v_expected_sha256,
    'derivative_targets_sha256', v_targets_sha256,
    'gate_expectations', v_gate_expectations,
    'gate_expectations_sha256', v_gate_expectations_sha256,
    'failure_baseline_sha256', v_failure_baseline_sha256,
    'preflight_request_sha256', v_request_sha256,
    'completed_at', v_completed_at,
    'expires_at', v_expires_at
  );
  v_proof_sha256 := util.dataset_alias_execution_v2_sha256(v_proof_material::text);

  insert into util.dataset_alias_execution_v2_preflights (
    id,
    actor_user_id,
    actor_email,
    environment,
    project_ref,
    target_visibility,
    plan,
    freeze_envelope,
    approval_envelope,
    plan_sha256,
    operation_id,
    plan_request_sha256,
    bindings,
    bindings_sha256,
    expected,
    expected_sha256,
    derivative_targets,
    derivative_targets_sha256,
    gate_expectations,
    gate_expectations_sha256,
    failure_baseline_sha256,
    preflight_request_sha256,
    preflight_proof_sha256,
    freeze_sha256,
    approval_identity_sha256,
    token_sha256,
    completed_at,
    expires_at
  ) values (
    v_request_id,
    v_actor,
    lower(btrim(v_actor_email)),
    v_environment,
    v_project_ref,
    'owner_draft',
    v_plan,
    v_freeze,
    v_approval,
    v_plan_sha256,
    v_operation_id,
    v_plan_request_sha256,
    v_bindings,
    v_bindings_sha256,
    v_expected,
    v_expected_sha256,
    v_targets,
    v_targets_sha256,
    v_gate_expectations,
    v_gate_expectations_sha256,
    v_failure_baseline_sha256,
    v_request_sha256,
    v_proof_sha256,
    v_bindings->>'freeze_sha256',
    v_bindings->>'approval_identity_sha256',
    v_token_sha256,
    v_completed_at,
    v_expires_at
  );

  return v_proof_material || jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_preflight_v2_guarded',
    'preflight_token', v_token,
    'preflight_proof_sha256', v_proof_sha256,
    'simulation', jsonb_build_object(
      'plan_rows', jsonb_array_length(v_plan->'actions'),
      'plan_exchanges', (v_plan #>> '{expected,exchange_count}')::integer,
      'alias_audits', (v_plan #>> '{expected,audit_count}')::integer,
      'derivative_targets', jsonb_array_length(v_input_targets),
      'rolled_back', true
    )
  );
exception
  when lock_not_available then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_LOCK_BUSY',
      'status', 409,
      'message', 'Protected preflight could not acquire its bounded locks'
    );
  when unique_violation then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_CONCURRENT_CONFLICT',
      'status', 409,
      'message', 'A concurrent preflight consumed the same request identity'
    );
end;
$$;

alter function api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)
  owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)
  to authenticated;

comment on function api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb) is
  'Rollback-only server validation for the exact owner-draft 52-row/59-exchange alias plan plus its sorted 23-flow/27-process derivative closure. A successful call persists one non-replayable token that expires 180 seconds after simulation completes.';

create or replace function api.cmd_dataset_alias_execution_gate_v2_guarded(
  p_request_id uuid,
  p_preflight_token text,
  p_gate_name text
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set statement_timeout = '55s'
as $$
declare
  v_actor uuid := auth.uid();
  v_preflight util.dataset_alias_execution_v2_preflights%rowtype;
  v_expected_name text;
  v_expected_sha256 text;
  v_material jsonb;
  v_observed_sha256 text;
  v_receipt_material jsonb;
  v_receipt_sha256 text;
  v_captured_at timestamp with time zone;
  v_alias_result jsonb;
  v_batch_result jsonb;
  v_simulation_passed boolean := false;
  v_execution_count integer := 0;
  v_alias_audit_count integer := 0;
  v_derivative_child_count integer := 0;
  v_snapshot_drift_count integer := 0;
  v_active_rebuild_count integer := 0;
  v_http_count integer := 0;
  v_extraction_count integer := 0;
  v_embedding_count integer := 0;
  v_pending_count integer := 0;
  v_failure_material jsonb;
  v_failure_sha256 text;
  v_target jsonb;
  v_snapshot jsonb;
  v_existing_gate_count integer := 0;
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_request_id is null
    or p_preflight_token is null
    or p_preflight_token !~ '^[a-f0-9]{64}$'
    or p_gate_name not in (
      'primary_support_plan',
      'execution_unused',
      'derivative_quiescence'
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_INVALID_REQUEST',
      'status', 400,
      'message', 'Exact request ID, preflight token, and known gate name are required'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor::text || ':' || p_request_id::text || ':' || p_gate_name,
      0
    )
  );

  select preflight.*
  into v_preflight
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = p_request_id
    and preflight.actor_user_id = v_actor
  for update;

  if v_preflight.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_NOT_FOUND',
      'status', 404,
      'message', 'No actor-owned protected preflight exists for this request ID'
    );
  end if;

  if v_preflight.consumed_at is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ATTEMPT_ALREADY_CONSUMED',
      'status', 409,
      'message', 'Admission already consumed this preflight; gates are read-only history now'
    );
  end if;

  if pg_catalog.clock_timestamp() > v_preflight.expires_at then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_EXPIRED',
      'status', 409,
      'message', 'The 180-second server preflight window expired before all gates completed'
    );
  end if;

  if util.dataset_alias_execution_v2_sha256(p_preflight_token)
      is distinct from v_preflight.token_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_TOKEN_MISMATCH',
      'status', 403,
      'message', 'Preflight token does not match the durable server record'
    );
  end if;

  if exists (
    select 1
    from util.dataset_alias_execution_v2_gate_receipts as receipt
    where receipt.preflight_id = p_request_id
      and receipt.gate_name = p_gate_name
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_ALREADY_CAPTURED',
      'status', 409,
      'message', 'Each live gate is captured at most once; freeze again after a lost gate response'
    );
  end if;

  select count(*)::integer
  into v_existing_gate_count
  from util.dataset_alias_execution_v2_gate_receipts as receipt
  where receipt.preflight_id = p_request_id
    and receipt.actor_user_id = v_actor;

  if (
      p_gate_name = 'primary_support_plan'
      and v_existing_gate_count <> 0
    ) or (
      p_gate_name = 'execution_unused'
      and (
        v_existing_gate_count <> 1
        or not exists (
          select 1
          from util.dataset_alias_execution_v2_gate_receipts as receipt
          where receipt.preflight_id = p_request_id
            and receipt.actor_user_id = v_actor
            and receipt.gate_name = 'primary_support_plan'
        )
      )
    ) or (
      p_gate_name = 'derivative_quiescence'
      and (
        v_existing_gate_count <> 2
        or not exists (
          select 1
          from util.dataset_alias_execution_v2_gate_receipts as receipt
          where receipt.preflight_id = p_request_id
            and receipt.actor_user_id = v_actor
            and receipt.gate_name = 'primary_support_plan'
        )
        or not exists (
          select 1
          from util.dataset_alias_execution_v2_gate_receipts as receipt
          where receipt.preflight_id = p_request_id
            and receipt.actor_user_id = v_actor
            and receipt.gate_name = 'execution_unused'
        )
      )
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_ORDER_MISMATCH',
      'status', 409,
      'message', 'Live gates must be captured exactly once in primary/support, execution-unused, derivative-quiescence order'
    );
  end if;

  v_expected_name := case p_gate_name
    when 'primary_support_plan' then 'primary_support_plan_sha256'
    when 'execution_unused' then 'execution_unused_sha256'
    when 'derivative_quiescence' then 'derivative_quiescence_sha256'
  end;
  v_expected_sha256 := v_preflight.gate_expectations->>v_expected_name;

  if p_gate_name = 'primary_support_plan' then
    begin
      v_alias_result := private.cmd_dataset_alias_plan_v2_guarded(v_preflight.plan);
      if coalesce((v_alias_result->>'ok')::boolean, false) is not true
        or coalesce((v_alias_result->>'idempotent_replay')::boolean, true)
        or (v_alias_result #>> '{counts,action_count}') is distinct from (v_preflight.plan #>> '{expected,action_count}')
        or (v_alias_result #>> '{counts,exchange_count}') is distinct from (v_preflight.plan #>> '{expected,exchange_count}') then
        raise exception using
          errcode = 'P0001',
          message = 'Primary/support simulation rejected';
      end if;

      v_batch_result := util.admit_dataset_alias_v2_derivative_chunks(
        v_actor,
        p_request_id,
        v_preflight.plan_sha256,
        v_preflight.operation_id,
        'PROTECTED_ALIAS_DERIVATIVE_CLOSURE',
        v_preflight.derivative_targets
      );

      if coalesce((v_batch_result->>'ok')::boolean, false) is not true
        or (v_batch_result->>'target_count')::integer
          is distinct from (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
        or coalesce((v_batch_result->>'flow_count')::integer, 0)
          is distinct from (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'flows')
        or coalesce((v_batch_result->>'process_count')::integer, 0)
          is distinct from (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'processes') then
        raise exception using
          errcode = 'P0001',
          message = 'Derivative batch simulation rejected';
      end if;

      raise exception using
        errcode = 'P0002',
        message = 'Protected primary/support gate rollback';
    exception
      when sqlstate 'P0002' then
        v_simulation_passed := true;
      when others then
        v_simulation_passed := false;
    end;

    if not v_simulation_passed then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_PRIMARY_SUPPORT_GATE_FAILED',
        'status', 409,
        'message', 'Primary/support plan drifted after preflight'
      );
    end if;

    v_material := jsonb_build_object(
      'schema_version', 'dataset-alias-execution-gate-material.v2',
      'gate', p_gate_name,
      'request_id', p_request_id,
      'actor_user_id', v_actor,
      'plan_request_sha256', v_preflight.plan_request_sha256,
      'derivative_targets_sha256', v_preflight.derivative_targets_sha256,
      'plan_rows', jsonb_array_length(v_preflight.plan->'actions'),
      'plan_exchanges', (v_preflight.plan #>> '{expected,exchange_count}')::integer,
      'alias_audits', (v_preflight.plan #>> '{expected,audit_count}')::integer,
      'derivative_targets', jsonb_array_length(v_preflight.derivative_targets),
      'rollback_simulation_passed', true
    );
  elsif p_gate_name = 'execution_unused' then
    select count(*)::integer
    into v_execution_count
    from util.dataset_alias_execution_v2_requests as request
    where request.actor_user_id = v_actor
      and request.approval_identity_sha256 =
        v_preflight.bindings->>'approval_identity_sha256';

    select count(*)::integer
    into v_alias_audit_count
    from private.command_audit_log as audit
    where audit.actor_user_id = v_actor
      and (
        (
          audit.command = 'cmd_dataset_alias_batch_v2_guarded'
          and audit.payload->>'plan_sha256' = v_preflight.plan_sha256
          and audit.payload->>'operation_id' = v_preflight.operation_id
        )
        or (
          audit.command = 'cmd_dataset_alias_plan_v2_guarded'
          and audit.payload->>'plan_request_sha256' =
            v_preflight.plan_request_sha256
        )
      );

    select count(*)::integer
    into v_derivative_child_count
    from util.dataset_derivative_rebuild_requests as request
    where request.actor_user_id = v_actor
      and request.batch_id = p_request_id;

    if v_execution_count <> 0
      or v_alias_audit_count <> 0
      or v_derivative_child_count <> 0 then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_UNUSED_GATE_FAILED',
        'status', 409,
        'message', 'The sealed execution identity already has durable effects'
      );
    end if;

    v_material := jsonb_build_object(
      'schema_version', 'dataset-alias-execution-gate-material.v2',
      'gate', p_gate_name,
      'request_id', p_request_id,
      'actor_user_id', v_actor,
      'plan_request_sha256', v_preflight.plan_request_sha256,
      'sealed_execution_rows', v_execution_count,
      'alias_audit_rows', v_alias_audit_count,
      'derivative_child_rows', v_derivative_child_count
    );
  else
    for v_target in
      select target_item.value
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
    loop
      begin
        v_snapshot := util.dataset_derivative_rebuild_snapshot(
          v_target->>'table',
          (v_target->>'id')::uuid,
          v_target->>'version'
        );
      exception
        when others then
          v_snapshot := null;
      end;

      if v_snapshot is null
        or v_snapshot->>'user_id' is distinct from v_actor::text
        or v_snapshot->>'state_code' is distinct from '0'
        or v_snapshot->>'snapshot_sha256'
          is distinct from v_target->>'baseline_snapshot_sha256' then
        v_snapshot_drift_count := v_snapshot_drift_count + 1;
      end if;
    end loop;

    select count(*)::integer
    into v_active_rebuild_count
    from util.dataset_derivative_rebuild_requests as request
    where request.status not in ('completed', 'stale', 'failed')
      and exists (
        select 1
        from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
        where request.target_table = target_item.value->>'table'
          and request.target_id = (target_item.value->>'id')::uuid
          and request.target_version = target_item.value->>'version'
      );

    select count(*)::integer
    into v_http_count
    from net.http_request_queue as request
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where util.dataset_derivative_rebuild_http_body_matches(
        request.body,
        target_item.value->>'table',
        (target_item.value->>'id')::uuid,
        target_item.value->>'version'
      )
    );

    select count(*)::integer
    into v_extraction_count
    from pgmq.q_dataset_extraction_jobs as job
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where job.message->>'schema' = 'public'
        and job.message->>'table' = target_item.value->>'table'
        and job.message->>'id' = target_item.value->>'id'
        and btrim(job.message->>'version') = target_item.value->>'version'
    );

    select count(*)::integer
    into v_embedding_count
    from pgmq.q_embedding_jobs as job
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where job.message->>'schema' = 'public'
        and job.message->>'table' = target_item.value->>'table'
        and job.message->>'id' = target_item.value->>'id'
        and btrim(job.message->>'version') = target_item.value->>'version'
        and job.message->>'embeddingColumn' = 'embedding_ft'
    );

    select count(*)::integer
    into v_pending_count
    from util.pending_embedding_jobs as pending
    where pending.schema_name = 'public'
      and pending.embedding_column = 'embedding_ft'
      and pending.status = 'pending'
      and exists (
        select 1
        from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
        where pending.table_name = target_item.value->>'table'
          and pending.record_id = target_item.value->>'id'
          and btrim(pending.record_version) = target_item.value->>'version'
      );

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', failure.id,
          'queue_name', failure.queue_name,
          'msg_id', failure.msg_id,
          'read_count', failure.read_count,
          'reason', failure.reason,
          'message', failure.message,
          'failed_at', failure.failed_at
        ) order by failure.id
      ),
      '[]'::jsonb
    )
    into v_failure_material
    from util.embedding_job_failures as failure
    where exists (
      select 1
      from jsonb_array_elements(v_preflight.derivative_targets) as target_item(value)
      where failure.message->>'table' = target_item.value->>'table'
        and failure.message->>'id' = target_item.value->>'id'
        and btrim(failure.message->>'version') = target_item.value->>'version'
    );
    v_failure_sha256 :=
      util.dataset_alias_execution_v2_sha256(v_failure_material::text);

    if v_snapshot_drift_count <> 0
      or v_active_rebuild_count <> 0
      or v_http_count <> 0
      or v_extraction_count <> 0
      or v_embedding_count <> 0
      or v_pending_count <> 0
      or v_failure_sha256 is distinct from v_preflight.failure_baseline_sha256 then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_DERIVATIVE_QUIESCENCE_GATE_FAILED',
        'status', 409,
        'message', 'Derivative baselines, queues, fences, or failure ledger drifted after preflight'
      );
    end if;

    v_material := jsonb_build_object(
      'schema_version', 'dataset-alias-execution-gate-material.v2',
      'gate', p_gate_name,
      'request_id', p_request_id,
      'actor_user_id', v_actor,
      'derivative_targets_sha256', v_preflight.derivative_targets_sha256,
      'snapshot_drift_count', v_snapshot_drift_count,
      'active_rebuild_count', v_active_rebuild_count,
      'http_request_count', v_http_count,
      'extraction_job_count', v_extraction_count,
      'embedding_job_count', v_embedding_count,
      'pending_embedding_count', v_pending_count,
      'failure_baseline_sha256', v_failure_sha256
    );
  end if;

  v_captured_at := pg_catalog.clock_timestamp();
  if v_captured_at > v_preflight.expires_at then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_WINDOW_EXPIRED',
      'status', 409,
      'message', 'The live gate completed after the 180-second server window'
    );
  end if;

  v_observed_sha256 := util.dataset_alias_execution_v2_sha256(v_material::text);
  if v_observed_sha256 is distinct from v_expected_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_EVIDENCE_MISMATCH',
      'status', 409,
      'message', 'The live gate evidence does not match the server-owned preflight expectation'
    );
  end if;

  v_receipt_material := jsonb_build_object(
    'schema_version', 'dataset-alias-execution-gate-receipt.v2',
    'request_id', p_request_id,
    'actor_user_id', v_actor,
    'preflight_proof_sha256', v_preflight.preflight_proof_sha256,
    'gate', p_gate_name,
    'expected_sha256', v_expected_sha256,
    'observed_sha256', v_observed_sha256,
    'status', 'passed',
    'captured_at', v_captured_at
  );
  v_receipt_sha256 :=
    util.dataset_alias_execution_v2_sha256(v_receipt_material::text);

  insert into util.dataset_alias_execution_v2_gate_receipts (
    preflight_id,
    actor_user_id,
    gate_name,
    expected_sha256,
    observed_sha256,
    material,
    status,
    captured_at,
    receipt_sha256
  ) values (
    p_request_id,
    v_actor,
    p_gate_name,
    v_expected_sha256,
    v_observed_sha256,
    v_material,
    'passed',
    v_captured_at,
    v_receipt_sha256
  );

  return v_receipt_material || jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_gate_v2_guarded',
    'receipt_sha256', v_receipt_sha256
  );
exception
  when lock_not_available then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_LOCK_BUSY',
      'status', 409,
      'message', 'Protected live gate could not acquire its bounded locks'
    );
  when unique_violation then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_ALREADY_CAPTURED',
      'status', 409,
      'message', 'A concurrent call already captured this live gate'
    );
end;
$$;

alter function api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text)
  owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text)
  to authenticated;

comment on function api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text) is
  'Captures one of exactly three actor-owned post-preflight live gates. Primary/support is rollback-simulated again; unused execution and derivative quiescence are read directly. Each passed receipt is persisted once inside the same 180-second server window.';

create or replace function api.cmd_dataset_alias_execution_admit_v2_guarded(
  p_request jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set statement_timeout = '10s'
as $$
declare
  v_actor uuid := auth.uid();
  -- The admission REQUEST keeps its input schema name; the RESPONSE has its own proof name, because
  -- this v2 has never shipped and carries exactly one response identity (no dual-name alias).
  v_schema_version constant text := 'dataset-alias-execution-admit.v2';
  v_response_schema_version constant text := 'dataset-alias-execution-admit-proof.v2';
  v_request_id uuid;
  v_preflight util.dataset_alias_execution_v2_preflights%rowtype;
  v_token text;
  v_gate_results jsonb;
  v_gate jsonb;
  v_gate_receipt util.dataset_alias_execution_v2_gate_receipts%rowtype;
  v_gate_name text;
  v_expectation_name text;
  v_captured_at timestamp with time zone;
  v_now timestamp with time zone;
  v_gate_results_sha256 text;
  v_admission_request_sha256 text;
  v_nonce text;
  v_nonce_sha256 text;
  v_service_key text;
  v_net_request_id bigint;
  v_dispatch_error jsonb;
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_request is not null and pg_column_size(p_request) > 65536 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ADMISSION_TOO_LARGE',
      'status', 413,
      'message', 'Protected admission request exceeds 64 KiB'
    );
  end if;

  if jsonb_typeof(p_request) is distinct from 'object'
    or not (p_request ?& array[
      'schema_version',
      'request_id',
      'preflight_token',
      'preflight_proof_sha256',
      'gate_results'
    ])
    or exists (
      select 1
      from jsonb_object_keys(p_request) as request_key(key)
      where request_key.key <> all (array[
        'schema_version',
        'request_id',
        'preflight_token',
        'preflight_proof_sha256',
        'gate_results'
      ])
    )
    or p_request->>'schema_version' is distinct from v_schema_version
    or jsonb_typeof(p_request->'request_id') is distinct from 'string'
    or (p_request->>'request_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or jsonb_typeof(p_request->'preflight_token') is distinct from 'string'
    or (p_request->>'preflight_token') !~ '^[a-f0-9]{64}$'
    or jsonb_typeof(p_request->'preflight_proof_sha256') is distinct from 'string'
    or (p_request->>'preflight_proof_sha256') !~ '^[a-f0-9]{64}$'
    or jsonb_typeof(p_request->'gate_results') is distinct from 'object' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ADMISSION_INVALID_REQUEST',
      'status', 400,
      'message', 'Admission request must match dataset-alias-execution-admit.v1 exactly'
    );
  end if;

  v_request_id := (p_request->>'request_id')::uuid;
  v_token := p_request->>'preflight_token';
  v_gate_results := p_request->'gate_results';

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || v_request_id::text, 0)
  );

  select preflight.*
  into v_preflight
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = v_request_id
    and preflight.actor_user_id = v_actor
  for update;

  if v_preflight.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_NOT_FOUND',
      'status', 404,
      'message', 'No actor-owned protected preflight exists for this request ID'
    );
  end if;

  v_now := pg_catalog.clock_timestamp();

  if v_preflight.consumed_at is not null
    or exists (
      select 1
      from util.dataset_alias_execution_v2_requests as request
      where request.id = v_request_id
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ATTEMPT_ALREADY_CONSUMED',
      'status', 409,
      'message', 'The protected attempt was already consumed; use status/readback only'
    );
  end if;

  if v_now > v_preflight.expires_at then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_EXPIRED',
      'status', 409,
      'message', 'The 180-second server preflight window expired before admission'
    );
  end if;

  if util.dataset_alias_execution_v2_sha256(v_token)
      is distinct from v_preflight.token_sha256
    or p_request->>'preflight_proof_sha256'
      is distinct from v_preflight.preflight_proof_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_PROOF_MISMATCH',
      'status', 409,
      'message', 'Preflight token or proof does not match the durable server record'
    );
  end if;

  if not (v_gate_results ?& array[
      'primary_support_plan',
      'execution_unused',
      'derivative_quiescence'
    ])
    or exists (
      select 1
      from jsonb_object_keys(v_gate_results) as gate_key(key)
      where gate_key.key <> all (array[
        'primary_support_plan',
        'execution_unused',
        'derivative_quiescence'
      ])
    ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_GATE_SET_MISMATCH',
      'status', 400,
      'message', 'Exactly three protected gate results are required'
    );
  end if;

  for v_gate_name, v_expectation_name in
    select *
    from (values
      ('primary_support_plan'::text, 'primary_support_plan_sha256'::text),
      ('execution_unused'::text, 'execution_unused_sha256'::text),
      ('derivative_quiescence'::text, 'derivative_quiescence_sha256'::text)
    ) as gate_map(gate_name, expectation_name)
  loop
    v_gate := v_gate_results->v_gate_name;
    v_gate_receipt := null;

    select receipt.*
    into v_gate_receipt
    from util.dataset_alias_execution_v2_gate_receipts as receipt
    where receipt.preflight_id = v_request_id
      and receipt.actor_user_id = v_actor
      and receipt.gate_name = v_gate_name;

    if jsonb_typeof(v_gate) is distinct from 'object'
      or not (v_gate ?& array[
        'expected_sha256',
        'observed_sha256',
        'status',
        'captured_at'
      ])
      or exists (
        select 1
        from jsonb_object_keys(v_gate) as gate_field(key)
        where gate_field.key <> all (array[
          'expected_sha256',
          'observed_sha256',
          'status',
          'captured_at'
        ])
      )
      or v_gate_receipt.preflight_id is null
      or v_gate->>'expected_sha256'
        is distinct from v_gate_receipt.expected_sha256
      or v_gate->>'observed_sha256'
        is distinct from v_gate_receipt.observed_sha256
      or v_gate->>'status' is distinct from v_gate_receipt.status
      or v_gate_receipt.expected_sha256
        is distinct from v_preflight.gate_expectations->>v_expectation_name
      or jsonb_typeof(v_gate->'captured_at') is distinct from 'string' then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_GATE_FAILED',
        'status', 409,
        'message', 'A protected gate is missing, failed, or bound to the wrong digest',
        'gate', v_gate_name
      );
    end if;

    begin
      v_captured_at := (v_gate->>'captured_at')::timestamp with time zone;
    exception
      when others then
        return jsonb_build_object(
          'ok', false,
          'code', 'ALIAS_EXECUTION_GATE_TIMESTAMP_INVALID',
          'status', 400,
          'message', 'A protected gate timestamp is invalid',
          'gate', v_gate_name
        );
    end;

    if v_captured_at is distinct from v_gate_receipt.captured_at
      or v_captured_at < v_preflight.completed_at
      or v_captured_at > v_now + interval '5 seconds'
      or v_captured_at > v_preflight.expires_at then
      return jsonb_build_object(
        'ok', false,
        'code', 'ALIAS_EXECUTION_GATE_OUTSIDE_WINDOW',
        'status', 409,
        'message', 'All gate evidence must be captured inside the server preflight window',
        'gate', v_gate_name
      );
    end if;
  end loop;

  if pg_catalog.clock_timestamp() > v_preflight.expires_at then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_EXPIRED',
      'status', 409,
      'message', 'The 180-second server preflight window expired during admission validation'
    );
  end if;

  v_gate_results_sha256 :=
    util.dataset_alias_execution_v2_sha256(v_gate_results::text);
  v_admission_request_sha256 :=
    util.dataset_alias_execution_v2_sha256(p_request::text);
  v_nonce := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
  v_nonce_sha256 := util.dataset_alias_execution_v2_sha256(v_nonce);

  insert into util.dataset_alias_execution_v2_requests (
    id,
    actor_user_id,
    plan_sha256,
    operation_id,
    plan_request_sha256,
    freeze_sha256,
    approval_identity_sha256,
    approval_text_sha256,
    derivative_target_set_sha256,
    preflight_proof_sha256,
    admission_request_sha256,
    gate_results,
    gate_results_sha256,
    nonce_sha256,
    attempt_count,
    dispatch_count,
    status,
    admitted_at
  ) values (
    v_request_id,
    v_actor,
    v_preflight.plan_sha256,
    v_preflight.operation_id,
    v_preflight.plan_request_sha256,
    v_preflight.bindings->>'freeze_sha256',
    v_preflight.bindings->>'approval_identity_sha256',
    v_preflight.bindings->>'approval_text_sha256',
    v_preflight.bindings->>'derivative_target_set_sha256',
    v_preflight.preflight_proof_sha256,
    v_admission_request_sha256,
    v_gate_results,
    v_gate_results_sha256,
    v_nonce_sha256,
    1,
    0,
    'dispatching',
    v_now
  );

  update util.dataset_alias_execution_v2_preflights
  set consumed_at = v_now
  where id = v_request_id;

  begin
    v_service_key := util.project_secret_key();
    v_net_request_id := net.http_post(
      url => util.project_url()
        || '/rest/v1/rpc/cmd_dataset_alias_execution_execute_v2',
      headers => jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_key,
        'apikey', v_service_key
      ),
      body => jsonb_build_object(
        'p_request_id', v_request_id,
        'p_nonce', v_nonce
      ),
      timeout_milliseconds => 70000
    );

    if v_net_request_id is null then
      raise exception using
        errcode = 'P0001',
        message = 'pg_net returned no request ID';
    end if;

    update util.dataset_alias_execution_v2_requests
    set
      dispatch_count = 1,
      net_request_id = v_net_request_id,
      status = 'dispatched',
      dispatched_at = pg_catalog.clock_timestamp(),
      updated_at = pg_catalog.clock_timestamp()
    where id = v_request_id;
  exception
    when others then
      v_dispatch_error := jsonb_build_object(
        'phase', 'dispatch',
        'code', 'ALIAS_EXECUTION_DISPATCH_FAILED',
        'sqlstate', sqlstate,
        'message', sqlerrm
      );

      update util.dataset_alias_execution_v2_requests
      set
        status = 'failed',
        terminal_at = pg_catalog.clock_timestamp(),
        last_error = v_dispatch_error,
        updated_at = pg_catalog.clock_timestamp()
      where id = v_request_id;
  end;

  if v_dispatch_error is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_DISPATCH_FAILED',
      'status', 'failed',
      'request_id', v_request_id,
      'attempt_count', 1,
      'dispatch_count', 0,
      'attempt_consumed', true,
      'retry_allowed', false,
      'preflight_proof_sha256', v_preflight.preflight_proof_sha256,
      'admission_request_sha256', v_admission_request_sha256,
      'gate_results_sha256', v_gate_results_sha256
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_admit_v2_guarded',
    'schema_version', v_response_schema_version,
    'request_id', v_request_id,
    'plan_sha256', v_preflight.plan_sha256,
    'operation_id', v_preflight.operation_id,
    'plan_request_sha256', v_preflight.plan_request_sha256,
    'preflight_proof_sha256', v_preflight.preflight_proof_sha256,
    'admission_request_sha256', v_admission_request_sha256,
    'gate_results_sha256', v_gate_results_sha256,
    'attempt_count', 1,
    'dispatch_count', 1,
    'net_request_id', v_net_request_id::text,
    'status', 'dispatched',
    'attempt_consumed', true,
    'retry_allowed', false
  );
exception
  when lock_not_available then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ADMISSION_LOCK_BUSY',
      'status', 409,
      'message', 'Protected admission could not acquire its bounded lock'
    );
  when unique_violation then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ATTEMPT_ALREADY_CONSUMED',
      'status', 409,
      'message', 'The request or sealed approval identity already consumed its only attempt'
    );
end;
$$;

alter function api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)
  owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)
  to authenticated;

comment on function api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb) is
  'Consumes one actor-owned unexpired preflight token, binds three passed gate digests, persists attempt_count=1, and enqueues at most one service executor request. Repeated admission is rejected and status/readback never redispatches.';

create or replace function util.read_dataset_alias_execution_v2_primary_closure(
  p_actor uuid,
  p_plan jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_action jsonb;
  v_found boolean;
  v_rows bigint := 0;
  v_claimed_rows bigint;
  v_exchange_count bigint;
begin
  if p_actor is null or jsonb_typeof(p_plan) is distinct from 'object' then
    return null;
  end if;
  v_claimed_rows := coalesce((p_plan #>> '{expected,action_count}')::bigint, -1);
  v_exchange_count := coalesce((p_plan #>> '{expected,exchange_count}')::bigint, -1);
  -- Fresh current readback: every claimed row must hold exactly the claimed desired payload now, for this
  -- actor, in the owner-draft state. The exact exchange set was proven under the lock by the batch
  -- executor; this readback re-verifies the committed rows rather than re-attesting a stored summary.
  for v_action in select * from jsonb_array_elements(coalesce(p_plan->'actions', '[]'::jsonb)) loop
    v_found := null;
    if v_action->>'table' = 'flows' then
      select true into v_found
      from public.flows as flow
      where flow.id = (v_action->>'id')::uuid
        and flow.version = v_action->>'version'
        and flow.user_id = p_actor
        and flow.state_code = 0
        and flow.json_ordered::jsonb is not distinct from v_action->'desired_json_ordered';
    elsif v_action->>'table' = 'processes' then
      select true into v_found
      from public.processes as process
      where process.id = (v_action->>'id')::uuid
        and process.version = v_action->>'version'
        and process.user_id = p_actor
        and process.state_code = 0
        and process.json_ordered::jsonb is not distinct from v_action->'desired_json_ordered';
    else
      v_found := false;
    end if;
    if coalesce(v_found, false) then
      v_rows := v_rows + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'ok', v_rows = v_claimed_rows and v_claimed_rows >= 0,
    'live_closure_proof', v_rows = v_claimed_rows and v_claimed_rows >= 0,
    'row_count', v_rows,
    'claimed_row_count', v_claimed_rows,
    'exchange_count', v_exchange_count,
    'invalid_action_count', case when v_rows = v_claimed_rows then 0 else v_claimed_rows - v_rows end,
    'proof_sha256', util.dataset_alias_execution_v2_artifact_sha256(
      jsonb_build_object('actor', p_actor, 'rows', v_rows, 'claimed_rows', v_claimed_rows,
        'exchange_count', v_exchange_count, 'plan_sha256', p_plan->>'plan_sha256'))
  );
end
$$;

alter function util.read_dataset_alias_execution_v2_primary_closure(uuid, jsonb) owner to postgres;
revoke all on function util.read_dataset_alias_execution_v2_primary_closure(uuid, jsonb)
  from public, anon, authenticated, service_role;

create or replace function api.cmd_dataset_alias_execution_execute_v2(
  p_request_id uuid,
  p_nonce text
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
set statement_timeout = '60s'
as $$
declare
  v_request util.dataset_alias_execution_v2_requests%rowtype;
  v_preflight util.dataset_alias_execution_v2_preflights%rowtype;
  v_alias_result jsonb;
  v_primary_closure jsonb;
  v_batch_result jsonb;
  v_alias_audit_count integer;
  v_failure jsonb;
  v_committed_at timestamp with time zone;
begin
  if not coalesce(util.is_service_request(), false) then
    return jsonb_build_object(
      'ok', false,
      'code', 'SERVICE_ROLE_REQUIRED',
      'status', 403,
      'message', 'Service role is required'
    );
  end if;

  if p_request_id is null
    or p_nonce is null
    or p_nonce !~ '^[a-f0-9]{64}$' then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_INVALID_SERVICE_REQUEST',
      'status', 400,
      'message', 'Exact request ID and executor nonce are required'
    );
  end if;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
  for update;

  if v_request.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_REQUEST_NOT_FOUND',
      'status', 404,
      'message', 'Protected execution request not found'
    );
  end if;

  if util.dataset_alias_execution_v2_sha256(p_nonce)
      is distinct from v_request.nonce_sha256 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_NONCE_MISMATCH',
      'status', 403,
      'message', 'Executor nonce does not match the admitted request'
    );
  end if;

  if v_request.status is distinct from 'dispatched'
    or v_request.dispatch_count <> 1 then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_ALREADY_STARTED',
      'status', 409,
      'message', 'The one-shot executor may start only once',
      'request_status', v_request.status,
      'retry_allowed', false
    );
  end if;

  select preflight.*
  into v_preflight
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = p_request_id
    and preflight.actor_user_id = v_request.actor_user_id;

  if v_preflight.id is null
    or v_preflight.consumed_at is null
    or v_preflight.preflight_proof_sha256
      is distinct from v_request.preflight_proof_sha256 then
    update util.dataset_alias_execution_v2_requests
    set
      status = 'indeterminate',
      terminal_at = pg_catalog.clock_timestamp(),
      last_error = jsonb_build_object(
        'phase', 'executor_precondition',
        'code', 'ALIAS_EXECUTION_PREFLIGHT_LEDGER_MISMATCH'
      ),
      updated_at = pg_catalog.clock_timestamp()
    where id = p_request_id;

    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_PREFLIGHT_LEDGER_MISMATCH',
      'status', 'indeterminate',
      'retry_allowed', false
    );
  end if;

  update util.dataset_alias_execution_v2_requests
  set
    status = 'running',
    started_at = pg_catalog.clock_timestamp(),
    updated_at = pg_catalog.clock_timestamp()
  where id = p_request_id;

  -- The service request remains authenticated by its secret headers.  Only
  -- auth.uid()/auth.email() are rebound so the existing owner-draft alias
  -- validators execute against the originally admitted actor.
  perform pg_catalog.set_config(
    'request.jwt.claim.sub',
    v_request.actor_user_id::text,
    true
  );
  perform pg_catalog.set_config(
    'request.jwt.claim.email',
    v_preflight.actor_email,
    true
  );

  begin
    v_alias_result := private.cmd_dataset_alias_plan_v2_guarded(v_preflight.plan);

    if coalesce((v_alias_result->>'ok')::boolean, false) is not true
      or coalesce((v_alias_result->>'idempotent_replay')::boolean, true)
      or v_alias_result->>'plan_sha256' is distinct from v_request.plan_sha256
      or v_alias_result->>'operation_id' is distinct from v_request.operation_id
      or v_alias_result->>'plan_request_sha256'
        is distinct from v_request.plan_request_sha256
      or (v_alias_result #>> '{counts,action_count}') is distinct from (v_preflight.plan #>> '{expected,action_count}')
      or (v_alias_result #>> '{counts,exchange_count}') is distinct from (v_preflight.plan #>> '{expected,exchange_count}') then
      v_failure := jsonb_build_object(
        'phase', 'alias',
        'code', 'ALIAS_EXECUTION_PRIMARY_REJECTED',
        'result', coalesce(v_alias_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected primary alias execution rejected';
    end if;

    -- The audit topology is the one the plan declared and the plan executor already verified: one row
    -- audit per action, one summary per batch and the whole-plan summary. The ledger is counted here,
    -- never trusted from the executor's response.
    select count(*)
    into v_alias_audit_count
    from private.command_audit_log as audit
    where audit.actor_user_id = v_request.actor_user_id
      and audit.payload->>'plan_sha256' = v_request.plan_sha256
      and (
        (
          audit.command = 'cmd_dataset_alias_batch_v2_guarded'
          and audit.payload->>'record_type' in ('row', 'plan')
        )
        or (
          audit.command = 'cmd_dataset_alias_plan_v2_guarded'
          and audit.payload->>'record_type' = 'plan_summary'
        )
      );

    if v_alias_audit_count is distinct from
      (v_preflight.plan #>> '{expected,audit_count}')::bigint then
      v_failure := jsonb_build_object(
        'phase', 'alias_audit',
        'code', 'ALIAS_EXECUTION_AUDIT_COUNT_MISMATCH',
        'expected', (v_preflight.plan #>> '{expected,audit_count}')::bigint,
        'observed', v_alias_audit_count
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected alias audit set is incomplete';
    end if;

    v_primary_closure :=
      util.read_dataset_alias_execution_v2_primary_closure(
        v_request.actor_user_id,
        v_preflight.plan
      );

    if coalesce(
        (v_primary_closure->>'live_closure_proof')::boolean,
        false
      ) is not true
      or v_primary_closure->>'row_count' is distinct from (v_preflight.plan #>> '{expected,action_count}')
      or v_primary_closure->>'exchange_count' is distinct from (v_preflight.plan #>> '{expected,exchange_count}')
      or v_primary_closure->>'invalid_action_count' is distinct from '0' then
      v_failure := jsonb_build_object(
        'phase', 'primary_closure',
        'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_MISMATCH',
        'proof', coalesce(v_primary_closure, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected primary/support live closure is incomplete';
    end if;

    v_batch_result := util.admit_dataset_alias_v2_derivative_chunks(
      v_request.actor_user_id,
      v_request.id,
      v_request.plan_sha256,
      v_request.operation_id,
      'PROTECTED_ALIAS_DERIVATIVE_CLOSURE',
      v_preflight.derivative_targets
    );

    if coalesce((v_batch_result->>'ok')::boolean, false) is not true
      or (v_batch_result->>'target_count')::integer is distinct from
        (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
      or coalesce((v_batch_result->>'flow_count')::integer, 0) is distinct from
        (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'flows')
      or coalesce((v_batch_result->>'process_count')::integer, 0) is distinct from
        (select count(*) from jsonb_array_elements(v_preflight.derivative_targets) as target where target->>'table' = 'processes') then
      v_failure := jsonb_build_object(
        'phase', 'derivative_batch',
        'code', 'ALIAS_EXECUTION_DERIVATIVE_ADMISSION_MISMATCH',
        'result', coalesce(v_batch_result, '{}'::jsonb)
      );
      raise exception using
        errcode = 'P0001',
        message = 'Protected derivative batch admission rejected';
    end if;

    v_committed_at := pg_catalog.clock_timestamp();

    update util.dataset_alias_execution_v2_requests
    set
      status = 'derivatives_pending',
      primary_committed_at = v_committed_at,
      alias_result = v_alias_result || jsonb_build_object(
        'primary_closure', v_primary_closure
      ),
      derivative_admission = v_batch_result,
      updated_at = v_committed_at
    where id = p_request_id;
  exception
    when others then
      if v_failure is null then
        v_failure := jsonb_build_object(
          'phase', 'executor',
          'code', 'ALIAS_EXECUTION_TRANSACTION_FAILED',
          'sqlstate', sqlstate,
          'message', sqlerrm
        );
      end if;
  end;

  if v_failure is not null then
    update util.dataset_alias_execution_v2_requests
    set
      status = 'failed',
      terminal_at = pg_catalog.clock_timestamp(),
      last_error = v_failure,
      updated_at = pg_catalog.clock_timestamp()
    where id = p_request_id;

    return jsonb_build_object(
      'ok', false,
      'command', 'cmd_dataset_alias_execution_execute_v2',
      'request_id', p_request_id,
      'status', 'failed',
      'primary_rolled_back', true,
      'retry_allowed', false,
      'error', v_failure
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_execute_v2',
    'request_id', p_request_id,
    'status', 'derivatives_pending',
    'plan_sha256', v_request.plan_sha256,
    'operation_id', v_request.operation_id,
    'plan_request_sha256', v_request.plan_request_sha256,
    'primary_committed_at', v_committed_at,
    'row_count', (select (preflight.plan #>> '{expected,action_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'exchange_count', (select (preflight.plan #>> '{expected,exchange_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'alias_audit_count', (select (preflight.plan #>> '{expected,audit_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'primary_closure', v_primary_closure,
    'derivative_target_count', (select (preflight.plan #>> '{expected,derivative_target_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id),
    'retry_allowed', false
  );
end;
$$;

alter function api.cmd_dataset_alias_execution_execute_v2(uuid, text)
  owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_execute_v2(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_execute_v2(uuid, text)
  to service_role;

comment on function api.cmd_dataset_alias_execution_execute_v2(uuid, text) is
  'Service-only, nonce-bound, non-replayable executor. It commits either the exact 52 alias rows/59 exchanges/55 alias audits plus all 50 derivative child requests in one transaction, or none of those business effects.';

create or replace function api.cmd_dataset_alias_execution_read_v2(
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set statement_timeout = '60s'
as $$
declare
  v_actor uuid := auth.uid();
  v_preflight util.dataset_alias_execution_v2_preflights%rowtype;
  v_request util.dataset_alias_execution_v2_requests%rowtype;
  v_gate_receipts jsonb := '[]'::jsonb;
  v_gate_count integer := 0;
  v_alias_audit_count integer := 0;
  v_derivative_child_count integer := 0;
  v_derivative_flow_count integer := 0;
  v_derivative_process_count integer := 0;
  v_primary_closure jsonb;
  v_primary_closure_ok boolean := false;
  v_active_dispatch_grace boolean := false;
  v_initial_request_status text;
  v_initial_request_updated_at timestamp with time zone;
  v_proof_request_status text;
  v_proof_request_updated_at timestamp with time zone;
  v_request_changed_during_read boolean := false;
  v_batch_proof_read boolean := false;
  v_terminal_update_count integer := 0;
  v_terminal_update_status text;
  v_batch_proof jsonb;
  v_terminal_proof jsonb;
  v_category text;
  v_now timestamp with time zone := pg_catalog.clock_timestamp();
begin
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AUTH_REQUIRED',
      'status', 401,
      'message', 'Authentication required'
    );
  end if;

  if p_request_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_READ_INVALID_REQUEST',
      'status', 400,
      'message', 'Exact protected execution request ID is required'
    );
  end if;

  select preflight.*
  into v_preflight
  from util.dataset_alias_execution_v2_preflights as preflight
  where preflight.id = p_request_id
    and preflight.actor_user_id = v_actor;

  if v_preflight.id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_REQUEST_NOT_FOUND',
      'status', 404,
      'message', 'No actor-owned protected preflight or execution exists'
    );
  end if;

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'gate', receipt.gate_name,
          'expected_sha256', receipt.expected_sha256,
          'observed_sha256', receipt.observed_sha256,
          'status', receipt.status,
          'captured_at', receipt.captured_at,
          'receipt_sha256', receipt.receipt_sha256
        ) order by receipt.captured_at, receipt.gate_name
      ),
      '[]'::jsonb
    ),
    count(*)::integer
  into v_gate_receipts, v_gate_count
  from util.dataset_alias_execution_v2_gate_receipts as receipt
  where receipt.preflight_id = p_request_id
    and receipt.actor_user_id = v_actor;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
    and request.actor_user_id = v_actor;

  if v_request.id is null then
    return jsonb_build_object(
      'ok', true,
      'command', 'cmd_dataset_alias_execution_read_v2',
      'schema_version', 'dataset-alias-execution-status.v2',
      'request_id', p_request_id,
      'status', 'indeterminate',
      'execution_status', 'not_admitted',
      'code', case
        when v_preflight.consumed_at is null
          then 'ALIAS_EXECUTION_NOT_ADMITTED'
        else 'ALIAS_EXECUTION_ADMISSION_LEDGER_MISSING'
      end,
      'retry_allowed', false,
      'actor_user_id', v_actor,
      'environment', v_preflight.environment,
      'project_ref', v_preflight.project_ref,
      'plan_sha256', v_preflight.plan_sha256,
      'operation_id', v_preflight.operation_id,
      'plan_request_sha256', v_preflight.plan_request_sha256,
      'preflight_proof_sha256', v_preflight.preflight_proof_sha256,
      'preflight_completed_at', v_preflight.completed_at,
      'preflight_expires_at', v_preflight.expires_at,
      'preflight_consumed_at', v_preflight.consumed_at,
      'gate_count', v_gate_count,
      'gates', v_gate_receipts
    );
  end if;

  v_initial_request_status := v_request.status;
  v_initial_request_updated_at := v_request.updated_at;

  v_active_dispatch_grace :=
    v_request.status in ('dispatching', 'dispatched', 'running')
    and v_now <= v_request.admitted_at + interval '120 seconds';

  if v_active_dispatch_grace then
    -- Do not run the heavyweight live closure while the one-shot executor may
    -- be committing.  Apart from wasting work, a status lock/readback race
    -- must never delay or misclassify the only authorized mutation attempt.
    v_primary_closure := jsonb_build_object(
      'ok', false,
      'schema_version', 'dataset-alias-primary-closure.v1',
      'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_PENDING',
      'live_closure_proof', false
    );
  else

  select count(*)::integer
  into v_alias_audit_count
  from private.command_audit_log as audit
  where audit.actor_user_id = v_actor
    and audit.payload->>'plan_sha256' = v_request.plan_sha256
    and (
      (
        audit.command = 'cmd_dataset_alias_batch_v2_guarded'
        and audit.payload->>'record_type' in ('row', 'plan')
      )
      or (
        audit.command = 'cmd_dataset_alias_plan_v2_guarded'
        and audit.payload->>'record_type' = 'plan_summary'
      )
    );

  select
    count(*)::integer,
    count(*) filter (where target_table = 'flows')::integer,
    count(*) filter (where target_table = 'processes')::integer
  into
    v_derivative_child_count,
    v_derivative_flow_count,
    v_derivative_process_count
  from util.dataset_derivative_rebuild_requests as child
  where child.actor_user_id = v_actor
    and child.batch_id in (
      select (chunk->>'batch_id')::uuid
      from jsonb_array_elements(private.dataset_alias_v2_derivative_chunks(
        p_request_id, v_request.plan_sha256, v_preflight.derivative_targets)) as chunk
    );

  v_primary_closure :=
    util.read_dataset_alias_execution_v2_primary_closure(
      v_actor,
      v_preflight.plan
    );
  v_primary_closure_ok := coalesce(
    (v_primary_closure->>'live_closure_proof')::boolean,
    false
  );

  if v_request.status in ('dispatching', 'dispatched', 'running') then
    if v_alias_audit_count = (v_preflight.plan #>> '{expected,audit_count}')::integer
      and v_derivative_child_count =
        (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
      and v_derivative_flow_count = (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'flows'
      )
      and v_derivative_process_count = (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'processes'
      )
      and v_primary_closure_ok then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'derivatives_pending',
        primary_committed_at = coalesce(primary_committed_at, updated_at),
        updated_at = v_now
      where id = p_request_id
        and status in ('dispatching', 'dispatched', 'running');
    elsif (
        v_alias_audit_count > 0
        or v_derivative_child_count > 0
      ) and not v_primary_closure_ok then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'indeterminate',
        terminal_at = v_now,
        last_error = jsonb_build_object(
          'phase', 'reconcile',
          'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_MISMATCH',
          'primary_closure', v_primary_closure,
          'retry_allowed', false
        ),
        updated_at = v_now
      where id = p_request_id
        and status in ('dispatching', 'dispatched', 'running');
    elsif v_now > v_request.admitted_at + interval '120 seconds' then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'indeterminate',
        terminal_at = v_now,
        last_error = jsonb_build_object(
          'phase', 'reconcile',
          'code', 'ALIAS_EXECUTION_DISPATCH_OUTCOME_INDETERMINATE',
          'alias_audit_count', v_alias_audit_count,
          'derivative_child_count', v_derivative_child_count,
          'retry_allowed', false
        ),
        updated_at = v_now
      where id = p_request_id
        and status in ('dispatching', 'dispatched', 'running');
    end if;
  end if;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
    and request.actor_user_id = v_actor;

  v_request_changed_during_read :=
    v_request.status is distinct from v_initial_request_status
    or v_request.updated_at is distinct from v_initial_request_updated_at;

  if v_request_changed_during_read then
    -- VOLATILE PL/pgSQL statements can observe different READ COMMITTED
    -- snapshots.  If the executor or this reconciliation pass advanced the
    -- ledger after the first read, none of the evidence cached above is safe
    -- to use for another monotonic classification.  Return an explicit
    -- read-only conflict so the caller can poll again from the new state;
    -- execution admission and dispatch remain permanently non-retryable.
    return jsonb_build_object(
      'ok', false,
      'command', 'cmd_dataset_alias_execution_read_v2',
      'schema_version', 'dataset-alias-execution-status.v2',
      'request_id', p_request_id,
      'code', 'ALIAS_EXECUTION_READ_STATE_CHANGED',
      'status', 409,
      'execution_status', v_request.status,
      'retry_allowed', false,
      'read_retry_allowed', true,
      'message', 'Execution state changed during readback; poll status again without redispatching'
    );
  end if;

  v_proof_request_status := v_request.status;
  v_proof_request_updated_at := v_request.updated_at;

  if v_derivative_child_count > 0
    or v_request.status in ('derivatives_pending', 'completed') then
    v_batch_proof_read := true;
    -- The versioned orchestration's own aggregate readback: every chunk through the existing bounded
    -- reader, with exact membership and a terminal proof only when every chunk proves its closure.
    v_batch_proof := util.read_dataset_alias_v2_derivative_chunks(
      v_actor,
      p_request_id,
      v_request.plan_sha256,
      v_preflight.derivative_targets
    );

    select request.*
    into v_request
    from util.dataset_alias_execution_v2_requests as request
    where request.id = p_request_id
      and request.actor_user_id = v_actor;

    if v_request.status is distinct from v_proof_request_status
      or v_request.updated_at is distinct from v_proof_request_updated_at then
      -- The derivative proof can be substantially more expensive than the
      -- parent-ledger read.  A different reader or the executor may classify
      -- the request while that proof is being assembled, so the cached proof
      -- must not be applied to the newly visible parent state.
      return jsonb_build_object(
        'ok', false,
        'command', 'cmd_dataset_alias_execution_read_v2',
        'schema_version', 'dataset-alias-execution-status.v2',
        'request_id', p_request_id,
        'code', 'ALIAS_EXECUTION_READ_STATE_CHANGED',
        'status', 409,
        'execution_status', v_request.status,
        'retry_allowed', false,
        'read_retry_allowed', true,
        'message', 'Execution state changed during readback; poll status again without redispatching'
      );
    end if;
  end if;

  if v_request.status = 'derivatives_pending' then
    if v_alias_audit_count
        is distinct from (v_preflight.plan #>> '{expected,audit_count}')::integer
      or v_derivative_child_count
        is distinct from (v_preflight.plan #>> '{expected,derivative_target_count}')::integer
      or v_derivative_flow_count is distinct from (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'flows'
      )
      or v_derivative_process_count is distinct from (
        select count(*)::integer from jsonb_array_elements(v_preflight.derivative_targets) as target
        where target->>'table' = 'processes'
      )
      or not v_primary_closure_ok then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'indeterminate',
        terminal_at = v_now,
        terminal_proof = jsonb_build_object(
          'primary_closure', v_primary_closure,
          'derivative_closure', v_batch_proof
        ),
        last_error = jsonb_build_object(
          'phase', 'readback',
          'code', 'ALIAS_EXECUTION_PRIMARY_CLOSURE_MISMATCH',
          'alias_audit_count', v_alias_audit_count,
          'derivative_child_count', v_derivative_child_count,
          'primary_closure', v_primary_closure
        ),
        updated_at = v_now
      where id = p_request_id
        and status = 'derivatives_pending';
      get diagnostics v_terminal_update_count = row_count;
      if v_terminal_update_count = 1 then
        v_terminal_update_status := 'indeterminate';
      end if;
    elsif v_batch_proof->>'status' = 'completed'
      and coalesce((v_batch_proof->>'causal_terminal_proof')::boolean, false) then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'completed',
        terminal_at = v_now,
        terminal_proof = jsonb_build_object(
          'primary_closure', v_primary_closure,
          'derivative_closure', v_batch_proof
        ),
        updated_at = v_now
      where id = p_request_id
        and status = 'derivatives_pending';
      get diagnostics v_terminal_update_count = row_count;
      if v_terminal_update_count = 1 then
        v_terminal_update_status := 'completed';
      end if;
    elsif v_batch_proof->>'status' = 'failed' then
      update util.dataset_alias_execution_v2_requests
      set
        status = 'failed',
        terminal_at = v_now,
        terminal_proof = jsonb_build_object(
          'primary_closure', v_primary_closure,
          'derivative_closure', v_batch_proof
        ),
        last_error = jsonb_build_object(
          'phase', 'derivative_readback',
          'code', coalesce(
            v_batch_proof->>'code',
            'ALIAS_EXECUTION_DERIVATIVE_CLOSURE_FAILED'
          )
        ),
        updated_at = v_now
      where id = p_request_id
        and status = 'derivatives_pending';
      get diagnostics v_terminal_update_count = row_count;
      if v_terminal_update_count = 1 then
        v_terminal_update_status := 'failed';
      end if;
    end if;
  end if;

  select request.*
  into v_request
  from util.dataset_alias_execution_v2_requests as request
  where request.id = p_request_id
    and request.actor_user_id = v_actor;

  if v_batch_proof_read
    and (
      v_request.status is distinct from v_proof_request_status
      or v_request.updated_at is distinct from v_proof_request_updated_at
    )
    and not (
      v_terminal_update_count = 1
      and v_request.status is not distinct from v_terminal_update_status
      and v_request.updated_at is not distinct from v_now
    ) then
    -- A conditional terminal update with ROW_COUNT = 1 is this invocation's
    -- own monotonic classification.  Any other parent transition invalidates
    -- the cached derivative proof and must be retried as read-only polling.
    return jsonb_build_object(
      'ok', false,
      'command', 'cmd_dataset_alias_execution_read_v2',
      'schema_version', 'dataset-alias-execution-status.v2',
      'request_id', p_request_id,
      'code', 'ALIAS_EXECUTION_READ_STATE_CHANGED',
      'status', 409,
      'execution_status', v_request.status,
      'retry_allowed', false,
      'read_retry_allowed', true,
      'message', 'Execution state changed during readback; poll status again without redispatching'
    );
  end if;

  end if;

  v_category := case v_request.status
    when 'completed' then 'passed'
    when 'failed' then 'failed'
    when 'indeterminate' then 'indeterminate'
    else 'pending'
  end;

  -- A stored completion is not allowed to hide later live-state drift during
  -- an independent readback.  The immutable ledger remains completed, but the
  -- fresh response fails closed if its current causal proof no longer passes.
  if v_request.status = 'completed'
    and (
      not v_primary_closure_ok
      or v_batch_proof is null
      or v_batch_proof->>'status' is distinct from 'completed'
      or coalesce((v_batch_proof->>'causal_terminal_proof')::boolean, false)
        is not true
    ) then
    v_category := 'failed';
  end if;

  -- The strict terminal proof exists only for a genuinely successful execution whose live primary
  -- closure AND every derivative child causal terminal proof still pass on this read. Everything else —
  -- pending, failed, indeterminate or drifted — reports null, never a fabricated observation.
  if v_category = 'passed'
    and v_request.status = 'completed'
    and v_primary_closure_ok
    and v_batch_proof is not null
    and v_batch_proof->>'status' = 'completed'
    and coalesce((v_batch_proof->>'causal_terminal_proof')::boolean, false) is true
    and coalesce((v_batch_proof->>'membership_exact')::boolean, false) is true then
    v_terminal_proof := util.read_dataset_alias_execution_v2_terminal_proof(v_actor, v_preflight.plan);
  end if;

  return jsonb_build_object(
    'ok', true,
    'command', 'cmd_dataset_alias_execution_read_v2',
    'schema_version', 'dataset-alias-execution-status.v2',
    'request_id', p_request_id,
    'status', v_category,
    'terminal_proof', v_terminal_proof,
    'execution_status', v_request.status,
    'retry_allowed', false,
    'actor_user_id', v_actor,
    'environment', v_preflight.environment,
    'project_ref', v_preflight.project_ref,
    'target_visibility', v_preflight.target_visibility,
    'plan_sha256', v_request.plan_sha256,
    'operation_id', v_request.operation_id,
    'plan_request_sha256', v_request.plan_request_sha256,
    'freeze_sha256', v_request.freeze_sha256,
    'approval_identity_sha256', v_request.approval_identity_sha256,
    'approval_text_sha256', v_request.approval_text_sha256,
    'derivative_target_set_sha256', v_request.derivative_target_set_sha256,
    'server_derivative_targets_sha256',
      v_preflight.derivative_targets_sha256,
    'preflight_proof_sha256', v_request.preflight_proof_sha256,
    'admission_request_sha256', v_request.admission_request_sha256,
    'gate_results_sha256', v_request.gate_results_sha256,
    'attempt_count', v_request.attempt_count,
    'dispatch_count', v_request.dispatch_count,
    'net_request_id', v_request.net_request_id::text,
    'preflight_completed_at', v_preflight.completed_at,
    'preflight_expires_at', v_preflight.expires_at,
    'preflight_consumed_at', v_preflight.consumed_at,
    'admitted_at', v_request.admitted_at,
    'dispatched_at', v_request.dispatched_at,
    'started_at', v_request.started_at,
    'primary_committed_at', v_request.primary_committed_at,
    'terminal_at', v_request.terminal_at,
    'gate_count', v_gate_count,
    'gates', v_gate_receipts,
    'primary_readback', jsonb_build_object(
      'row_count', case
        when v_alias_audit_count = (select (preflight.plan #>> '{expected,audit_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id) and v_primary_closure_ok then (select (preflight.plan #>> '{expected,action_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id)
        else null
      end,
      'exchange_count', case
        when v_alias_audit_count = (select (preflight.plan #>> '{expected,audit_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id) and v_primary_closure_ok then (select (preflight.plan #>> '{expected,exchange_count}')::integer from util.dataset_alias_execution_v2_preflights as preflight where preflight.id = v_request.id)
        else null
      end,
      'alias_audit_count', v_alias_audit_count,
      'live_closure_proof', v_primary_closure_ok,
      'closure', v_primary_closure
    ),
    'derivative_readback', coalesce(
      v_batch_proof,
      jsonb_build_object(
        'schema_version', 'dataset-derivative-rebuild-batch-status.v1',
        'batch_id', p_request_id,
        'status', 'not_started',
        'code', 'DERIVATIVE_BATCH_NOT_STARTED',
        'proof_level', 'none',
        'proof_deferred', false,
        'target_count', v_derivative_child_count,
        'flow_count', v_derivative_flow_count,
        'process_count', v_derivative_process_count,
        'completed_count', 0,
        'nonterminal_count', 0,
        'failed_count', 0,
        'invalid_proof_count', null,
        'causal_terminal_proof', false,
        'targets', '[]'::jsonb
      )
    ),
    'error', v_request.last_error
  );
exception
  when lock_not_available then
    return jsonb_build_object(
      'ok', false,
      'code', 'ALIAS_EXECUTION_READ_LOCK_BUSY',
      'status', 'indeterminate',
      'message', 'Protected execution status row is busy; readback did not retry or redispatch'
    );
end;
$$;

alter function api.cmd_dataset_alias_execution_read_v2(uuid)
  owner to postgres;
revoke all on function api.cmd_dataset_alias_execution_read_v2(uuid)
  from public, anon, authenticated, service_role;
grant execute on function api.cmd_dataset_alias_execution_read_v2(uuid)
  to authenticated;

comment on function api.cmd_dataset_alias_execution_read_v2(uuid) is
  'Actor-only status and reconciliation for one protected attempt. It may monotonically classify durable evidence as derivatives_pending/completed/failed/indeterminate, but it never dispatches, retries, replays, or changes dataset rows.';

-- The old whole-plan function deliberately supports idempotent replay and is
-- therefore no longer an authenticated API once the protected replacement is
-- installed.  The private/service executor above can still invoke it as owner.
revoke all on function private.cmd_dataset_alias_plan_v2_guarded(jsonb)
  from public, anon, authenticated, service_role;

comment on function private.cmd_dataset_alias_plan_v2_guarded(jsonb) is
  'Internal owner-draft alias transaction used by the protected one-shot executor and rollback-only preflight. Direct authenticated/service-role API execution is revoked because this legacy function supports idempotent replay.';

-- The capability manifest rows of the versioned surface: the four actor-facing endpoints are authenticated
-- only, and the service-only callback is service-role only with no anon/authenticated reach.
insert into private.api_capability_grants (routine_identity, capability_id, allow_anon, allow_authenticated, allow_service_role)
values
  ('api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)', 'CLI-ALIAS-02', false, true, false),
  ('api.cmd_dataset_alias_execution_gate_v2_guarded(uuid, text, text)', 'CLI-ALIAS-02', false, true, false),
  ('api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)', 'CLI-ALIAS-02', false, true, false),
  ('api.cmd_dataset_alias_execution_read_v2(uuid)', 'CLI-ALIAS-02', false, true, false),
  ('api.cmd_dataset_alias_execution_execute_v2(uuid, text)', 'CLI-ALIAS-02', false, false, true)
on conflict (routine_identity) do update
  set capability_id = excluded.capability_id,
      allow_anon = excluded.allow_anon,
      allow_authenticated = excluded.allow_authenticated,
      allow_service_role = excluded.allow_service_role;
