-- Database #689: the protected whole-preflight (and the real admit transaction) quarantines one
-- derivative target at a time through util.quarantine_dataset_derivative_rebuild_target, and every
-- quarantine call deletes from net.http_request_queue by scanning the queue and JSON-parsing each
-- candidate dispatch body through util.dataset_derivative_rebuild_http_body_matches. Inside the
-- rollback-only simulation the queue holds one uncommitted dispatch per target, no drainer can
-- remove uncommitted rows, and the real bodies are built from to_jsonb(NEW)/to_jsonb(OLD) so every
-- row carries a large payload: the measured nested-statement hotspot is 387 queue deletes at
-- ~12.9 s and 1,143,439 shared hits for one complete-row preflight, with per-body decode repeated
-- once per target.
--
-- This migration removes the repeated decode without touching the matcher: the original
-- util.dataset_derivative_rebuild_http_body_matches definition is left exactly as it was (the
-- earlier, insufficient prefilter variant of this migration is replaced in place and never
-- published). The bounded batch admission instead builds ONE candidate cache per batch of at most
-- fifty targets, after every target has been fully validated and locked, and every target's
-- quarantine deletes through a new internal-only cached path whose row set is provably identical
-- to the original:
--
--   cache (one decode pass, per batch):  {"snapshot": {queue_id: ctid, ...},
--                                         "targets": {ordinal: {queue_id: true, ...}, ...}}
--   It records, per queue row, only its id, its ctid version, and which target ordinals have that
--   row's id anywhere in its decoded body. The body-decode superset rule: the original matcher can
--   only return true when a decoded string equals the target id, so id-presence in the decoded body
--   is a necessary condition; the cache therefore never omits a row the matcher would delete. The
--   target side of that comparison is normalised with (id)::uuid::text because plan validation
--   accepts any hexadecimal case while the matcher compares against the canonical lower-case
--   p_id::text; the body side stays verbatim, exactly like the matcher, so a body id in another
--   case remains the non-match the matcher already reports. The queue rows are MATERIALIZED so each
--   body is decoded exactly once per batch.
--
--   per-target delete (row set unchanged):  candidate rows are
--     (a) rows the cache recorded as matching this target, plus
--     (b) rows absent from the snapshot (concurrent inserts) or whose ctid changed (rewrites),
--   and every candidate is still decided by the original matcher on its current body. No cached
--   match result is trusted, no row outside the (a) u (b) superset can satisfy the original
--   predicate, and the unchanged URL predicate still applies.
--
-- The 3-arg quarantine, the matcher, the queue's shape, every lock, audit, count, snapshot
-- re-check, failure rollback and replay rule are untouched; only the measured hotspot path changes.
-- No index, no table, no global queue lock, and no weakened check is added.

create or replace function private.dataset_derivative_http_body_candidate_ids(
  p_body bytea
) returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  v_body jsonb;
  v_ids text[];
begin
  if p_body is null then
    return array[]::text[];
  end if;
  v_body := pg_catalog.convert_from(p_body, 'UTF8')::jsonb;
  if jsonb_typeof(v_body) = 'object' then
    select coalesce(array_agg(candidate.value), array[]::text[])
    into v_ids
    from (
      select v_body #>> '{record,id}' as value
      union all
      select v_body #>> '{old_record,id}'
    ) as candidate
    where candidate.value is not null;
    return v_ids;
  end if;
  if jsonb_typeof(v_body) = 'array' then
    select coalesce(array_agg(distinct job.value->>'id'), array[]::text[])
    into v_ids
    from jsonb_array_elements(v_body) as job(value)
    where job.value->>'id' is not null;
    return v_ids;
  end if;
  return array[]::text[];
exception
  when others then
    return array[]::text[];
end;
$$;

alter function private.dataset_derivative_http_body_candidate_ids(bytea)
  owner to postgres;
revoke all on function private.dataset_derivative_http_body_candidate_ids(bytea)
  from public;
comment on function private.dataset_derivative_http_body_candidate_ids(bytea) is
  'Ids a dispatch body can possibly match under the derivative quarantine predicate: the decoded record/old_record ids for object bodies and every embedded job id for array bodies. Presence of an id in this set is necessary (never sufficient) for util.dataset_derivative_rebuild_http_body_matches, so callers use it only as a candidate superset.';

