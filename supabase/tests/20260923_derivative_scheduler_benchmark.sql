-- Isolated synthetic scheduler throughput, NOT real worker latency or hosted p95.
-- Candidate: psql -v ON_ERROR_STOP=1 -v invocation_limit=25 -v maximum_ticks=190 -f ...
-- Original deployed definition: invocation_limit=5, maximum_ticks=1000 (>=310 ticks).
-- All definitions, seeds, network queue entries, proposals and output writes roll back.
\if :{?invocation_limit}
\else
  \set invocation_limit 25
\endif
\if :{?maximum_ticks}
\else
  \set maximum_ticks 190
\endif
\if :{?fixture_actors}
\else
  \set fixture_actors 1
\endif

begin;
-- Match the qualified production profile (Database #703 read-only receipt):
-- hosted PostgreSQL has jit=off. Keep this transaction-local; availability
-- alone is not provider proof because pg_jit_available() also checks jit=on.
do $profile$
begin
  perform set_config('scheduler703.original_jit_profile', jsonb_build_object(
    'jit', current_setting('jit'), 'available_at_capture', pg_jit_available()
  )::text, true);
end;
$profile$;
set local jit = off;
set local statement_timeout = '10min';
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select set_config('scheduler703.invocation_limit', :'invocation_limit', true);
select set_config('scheduler703.maximum_ticks', :'maximum_ticks', true);
select set_config('scheduler703.fixture_actors', :'fixture_actors', true);
\ir fixtures/derivative_scheduler703.sql

select plan(17);
select pg_temp.scheduler703_seed(113, 274, current_setting('scheduler703.fixture_actors')::integer, 50);
select is((select count(*)::integer from pg_temp.scheduler703_targets), 387,
  'synthetic cohort has exactly 113 Flow and 274 Process targets');
select is((select count(*)::integer from pg_temp.scheduler703_targets where target_table = 'flows'), 113,
  'Flow membership matches the frozen synthetic shape');
select is((select count(*)::integer from pg_temp.scheduler703_targets where target_table = 'processes'), 274,
  'Process membership matches the frozen synthetic shape');
select ok((select max(target_count) <= 50 from pg_temp.scheduler703_batches)
  and (current_setting('scheduler703.fixture_actors')::integer <> 1
    or (select count(*) = 8 from pg_temp.scheduler703_batches)),
  'every batch is bounded by 50 and the single-actor cohort has exactly eight batches');
select ok((select bool_and(drain_not_before - admitted_at = interval '420 seconds')
  from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_targets target on target.request_id = request.id),
  'fixture simulates elapsed time while preserving the original 420-second drain interval');

create temporary table scheduler703_tick_metrics (
  tick integer primary key,
  visits integer not null,
  external_progress integer not null,
  waiting_updates integer not null,
  terminal integer not null,
  failed integer not null,
  coordinator_call_ms double precision not null,
  worker jsonb not null
) on commit drop;
create temporary table scheduler703_before on commit drop as
select request.id, request.status, request.phase, request.updated_at,
       request.markdown_request_id, request.embedding_queue_msg_id, request.embedding_pending_job_id
from util.dataset_derivative_rebuild_requests request
join pg_temp.scheduler703_targets target on target.request_id = request.id
with no data;

do $benchmark$
declare
  v_tick integer;
  v_limit integer := current_setting('scheduler703.invocation_limit')::integer;
  v_max integer := current_setting('scheduler703.maximum_ticks')::integer;
  v_visits integer;
  v_external integer;
  v_waiting integer;
  v_terminal integer;
  v_failed integer;
  v_started timestamp with time zone;
  v_call_ms double precision;
  v_worker jsonb;
begin
  if v_limit not between 1 and 25 or v_max not between 1 and 2000 then
    raise exception 'benchmark invocation_limit or maximum_ticks is outside its explicit bound';
  end if;
  for v_tick in 1..v_max loop
    truncate pg_temp.scheduler703_before;
    insert into pg_temp.scheduler703_before
    select request.id, request.status, request.phase, request.updated_at,
           request.markdown_request_id, request.embedding_queue_msg_id, request.embedding_pending_job_id
    from util.dataset_derivative_rebuild_requests request
    join pg_temp.scheduler703_targets target on target.request_id = request.id;

    -- This is the actual installed coordinator, never a copied selector/model.
    v_started := clock_timestamp();
    v_visits := util.process_dataset_derivative_rebuilds(v_limit);
    v_call_ms := extract(epoch from (clock_timestamp() - v_started)) * 1000;
    select count(*) filter (where
        request.markdown_request_id is distinct from before.markdown_request_id
        or (before.status = 'markdown_pending' and request.status = 'embedding_pending'))::integer,
      count(*) filter (where request.status = before.status and request.phase = before.phase
        and request.updated_at is distinct from before.updated_at)::integer,
      count(*) filter (where request.status = 'completed')::integer,
      count(*) filter (where request.status in ('failed', 'stale'))::integer
    into v_external, v_waiting, v_terminal, v_failed
    from util.dataset_derivative_rebuild_requests request
    join pg_temp.scheduler703_before before on before.id = request.id;

    v_worker := pg_temp.scheduler703_ideal_worker();
    insert into pg_temp.scheduler703_tick_metrics
    values (v_tick, v_visits, v_external, v_waiting, v_terminal, v_failed, v_call_ms, v_worker);
    exit when v_terminal = 387 or v_failed <> 0;
  end loop;
end;
$benchmark$;

select ok((select max(visits) <= least(current_setting('scheduler703.invocation_limit')::integer, 25)
  and min(visits) >= 0 from pg_temp.scheduler703_tick_metrics),
  'each real invocation respects p_limit as visits and the absolute 25 ceiling');
select ok((select max(external_progress) <= 5 from pg_temp.scheduler703_tick_metrics),
  'per tick Markdown dispatch plus embedding/pending admission never exceeds five');
select ok((select max(waiting_updates) <= 5 from pg_temp.scheduler703_tick_metrics),
  'per tick waiting audits stay within five');
select ok((select max((worker->>'embedding_acks')::integer) <= 9 from pg_temp.scheduler703_tick_metrics),
  'ideal-worker simulation does not exceed the existing three-by-three dispatch allowance');
select is((select count(*)::integer from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_targets target on target.request_id = request.id where request.status = 'completed'), 387,
  'all 387 requests reach actual coordinator terminal completion within the tick budget');
select is((select count(*)::integer from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_targets target on target.request_id = request.id where request.status in ('failed', 'stale')), 0,
  'no failed or stale synthetic requests');
select ok((current_setting('scheduler703.invocation_limit')::integer <> 5
    or (select max(tick) >= 310 from pg_temp.scheduler703_tick_metrics))
  and (select max(tick) <= current_setting('scheduler703.maximum_ticks')::integer from pg_temp.scheduler703_tick_metrics),
  'baseline five-visit throughput needs at least 310 ticks; selected run stays inside its explicit ceiling');
select ok((select bool_and((proof->>'causal_terminal_proof')::boolean
    and coalesce((proof->>'invalid_proof_count')::integer, 0) = 0)
  from pg_temp.scheduler703_batches batch
  cross join lateral util.read_dataset_derivative_rebuild_batch_any(batch.actor_user_id, batch.batch_id) proof),
  'all exact real batch readers prove committed proposals, terminal audit and zero queue residue');
select ok((select bool_and(
  (util.dataset_derivative_rebuild_snapshot(target.target_table, target.target_id, target.target_version)
    - array['snapshot_sha256','extracted_md_sha256','embedding_ft_sha256','embedding_ft_at'])
  = (target.primary_snapshot - array['snapshot_sha256','extracted_md_sha256','embedding_ft_sha256','embedding_ft_at']))
  from pg_temp.scheduler703_targets target),
  'all frozen primary identity, owner, state, JSON hashes and modified timestamps remain unchanged');
select ok(not exists (
  select 1 from pg_temp.scheduler703_outside outside_row
  left join (select 'flows'::text as target_table, id,
      util.dataset_derivative_rebuild_sha256(to_jsonb(row_value)::text) as row_sha256
    from public.flows row_value
    union all select 'processes', id, util.dataset_derivative_rebuild_sha256(to_jsonb(row_value)::text)
    from public.processes row_value) current_row
    on current_row.target_table = outside_row.target_table and current_row.id = outside_row.target_id
  where current_row.row_sha256 is distinct from outside_row.row_sha256)
  and (select count(*) from public.flows) = 114 and (select count(*) from public.processes) = 275,
  'all out-of-scope synthetic rows and total source membership remain unchanged');
select ok((select count(*) = 387 and count(distinct request_id) = 387 from pg_temp.scheduler703_targets)
  and not exists (select 1 from pg_temp.scheduler703_targets target
    left join private.command_audit_log audit on audit.command = 'cmd_dataset_derivative_rebuild_terminal'
      and audit.payload->>'request_id' = target.request_id::text
    group by target.request_id having count(audit.id) <> 1),
  'each target has one request and exactly one real terminal audit, without duplicate completion');
select ok((select count(*) = 774 and bool_and(proposal.status = 'committed')
  from util.dataset_derivative_rebuild_proposals proposal
  join pg_temp.scheduler703_targets target on target.request_id = proposal.request_id),
  'exactly one Markdown and embedding proposal pair per target commits through the real permits');

select diag(jsonb_build_object('original_jit_profile', current_setting('scheduler703.original_jit_profile')::jsonb, 'jit', current_setting('jit'), 'evidence', 'isolated-synthetic ideal-worker scheduling; not hosted latency',
  'coordinator_sha256', util.dataset_derivative_rebuild_sha256(pg_get_functiondef('util.process_dataset_derivative_rebuilds(integer)'::regprocedure)),
  'invocation_limit', current_setting('scheduler703.invocation_limit')::integer,
  'actors', current_setting('scheduler703.fixture_actors')::integer,
  'ticks', (select max(tick) from pg_temp.scheduler703_tick_metrics),
  'total_visits', (select sum(visits) from pg_temp.scheduler703_tick_metrics),
  'maximum_visits', (select max(visits) from pg_temp.scheduler703_tick_metrics),
  'maximum_external_progress', (select max(external_progress) from pg_temp.scheduler703_tick_metrics),
  'maximum_waiting_updates', (select max(waiting_updates) from pg_temp.scheduler703_tick_metrics),
  'coordinator_call_ms_p50', (select percentile_cont(0.50) within group (order by coordinator_call_ms) from pg_temp.scheduler703_tick_metrics),
  'coordinator_call_ms_p95', (select percentile_cont(0.95) within group (order by coordinator_call_ms) from pg_temp.scheduler703_tick_metrics),
  'coordinator_call_ms_max', (select max(coordinator_call_ms) from pg_temp.scheduler703_tick_metrics),
  'terminal', (select max(terminal) from pg_temp.scheduler703_tick_metrics),
  'rollback_only', true)::text);
select * from finish();
rollback;
