-- Bounded physical-history profile: 456 genuinely completed synthetic rows
-- plus 387 active (113 Flow / 274 Process) requests. Not hosted latency.
-- Run only on the isolated empty stack. No function, policy or cron is changed
-- except the fixture's transaction-local black-hole external-boundary helpers.
\if :{?invocation_limit}
\else
  \set invocation_limit 25
\endif
\if :{?maximum_ticks}
\else
  \set maximum_ticks 500
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
\ir fixtures/derivative_scheduler703.sql
select plan(10);
select pg_temp.scheduler703_seed(113, 730, 1, 50);

-- SIMULATION ONLY: park the future 387-row cohort while the middle 456 Process
-- requests traverse the real coordinator, proposal capture, permits and commit.
-- Never manufacture terminal history by editing completed/status fields.
create temporary table scheduler703_held on commit drop as
select request.id, request.status, request.phase, request.failure_release_not_before,
       request.updated_at
from util.dataset_derivative_rebuild_requests request
join pg_temp.scheduler703_targets target on target.request_id = request.id
where target.ordinal <= 113 or target.ordinal >= 570;
update util.dataset_derivative_rebuild_requests request
set status = 'dispatching', phase = 'failure_draining',
    failure_release_not_before = clock_timestamp() + interval '1 day'
where id in (select id from pg_temp.scheduler703_held);

create temporary table scheduler703_profile_metrics (
  phase text not null,
  tick integer not null,
  coordinator_call_ms double precision not null,
  visits integer not null,
  phase_completed integer not null,
  failed integer not null,
  primary key (phase, tick)
) on commit drop;

create or replace function pg_temp.scheduler703_run_profile_phase(p_phase text)
returns integer language plpgsql as $profile$
declare
  v_tick integer;
  v_limit integer := current_setting('scheduler703.invocation_limit')::integer;
  v_max integer := current_setting('scheduler703.maximum_ticks')::integer;
  v_goal integer := case when p_phase = 'history' then 456 else 387 end;
  v_started timestamp with time zone;
  v_ms double precision;
  v_visits integer;
  v_completed integer;
  v_failed integer;
begin
  if p_phase not in ('history', 'active') or v_limit not between 1 and 25
    or v_max not between 1 and 500 then
    raise exception 'profile parameters exceed the fixed two-phase/500-tick bound';
  end if;
  for v_tick in 1..v_max loop
    v_started := clock_timestamp();
    v_visits := util.process_dataset_derivative_rebuilds(v_limit);
    v_ms := extract(epoch from (clock_timestamp() - v_started)) * 1000;
    select count(*) filter (where request.status = 'completed' and
        ((p_phase = 'history' and target.ordinal between 114 and 569)
          or (p_phase = 'active' and (target.ordinal <= 113 or target.ordinal >= 570))))::integer,
      count(*) filter (where request.status in ('failed', 'stale'))::integer
    into v_completed, v_failed
    from util.dataset_derivative_rebuild_requests request
    join pg_temp.scheduler703_targets target on target.request_id = request.id;
    insert into pg_temp.scheduler703_profile_metrics
    values (p_phase, v_tick, v_ms, v_visits, v_completed, v_failed);
    perform pg_temp.scheduler703_ideal_worker();
    if v_failed <> 0 then
      raise exception 'profile real coordinator produced % failed/stale requests in phase %', v_failed, p_phase;
    end if;
    if v_completed = v_goal then return v_tick; end if;
  end loop;
  raise exception 'profile phase % did not reach % real completions within % ticks', p_phase, v_goal, v_max;
end;
$profile$;

select pg_temp.scheduler703_run_profile_phase('history');
select is((select count(*)::integer from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_targets target on target.request_id = request.id
  where target.ordinal between 114 and 569 and request.status = 'completed'), 456,
  'all 456 historical Process requests really complete through the coordinator');
select is((select count(*)::integer from util.dataset_derivative_rebuild_proposals proposal
  join pg_temp.scheduler703_targets target on target.request_id = proposal.request_id
  where target.ordinal between 114 and 569 and proposal.status = 'committed'), 912,
  'historical population has 912 real committed proposals, not synthetic terminal flags');
select is((select count(*)::integer from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_held held on held.id = request.id
  where request.status = 'dispatching' and request.phase = 'failure_draining'
    and request.markdown_request_id is null and request.embedding_queue_msg_id is null), 387,
  'all held synthetic targets stayed pending without dispatch during history construction');

-- Retain byte snapshots of genuinely completed request/proposal/audit rows.
create temporary table scheduler703_history_rows on commit drop as
select request.id, to_jsonb(request) as request_row,
  (select jsonb_agg(to_jsonb(proposal) order by proposal.id)
    from util.dataset_derivative_rebuild_proposals proposal where proposal.request_id = request.id) as proposals,
  (select jsonb_agg(to_jsonb(audit) order by audit.id) from private.command_audit_log audit
    where audit.command = 'cmd_dataset_derivative_rebuild_terminal'
      and audit.payload->>'request_id' = request.id::text) as terminal_audits
from util.dataset_derivative_rebuild_requests request
join pg_temp.scheduler703_targets target on target.request_id = request.id
where target.ordinal between 114 and 569;

-- Restore only the 387 explicitly parked simulation rows to their real admitted
-- state. No completed request is edited. Their 420-second initial drain elapsed
-- in the fixture; it is not shortened in the implementation.
update util.dataset_derivative_rebuild_requests request
set status = held.status, phase = held.phase,
    failure_release_not_before = held.failure_release_not_before,
    updated_at = held.updated_at
