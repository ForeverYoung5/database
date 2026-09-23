-- Include only inside an outer BEGIN/ROLLBACK on an isolated synthetic stack.
-- pg_temp guard disappears between statements in autocommit mode; seed then
-- refuses before changing any persistent object. No hosted payloads are used.
create temporary table scheduler703_transaction_guard (present boolean) on commit drop;
insert into scheduler703_transaction_guard values (true);

create temporary table scheduler703_targets (
  ordinal integer primary key,
  target_table text not null,
  target_id uuid not null,
  target_version text not null,
  actor_user_id uuid not null,
  batch_id uuid not null,
  request_id uuid,
  primary_snapshot jsonb,
  unique (target_table, target_id, target_version)
) on commit drop;
create temporary table scheduler703_batches (
  batch_id uuid primary key,
  actor_user_id uuid not null,
  target_count integer not null,
  admission jsonb
) on commit drop;
create temporary table scheduler703_outside (
  target_table text,
  target_id uuid,
  row_sha256 text
) on commit drop;

create or replace function pg_temp.scheduler703_seed(
  p_flows integer default 113,
  p_processes integer default 274,
  p_actors integer default 1,
  p_batch_size integer default 50
) returns jsonb language plpgsql as $fixture$
declare
  v_total integer := p_flows + p_processes;
  v_batch record;
  v_targets jsonb;
  v_admission jsonb;
  v_trigger record;