create or replace function private.dataset_derivative_rebuild_queue_cache(
  p_targets jsonb
) returns jsonb
language sql
stable
set search_path = ''
as $$
  with queue_rows as materialized (
    select
      request.id,
      request.ctid::text as ctid,
      private.dataset_derivative_http_body_candidate_ids(request.body) as ids
    from net.http_request_queue as request
    where request.url like '%/functions/v1/webhook_process_embedding_ft'
      or request.url like '%/functions/v1/webhook_flow_embedding_ft'
      or request.url like '%/functions/v1/embedding_ft'
  ),
  snapshot as (
    select jsonb_object_agg(queue_row.id::text, queue_row.ctid) as map
    from queue_rows as queue_row
  ),
  target_matches as (
    select
      matched.ordinal,
      jsonb_object_agg(distinct matched.id::text, true) as map
    from (
      select queue_row.id, target.ordinality as ordinal
      from queue_rows as queue_row
      cross join lateral unnest(queue_row.ids) as body_id(value)
      join lateral (
        select target.ordinality
        from jsonb_array_elements(p_targets) with ordinality as target(value, ordinality)
        where (target.value->>'id')::uuid::text = body_id.value
      ) as target on true
    ) as matched
    group by matched.ordinal
  )
  select jsonb_build_object(
    'snapshot', coalesce((select snapshot.map from snapshot), '{}'::jsonb),
    'targets', coalesce(
      (select jsonb_object_agg(target_matches.ordinal::text, target_matches.map)
       from target_matches),
      '{}'::jsonb
    )
  )
$$;

alter function private.dataset_derivative_rebuild_queue_cache(jsonb)
  owner to postgres;
revoke all on function private.dataset_derivative_rebuild_queue_cache(jsonb)
  from public;
comment on function private.dataset_derivative_rebuild_queue_cache(jsonb) is
  'One-pass candidate cache over the derivative dispatch queue for a bounded batch: every queue row''s id and ctid version, plus the per-target-ordinal row-id sets derived from decoded body ids. A candidate superset for the quarantine predicate; the matcher still decides every candidate row.';