from pg_temp.scheduler703_held held
where request.id = held.id and request.status = 'dispatching' and request.phase = 'failure_draining';
select is((select count(*)::integer from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_held held on held.id = request.id where request.status = 'queued'), 387,
  'profile starts with exact 456 completed history plus 387 active requests');

-- Function-level BUFFERS includes the real coordinator's nested work. Restore
-- the savepoint so this diagnostic call cannot alter the measured tick cohort.
savepoint scheduler703_explain;
explain (analyze, buffers, costs, timing, summary)
select * from private.pick_dataset_derivative_rebuild_request(array[]::uuid[], 'ready', true, clock_timestamp());
explain (analyze, buffers, costs, timing, summary)
select util.process_dataset_derivative_rebuilds(current_setting('scheduler703.invocation_limit')::integer);
rollback to savepoint scheduler703_explain;

-- SQL-function EXPLAIN may hide its scan/join nodes behind Function Scan.
-- Explain the exact installed SQL body too, replacing only formal parameter
-- names with bound parameters. No checked-in copy/model of the selector exists.
create or replace function pg_temp.scheduler703_explain_installed_selector()
returns setof text language plpgsql as $profile$
declare
  v_body text;
begin
  select proc.prosrc into v_body from pg_proc proc
  join pg_language language on language.oid = proc.prolang
  where proc.oid = 'private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamp with time zone)'::regprocedure
    and language.lanname = 'sql' and not proc.prosecdef;
  if v_body is null then raise exception 'expected current SQL SECURITY INVOKER selector'; end if;
  v_body := regexp_replace(v_body, '\mp_seen\M', '$1', 'g');
  v_body := regexp_replace(v_body, '\mp_lane\M', '$2', 'g');
  v_body := regexp_replace(v_body, '\mp_allow_external\M', '$3', 'g');
  v_body := regexp_replace(v_body, '\mp_now\M', '$4', 'g');
  return query execute 'explain (analyze, buffers, costs, timing, summary) ' || v_body
    using array[]::uuid[], 'ready'::text, true, clock_timestamp();
end;
$profile$;
select * from pg_temp.scheduler703_explain_installed_selector();

select pg_temp.scheduler703_run_profile_phase('active');
select is((select count(*)::integer from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_held held on held.id = request.id where request.status = 'completed'), 387,
  'active phase completes all 387 through actual coordinator visits with history present');
select ok(not exists (
  select 1 from pg_temp.scheduler703_history_rows history
  join util.dataset_derivative_rebuild_requests request on request.id = history.id
  where to_jsonb(request) is distinct from history.request_row
    or (select jsonb_agg(to_jsonb(proposal) order by proposal.id)
      from util.dataset_derivative_rebuild_proposals proposal where proposal.request_id = request.id) is distinct from history.proposals
    or (select jsonb_agg(to_jsonb(audit) order by audit.id) from private.command_audit_log audit
      where audit.command = 'cmd_dataset_derivative_rebuild_terminal'
        and audit.payload->>'request_id' = request.id::text) is distinct from history.terminal_audits),
  'the entire 456-row completed request/proposal/audit history stays unchanged');
select ok((select bool_and((proof->>'causal_terminal_proof')::boolean
  and (proof->>'invalid_proof_count')::integer = 0)
  from pg_temp.scheduler703_batches batch
  cross join lateral util.read_dataset_derivative_rebuild_batch_any(batch.actor_user_id, batch.batch_id) proof),
  'all 843 requests have actual causal terminal proof after both phases');
select ok((select bool_and(util.dataset_derivative_rebuild_primary_matches(request))
  from util.dataset_derivative_rebuild_requests request
  join pg_temp.scheduler703_targets target on target.request_id = request.id),
  'all 843 primary fingerprints survive both phases unchanged');
select ok((select max(tick) <= 500 and max(visits) <= 25 from pg_temp.scheduler703_profile_metrics),
  'both profile phases remain bounded to 500 ticks and 25 visits per call');
select ok((select count(*) = 843 and count(distinct request_id) = 843 from pg_temp.scheduler703_targets)
  and not exists (select 1 from pg_temp.scheduler703_targets target
    left join private.command_audit_log audit on audit.command = 'cmd_dataset_derivative_rebuild_terminal'
      and audit.payload->>'request_id' = target.request_id::text
    group by target.request_id having count(audit.id) <> 1),
  'no duplicate terminal request/audit is manufactured during history construction or active profiling');

select diag(jsonb_build_object('original_jit_profile', current_setting('scheduler703.original_jit_profile')::jsonb, 'jit', current_setting('jit'), 'evidence', 'isolated-synthetic; real SQL history and ideal external workers; not hosted p95',
  'history_rows', 456, 'active_rows', 387, 'active_flows', 113, 'active_processes', 274,
  'physical_requests', 843, 'phase', phase, 'ticks', max(tick), 'visits', sum(visits),
  'coordinator_call_ms_p50', percentile_cont(0.50) within group (order by coordinator_call_ms),
  'coordinator_call_ms_p95', percentile_cont(0.95) within group (order by coordinator_call_ms),
  'coordinator_call_ms_max', max(coordinator_call_ms),
  'invocation_limit', current_setting('scheduler703.invocation_limit')::integer,
  'rollback_only', true)::text)
from pg_temp.scheduler703_profile_metrics group by phase order by phase;
select * from finish();
rollback;