begin
  if to_regclass('pg_temp.scheduler703_transaction_guard') is null then
    raise exception 'scheduler703 fixture requires an outer BEGIN/ROLLBACK';
  end if;
  if p_flows is null or p_processes is null or p_actors is null or p_batch_size is null
    or p_flows < 0 or p_processes < 0 or v_total not between 1 and 1000
    or p_actors not between 1 and least(v_total, 20)
    or p_batch_size not between 1 and 50 then
    raise exception 'scheduler703 fixture bounds are invalid';
  end if;
  if exists (select 1 from pg_temp.scheduler703_targets)
    or exists (select 1 from public.flows)
    or exists (select 1 from public.processes)
    or exists (select 1 from util.dataset_derivative_rebuild_requests
      where status not in ('completed', 'stale', 'failed'))
    or exists (select 1 from pgmq.q_embedding_jobs)
    or exists (select 1 from util.pending_embedding_jobs where status = 'pending')
    or exists (select 1 from net.http_request_queue) then
    raise exception 'scheduler703 requires empty isolated dataset/active/queue tables; it never clears unrelated work';
  end if;

  -- Only the external boundary is replaced. No Vault value is read or changed.
  -- These function definitions and all queue entries are rolled back together.
  execute $ddl$create or replace function util.project_url() returns text
    language sql security definer set search_path = ''
    as 'select ''http://127.0.0.1:9''::text'$ddl$;
  execute $ddl$create or replace function util.project_secret_key() returns text
    language sql security definer set search_path = ''
    as 'select ''synthetic-scheduler703-not-a-credential''::text'$ddl$;

  insert into pg_temp.scheduler703_targets
    (ordinal, target_table, target_id, target_version, actor_user_id, batch_id)
  select n,
    case when n <= p_flows then 'flows' else 'processes' end,
    ('70300000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
    '00.00.001',
    ('703a0000-0000-4000-8000-' || lpad((((n - 1) % p_actors) + 1)::text, 12, '0'))::uuid,
    ('703b0000-0000-4000-8000-' || lpad((
      (((n - 1) % p_actors) + 1)::bigint * 1000000
      + ((n - 1) / p_actors / p_batch_size) + 1
    )::text, 12, '0'))::uuid
  from generate_series(1, v_total) as numbers(n);

  -- Restore each original enabled state, rather than broadly enabling triggers.
  create temporary table scheduler703_seed_triggers on commit drop as
  select tgrelid::regclass as target, tgname, tgenabled
  from pg_trigger where not tgisinternal and (
    (tgrelid = 'public.flows'::regclass and tgname in
      ('flow_dataset_extraction_trigger_insert', 'flows_json_sync_trigger'))
    or (tgrelid = 'public.processes'::regclass and tgname in
      ('process_extract_md_trigger_insert', 'processes_json_sync_trigger'))
  );
  for v_trigger in select * from pg_temp.scheduler703_seed_triggers loop
    execute format('alter table %s disable trigger %I', v_trigger.target, v_trigger.tgname);
  end loop;

  insert into public.flows(id, version, json, json_ordered, user_id,
                          state_code, extracted_md, modified_at)
  select target_id, target_version, jsonb_build_object('fixture', 'scheduler703', 'kind', 'flow', 'ordinal', ordinal),
    jsonb_build_object('fixture', 'scheduler703', 'kind', 'flow', 'ordinal', ordinal)::json,
    actor_user_id, 0, 'synthetic before markdown ' || ordinal, '2026-09-23 00:00:00+00'
  from pg_temp.scheduler703_targets where target_table = 'flows';
  insert into public.processes(id, version, json, json_ordered, user_id,
                              state_code, extracted_md, modified_at)
  select target_id, target_version, jsonb_build_object('fixture', 'scheduler703', 'kind', 'process', 'ordinal', ordinal),
    jsonb_build_object('fixture', 'scheduler703', 'kind', 'process', 'ordinal', ordinal)::json,
    actor_user_id, 0, 'synthetic before markdown ' || ordinal, '2026-09-23 00:00:00+00'
  from pg_temp.scheduler703_targets where target_table = 'processes';

  -- Unadmitted sentinel rows must remain byte-identical, including derivatives.
  insert into public.flows(id, version, json, json_ordered, user_id, state_code, extracted_md, modified_at)
  values ('703fffff-0000-4000-8000-000000000001', '00.00.001', '{"fixture":"outside-flow"}',
          '{"fixture":"outside-flow"}', '703affff-0000-4000-8000-000000000001', 0,
          'outside flow remains unchanged', '2026-09-23 00:00:00+00');
  insert into public.processes(id, version, json, json_ordered, user_id, state_code, extracted_md, modified_at)
  values ('703fffff-0000-4000-8000-000000000002', '00.00.001', '{"fixture":"outside-process"}',
          '{"fixture":"outside-process"}', '703affff-0000-4000-8000-000000000001', 0,
          'outside process remains unchanged', '2026-09-23 00:00:00+00');

  for v_trigger in select * from pg_temp.scheduler703_seed_triggers loop
    execute format('alter table %s %s trigger %I', v_trigger.target,
      case v_trigger.tgenabled when 'D' then 'disable' when 'A' then 'enable always'
        when 'R' then 'enable replica' else 'enable' end, v_trigger.tgname);
  end loop;
  insert into pg_temp.scheduler703_outside
  select 'flows', id, util.dataset_derivative_rebuild_sha256(to_jsonb(row_value)::text)
  from public.flows row_value where id = '703fffff-0000-4000-8000-000000000001'
  union all
  select 'processes', id, util.dataset_derivative_rebuild_sha256(to_jsonb(row_value)::text)
  from public.processes row_value where id = '703fffff-0000-4000-8000-000000000002';

  update pg_temp.scheduler703_targets target
  set primary_snapshot = util.dataset_derivative_rebuild_snapshot(
    target.target_table, target.target_id, target.target_version);
  insert into pg_temp.scheduler703_batches(batch_id, actor_user_id, target_count)
  select batch_id, actor_user_id, count(*)::integer
  from pg_temp.scheduler703_targets group by batch_id, actor_user_id;
  for v_batch in select * from pg_temp.scheduler703_batches order by actor_user_id, batch_id loop
    select jsonb_agg(jsonb_build_object('table', target_table, 'id', target_id,
      'version', target_version, 'expected_json_ordered_sha256', primary_snapshot->>'json_ordered_sha256',
      'baseline_snapshot_sha256', primary_snapshot->>'snapshot_sha256') order by ordinal)
    into v_targets from pg_temp.scheduler703_targets where batch_id = v_batch.batch_id;
    v_admission := util.admit_dataset_derivative_rebuild_batch(v_batch.actor_user_id, v_batch.batch_id,
      util.dataset_derivative_rebuild_sha256('scheduler703:' || v_batch.batch_id::text),
      'scheduler703-synthetic', 'isolated_scheduler_benchmark', v_targets);
    update pg_temp.scheduler703_batches set admission = v_admission where batch_id = v_batch.batch_id;
  end loop;
  update pg_temp.scheduler703_targets target set request_id = request.id
  from util.dataset_derivative_rebuild_requests request
  where request.batch_id = target.batch_id and request.target_table = target.target_table
    and request.target_id = target.target_id and request.target_version = target.target_version;

  -- Simulate elapsed initial drain only. Preserve its exact 420-second interval;
  -- no coordinator condition, runtime deadline, failure drain or fence is changed.
  update util.dataset_derivative_rebuild_requests request
  set admitted_at = admitted_at - interval '421 seconds',
      drain_not_before = drain_not_before - interval '421 seconds'
  where id in (select request_id from pg_temp.scheduler703_targets);
  return jsonb_build_object('simulation', 'synthetic workers; initial drain already elapsed',
    'targets', v_total, 'flows', p_flows, 'processes', p_processes, 'actors', p_actors,
    'batches', (select count(*) from pg_temp.scheduler703_batches));
end;
$fixture$;

create or replace function pg_temp.scheduler703_ideal_worker()
returns jsonb language plpgsql as $fixture$
declare
  v_request record;
  v_markdown text;
  v_vector extensions.vector := ('[' || array_to_string(array_fill('0'::text, array[1024]), ',') || ']')::extensions.vector;
  v_markdowns integer := 0;
  v_embeddings integer := 0;
  v_flow_embeddings integer := 0;
  v_process_embeddings integer := 0;
  v_capacity integer;
  v_mode text;
begin
  -- SIMULATION: an ideal webhook stages output through the real table trigger.
  -- Only requests actually dispatched by the real coordinator are answered.
  for v_request in
    select request.* from util.dataset_derivative_rebuild_requests request
    join pg_temp.scheduler703_targets target on target.request_id = request.id
    where request.status = 'markdown_pending' and request.markdown_request_id is not null
      and not exists (select 1 from net._http_response response where response.id = request.markdown_request_id)
    order by target.ordinal
  loop
    v_markdown := 'scheduler703 synthetic markdown ' || v_request.target_id;
    execute format('update public.%I set extracted_md = $1 where id = $2 and btrim(version::text) = $3', v_request.target_table)
      using v_markdown, v_request.target_id, v_request.target_version;
    insert into net._http_response(id, status_code, content_type, headers, content, timed_out, error_msg, created)
    values (v_request.markdown_request_id, 200, 'application/json', '{}'::jsonb,
      jsonb_build_object('success', true, 'results', jsonb_build_array(jsonb_build_object(
        'index', 0, 'id', v_request.target_id, 'version', v_request.target_version,
        'type', 'UPDATE', 'table', v_request.target_table, 'status', 'success',
        'markdownLength', length(v_markdown))))::text,
      false, null, clock_timestamp());
    delete from net.http_request_queue where id = v_request.markdown_request_id;
    v_markdowns := v_markdowns + 1;
  end loop;

  -- SIMULATION: at most the existing 3 x 3 embedding dispatch allowance per
  -- tick, additionally bounded by the resolved per-table max_in_flight. No
  -- policy row, cron schedule, worker function or coordinator is replaced.
  for v_request in
    select request.*, job.msg_id
    from util.dataset_derivative_rebuild_requests request
    join pg_temp.scheduler703_targets target on target.request_id = request.id
    join pgmq.q_embedding_jobs job on job.msg_id = request.embedding_queue_msg_id
      and job.message->>'requestId' = request.id::text
      and job.message->>'id' = request.target_id::text
      and job.message->>'version' = request.target_version
      and job.message->>'table' = request.target_table
    where request.status = 'embedding_pending'
      and request.markdown_proposal_id is not null
      and not exists (select 1 from util.dataset_derivative_rebuild_proposals proposal
        where proposal.request_id = request.id and proposal.proposal_kind = 'embedding'
          and proposal.status = 'captured')
    order by target.ordinal
  loop
    exit when v_embeddings >= 9;
    select mode, max_in_flight into v_mode, v_capacity
    from util.embedding_queue_policy_for('public', v_request.target_table, 'embedding_ft', 'embedding_ft');
    if v_mode = 'paused' or coalesce(v_capacity, 0) <= 0 then continue; end if;
    if (v_request.target_table = 'flows' and v_flow_embeddings >= v_capacity)
      or (v_request.target_table = 'processes' and v_process_embeddings >= v_capacity) then continue; end if;
    execute format('update public.%I set embedding_ft = $1, embedding_ft_at = $2 where id = $3 and btrim(version::text) = $4', v_request.target_table)
      using v_vector, clock_timestamp(), v_request.target_id, v_request.target_version;
    -- Deleting exactly the request-bound job models the worker ACK. It does
    -- not complete the request: the next real coordinator visit must commit
    -- both proposals with its real permits and create its terminal audit.
    delete from pgmq.q_embedding_jobs where msg_id = v_request.msg_id
      and message->>'requestId' = v_request.id::text;
    v_embeddings := v_embeddings + 1;
    if v_request.target_table = 'flows' then v_flow_embeddings := v_flow_embeddings + 1;
    else v_process_embeddings := v_process_embeddings + 1; end if;
  end loop;
  return jsonb_build_object('simulation', 'ideal worker callbacks and exact ACK only',
    'markdown_callbacks', v_markdowns, 'embedding_acks', v_embeddings,
    'flow_embedding_acks', v_flow_embeddings, 'process_embedding_acks', v_process_embeddings);
end;
$fixture$;