create or replace function util.quarantine_dataset_derivative_rebuild_target_cached(
  p_table text,
  p_id uuid,
  p_version text,
  p_cache jsonb,
  p_ordinal integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_http integer := 0;
  v_embedding integer := 0;
  v_pending integer := 0;
  v_snapshot jsonb;
  v_candidates jsonb;
begin
  if p_table is null or p_table not in ('flows', 'processes') then
    raise exception using
      errcode = '22023',
      message = 'Derivative quarantine target table must be flows or processes';
  end if;

  v_snapshot := coalesce(p_cache->'snapshot', '{}'::jsonb);
  v_candidates := coalesce(p_cache->'targets'->p_ordinal::text, '{}'::jsonb);

  delete from net.http_request_queue as request
  where (
      request.url like '%/functions/v1/webhook_process_embedding_ft'
      or request.url like '%/functions/v1/webhook_flow_embedding_ft'
      or request.url like '%/functions/v1/embedding_ft'
    )
    and (
      v_candidates ? request.id::text
      or not (v_snapshot ? request.id::text)
      or (v_snapshot->>request.id::text) is distinct from request.ctid::text
    )
    and util.dataset_derivative_rebuild_http_body_matches(
      request.body,
      p_table,
      p_id,
      p_version
    );
  get diagnostics v_http = row_count;

  delete from pgmq.q_embedding_jobs as job
  where job.message->>'id' = p_id::text
    and btrim(job.message->>'version') = p_version
    and job.message->>'schema' = 'public'
    and job.message->>'table' = p_table
    and job.message->>'embeddingColumn' = 'embedding_ft';
  get diagnostics v_embedding = row_count;

  delete from util.pending_embedding_jobs as pending
  where pending.schema_name = 'public'
    and pending.table_name = p_table
    and pending.record_id = p_id::text
    and btrim(pending.record_version) = p_version
    and pending.embedding_column = 'embedding_ft';
  get diagnostics v_pending = row_count;

  return jsonb_build_object(
    'http_requests', v_http,
    'embedding_jobs', v_embedding,
    'pending_jobs', v_pending
  );
end;
$$;

alter function util.quarantine_dataset_derivative_rebuild_target_cached(
  text,
  uuid,
  text,
  jsonb,
  integer
) owner to postgres;
revoke all on function util.quarantine_dataset_derivative_rebuild_target_cached(
  text,
  uuid,
  text,
  jsonb,
  integer
) from public, anon, authenticated, service_role;
comment on function util.quarantine_dataset_derivative_rebuild_target_cached(
  text,
  uuid,
  text,
  jsonb,
  integer
) is
  'Cached-batch variant of util.quarantine_dataset_derivative_rebuild_target: the queue delete first narrows to the cache''s candidate superset (cached matches for this ordinal, plus rows absent from the snapshot or with a changed ctid version) and the original dispatch-body matcher still decides every candidate row; the embedding-job and pending-job deletes and the returned counters are identical to the uncached owner. Internal batch-admission use only.';

create or replace function util.admit_dataset_derivative_rebuild_batch(
  p_actor_user_id uuid,
  p_batch_id uuid,
  p_plan_sha256 text,
  p_operation_id text,
  p_reason_code text,
  p_targets jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  v_command constant text := 'cmd_dataset_derivative_rebuild_plan_guarded';
  v_schema_version constant text := 'dataset-derivative-rebuild-batch.v1';
  v_target jsonb;
  v_snapshot jsonb;
  v_quarantine jsonb;
  v_queue_cache jsonb;
  v_action jsonb;
  v_table text;
  v_id uuid;
  v_version text;
  v_expected_json_ordered_sha256 text;
  v_baseline_snapshot_sha256 text;
  v_target_count integer;
  v_flow_count integer;
  v_process_count integer;
  v_ordinal integer;
  v_action_id text;
  v_action_request_sha256 text;
  v_plan_request_sha256 text;
  v_summary_audit_id bigint;
  v_action_audit_id bigint;
  v_request_id uuid;
  v_now timestamp with time zone := pg_catalog.clock_timestamp();
  v_child_ids jsonb := '[]'::jsonb;
  v_normalized_targets jsonb;
  v_flow public.flows%rowtype;
  v_process public.processes%rowtype;
begin
  if p_actor_user_id is null
    or p_batch_id is null
    or p_plan_sha256 is null
    or p_plan_sha256 !~ '^[a-f0-9]{64}$'
    or nullif(btrim(p_operation_id), '') is null
    or octet_length(p_operation_id) > 512
    or nullif(btrim(p_reason_code), '') is null
    or octet_length(p_reason_code) > 512
    or jsonb_typeof(p_targets) is distinct from 'array'
    or jsonb_array_length(p_targets) not between 1 and 50
    or pg_column_size(p_targets) > 131072 then
    raise exception using
      errcode = '22023',
      message = 'Invalid bounded derivative rebuild batch request';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_targets) as target(value)
    where jsonb_typeof(target.value) is distinct from 'object'
      or not (target.value ?& array[
        'table',
        'id',
        'version',
        'expected_json_ordered_sha256',
        'baseline_snapshot_sha256'
      ])
      or exists (
        select 1
        from jsonb_object_keys(target.value) as target_key(key)
        where target_key.key <> all (array[
          'table',
          'id',
          'version',
          'expected_json_ordered_sha256',
          'baseline_snapshot_sha256'
        ])
      )
      or jsonb_typeof(target.value->'table') is distinct from 'string'
      or target.value->>'table' not in ('flows', 'processes')
      or jsonb_typeof(target.value->'id') is distinct from 'string'
      or (target.value->>'id')
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or jsonb_typeof(target.value->'version') is distinct from 'string'
      or (target.value->>'version') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or jsonb_typeof(target.value->'expected_json_ordered_sha256')
        is distinct from 'string'
      or (target.value->>'expected_json_ordered_sha256')
        !~ '^[a-f0-9]{64}$'
      or jsonb_typeof(target.value->'baseline_snapshot_sha256')
        is distinct from 'string'
      or (target.value->>'baseline_snapshot_sha256')
        !~ '^[a-f0-9]{64}$'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Derivative rebuild batch targets must match the exact schema';
  end if;

  select
    count(*)::integer,
    count(*) filter (where target.value->>'table' = 'flows')::integer,
    count(*) filter (where target.value->>'table' = 'processes')::integer
  into v_target_count, v_flow_count, v_process_count
  from jsonb_array_elements(p_targets) as target(value);

  if (
    select count(*)
    from (
      select distinct
        target.value->>'table' as target_table,
        (target.value->>'id')::uuid as target_id,
        btrim(target.value->>'version') as target_version
      from jsonb_array_elements(p_targets) as target(value)
    ) as unique_target
  ) <> v_target_count then
    raise exception using
      errcode = '22023',
      message = 'Derivative rebuild batch targets must be unique';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_batch_id::text,
      0
    )
  );

  if exists (
    select 1
    from util.dataset_derivative_rebuild_requests as request
    where request.batch_id = p_batch_id
  ) then
    raise exception using
      errcode = '23505',
      message = 'Derivative rebuild batch id has already been admitted';
  end if;

  -- Full validation pass.  No quarantine, audit, proposal, request, or queue
  -- effect happens until every target has passed this loop.  Stable ordered
  -- row locks below avoid adding a database-wide write lock; the protected
  -- alias caller already owns any stronger closure locks required by its own
  -- primary mutation transaction.
  for v_target in
    select target.value || jsonb_build_object('ordinal', target.ordinality)
    from jsonb_array_elements(p_targets) with ordinality as target(value, ordinality)
    order by
      target.value->>'table',
      (target.value->>'id')::uuid,
      btrim(target.value->>'version')
  loop
    v_table := v_target->>'table';
    v_id := (v_target->>'id')::uuid;
    v_version := btrim(v_target->>'version');
    v_expected_json_ordered_sha256 :=
      v_target->>'expected_json_ordered_sha256';

    if v_table = 'flows' then
      v_flow := null;
      select flow.*
      into v_flow
      from public.flows as flow
      where flow.id = v_id
        and btrim(flow.version::text) = v_version
        and flow.user_id = p_actor_user_id
        and flow.state_code = 0
      for update;
      if v_flow.id is not null then
        v_snapshot := util.dataset_derivative_rebuild_snapshot(v_flow);
      else
        v_snapshot := null;
      end if;
    else
      v_process := null;
      select process.*
      into v_process
      from public.processes as process
      where process.id = v_id
        and btrim(process.version::text) = v_version
        and process.user_id = p_actor_user_id
        and process.state_code = 0
      for update;
      if v_process.id is not null then
        v_snapshot := util.dataset_derivative_rebuild_snapshot(v_process);
      else
        v_snapshot := null;
      end if;
    end if;

    if v_snapshot is null then
      raise exception using
        errcode = 'P0002',
        message = 'Derivative rebuild batch target is not an owner draft',
        detail = v_table || ':' || v_id::text || '@' || v_version;
    end if;

    if v_snapshot->>'json_sha256'
        is distinct from v_snapshot->>'json_ordered_sha256'
      or v_snapshot->>'json_ordered_sha256'
        is distinct from v_expected_json_ordered_sha256 then
      raise exception using
        errcode = '40001',
        message = 'Derivative rebuild batch desired primary hash drifted',
        detail = v_table || ':' || v_id::text || '@' || v_version;
    end if;

    if exists (
      select 1
      from util.dataset_derivative_rebuild_requests as request
      where request.target_table = v_table
        and request.target_id = v_id
        and request.target_version = v_version
        and request.status not in ('completed', 'stale', 'failed')
    ) then
      raise exception using
        errcode = '55006',
        message = 'Derivative rebuild batch target already has an active fence',
        detail = v_table || ':' || v_id::text || '@' || v_version;
    end if;
  end loop;

  -- One decode pass over the candidate dispatch queue for this bounded batch, built only after
  -- every target above has been fully validated and locked. The cache is a strict candidate
  -- superset: per queue row it records the row id, its ctid version and the target ordinals whose
  -- id appears anywhere in the row's decoded body. The original matcher still decides every
  -- candidate row at delete time, rows absent from the snapshot (new inserts or ctid rewrites)
  -- are always candidates, and no row outside the superset can satisfy the original predicate, so
  -- each target's delete keeps its exact original row set while the body decode is paid once per
  -- batch instead of once per target.
  v_queue_cache := private.dataset_derivative_rebuild_queue_cache(p_targets);

  select jsonb_agg(
    jsonb_build_object(
      'table', target.value->>'table',
      'id', (target.value->>'id')::uuid,
      'version', btrim(target.value->>'version'),
      'expected_json_ordered_sha256',
        target.value->>'expected_json_ordered_sha256',
      'baseline_snapshot_sha256',
        target.value->>'baseline_snapshot_sha256'
    )
    order by
      target.value->>'table',
      (target.value->>'id')::uuid,
      btrim(target.value->>'version')
  )
  into v_normalized_targets
  from jsonb_array_elements(p_targets) as target(value);

  v_plan_request_sha256 := util.dataset_derivative_rebuild_sha256(
    jsonb_build_object(
      'schema_version', v_schema_version,
      'batch_id', p_batch_id,
      'plan_sha256', p_plan_sha256,
      'operation_id', btrim(p_operation_id),
      'reason_code', btrim(p_reason_code),
      'targets', v_normalized_targets
    )::text
  );

  insert into private.command_audit_log (
    command,
    actor_user_id,
    target_table,
    target_id,
    target_version,
    payload
  ) values (
    v_command,
    p_actor_user_id,
    null,
    null,
    null,
    jsonb_build_object(
      'record_type', 'plan_summary',
      'schema_version', v_schema_version,
      'batch_id', p_batch_id,
      'plan_sha256', p_plan_sha256,
      'operation_id', btrim(p_operation_id),
      'target_visibility', 'owner_draft',
      'plan_request_sha256', v_plan_request_sha256,
      'action_count', v_target_count,
      'accepted_count', v_target_count,
      'flows', v_flow_count,
      'processes', v_process_count,
      'reason_code', btrim(p_reason_code),
      'hash_algorithm', 'postgres-jsonb-text-sha256'
    )
  )
  returning id into v_summary_audit_id;

  for v_target in
    select target.value || jsonb_build_object('ordinal', target.ordinality)
    from jsonb_array_elements(p_targets) with ordinality as target(value, ordinality)
    order by target.ordinality
  loop
    v_table := v_target->>'table';
    v_id := (v_target->>'id')::uuid;
    v_version := btrim(v_target->>'version');
    v_ordinal := (v_target->>'ordinal')::integer;
    v_expected_json_ordered_sha256 :=
      v_target->>'expected_json_ordered_sha256';
    v_baseline_snapshot_sha256 := v_target->>'baseline_snapshot_sha256';
    v_snapshot := util.dataset_derivative_rebuild_snapshot(
      v_table,
      v_id,
      v_version
    );

    if v_snapshot is null
      or v_snapshot->>'user_id' is distinct from p_actor_user_id::text
      or v_snapshot->>'state_code' is distinct from '0'
      or v_snapshot->>'json_sha256'
        is distinct from v_expected_json_ordered_sha256
      or v_snapshot->>'json_ordered_sha256'
        is distinct from v_expected_json_ordered_sha256 then
      raise exception using
        errcode = '40001',
        message = 'Derivative rebuild batch primary changed after validation';
    end if;

    v_quarantine := util.quarantine_dataset_derivative_rebuild_target_cached(
      v_table,
      v_id,
      v_version,
      v_queue_cache,
      v_ordinal
    );
    v_request_id := pg_catalog.gen_random_uuid();
    v_action_id := 'batch:' || v_ordinal::text || ':'
      || v_table || ':' || v_id::text || '@' || v_version;
    v_action := jsonb_build_object(
      'schema_version', 'dataset-derivative-rebuild-batch-action.v1',
      'batch_id', p_batch_id,
      'batch_ordinal', v_ordinal,
      'action_id', v_action_id,
      'action', 'rebuild_derivatives',
      'table', v_table,
      'id', v_id,
      'version', v_version,
      'expected_state_code', 0,
      'expected_json_ordered_sha256', v_expected_json_ordered_sha256,
      'baseline_snapshot_sha256', v_baseline_snapshot_sha256,
      'post_write_snapshot_sha256', v_snapshot->>'snapshot_sha256',
      'components', jsonb_build_array('extracted_md', 'embedding_ft'),
      'reason_code', btrim(p_reason_code)
    );
    v_action_request_sha256 := util.dataset_derivative_rebuild_sha256(
      v_action::text
    );

    insert into private.command_audit_log (
      command,
      actor_user_id,
      target_table,
      target_id,
      target_version,
      payload
    ) values (
      v_command,
      p_actor_user_id,
      v_table,
      v_id,
      v_version,
      jsonb_build_object(
        'record_type', 'action',
        'schema_version', v_schema_version,
        'batch_id', p_batch_id,
        'batch_ordinal', v_ordinal,
        'batch_target_count', v_target_count,
        'request_id', v_request_id,
        'plan_sha256', p_plan_sha256,
        'operation_id', btrim(p_operation_id),
        'action_id', v_action_id,
        'target_visibility', 'owner_draft',
        'expected_snapshot_sha256', v_snapshot->>'snapshot_sha256',
        'expected_json_ordered_sha256', v_expected_json_ordered_sha256,
        'baseline_snapshot_sha256', v_baseline_snapshot_sha256,
        'plan_request_sha256', v_plan_request_sha256,
        'action_request_sha256', v_action_request_sha256,
        'reason_code', btrim(p_reason_code),
        'components', jsonb_build_array('extracted_md', 'embedding_ft'),
        'hash_algorithm', 'postgres-jsonb-text-sha256'
      )
    )
    returning id into v_action_audit_id;

    insert into util.dataset_derivative_rebuild_requests (
      id,
      actor_user_id,
      plan_sha256,
      operation_id,
      action_id,
      target_table,
      target_id,
      target_version,
      expected_snapshot_sha256,
      expected_modified_at,
      expected_json_sha256,
      expected_json_ordered_sha256,
      before_extracted_md_sha256,
      before_embedding_ft_sha256,
      before_embedding_ft_at,
      plan_request_sha256,
      action_request_sha256,
      reason_code,
      status,
      phase,
      admitted_at,
      drain_not_before,
      action_audit_id,
      summary_audit_id,
      quarantined_http_requests,
      quarantined_embedding_jobs,
      quarantined_pending_jobs,
      batch_id,
      batch_ordinal,
      batch_target_count,
      source_baseline_snapshot_sha256
    ) values (
      v_request_id,
      p_actor_user_id,
      p_plan_sha256,
      btrim(p_operation_id),
      v_action_id,
      v_table,
      v_id,
      v_version,
      v_snapshot->>'snapshot_sha256',
      (v_snapshot->>'modified_at')::timestamp with time zone,
      v_snapshot->>'json_sha256',
      v_snapshot->>'json_ordered_sha256',
      v_snapshot->>'extracted_md_sha256',
      v_snapshot->>'embedding_ft_sha256',
      (v_snapshot->>'embedding_ft_at')::timestamp with time zone,
      v_plan_request_sha256,
      v_action_request_sha256,
      btrim(p_reason_code),
      'queued',
      'admitted',
      v_now,
      v_now + interval '420 seconds',
      v_action_audit_id,
      v_summary_audit_id,
      coalesce((v_quarantine->>'http_requests')::integer, 0),
      coalesce((v_quarantine->>'embedding_jobs')::integer, 0),
      coalesce((v_quarantine->>'pending_jobs')::integer, 0),
      p_batch_id,
      v_ordinal,
      v_target_count,
      v_baseline_snapshot_sha256
    );

    v_child_ids := v_child_ids || jsonb_build_array(
      jsonb_build_object(
        'ordinal', v_ordinal,
        'table', v_table,
        'id', v_id,
        'version', v_version,
        'request_id', v_request_id,
        'expected_snapshot_sha256', v_snapshot->>'snapshot_sha256'
      )
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'schema_version', v_schema_version,
    'batch_id', p_batch_id,
    'plan_sha256', p_plan_sha256,
    'operation_id', btrim(p_operation_id),
    'plan_request_sha256', v_plan_request_sha256,
    'target_count', v_target_count,
    'flow_count', v_flow_count,
    'process_count', v_process_count,
    'flows', v_flow_count,
    'processes', v_process_count,
    'summary_audit_id', v_summary_audit_id::text,
    'child_request_ids', v_child_ids
  );
exception
  when lock_not_available then
    raise exception using
      errcode = '55P03',
      message = 'Derivative rebuild batch write fence could not be acquired';
end;
$$;

alter function util.admit_dataset_derivative_rebuild_batch(
  uuid,
  uuid,
  text,
  text,
  text,
  jsonb
) owner to postgres;
revoke all on function util.admit_dataset_derivative_rebuild_batch(
  uuid,
  uuid,
  text,
  text,
  text,
  jsonb
) from public, anon, authenticated, service_role;

comment on function util.admit_dataset_derivative_rebuild_batch(
  uuid,
  uuid,
  text,
  text,
  text,
  jsonb
) is
  'Private atomic admission for 1..50 unique owner-draft flow/process derivative children. Every target is validated before any quarantine/audit/request write; batch ids are non-replayable.';
