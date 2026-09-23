-- Reviewed deployment operation, separate from schema migration transaction rules.
-- Render the single placeholder with BASE64(UTF8(JSON(plan))) using a strict
-- base64 encoder, never SQL/string interpolation of untrusted fields.
-- Run only after a read-only probe proves this transport preserves the explicit
-- transaction/isolation. The caller owns project binding and durable fsync'd
-- before/plan/attempt/after records. No automatic mutation retry is permitted.
-- An uncertain response requires fresh read-only reconciliation, not replay.
-- Roll back this activation (rollback5) BEFORE reverting the #703 schema/code.

begin isolation level repeatable read;
set local lock_timeout = '5s';
set local statement_timeout = '15s';

do $activate$
declare
  v_plan jsonb := convert_from(decode('__SCHEDULER703_PLAN_BASE64__','base64'),'UTF8')::jsonb;
  v_before jsonb;
  v_after jsonb;
  v_count integer;
  v_desired text;
  v_coordinator regprocedure := 'util.process_dataset_derivative_rebuilds(integer)'::regprocedure;
  v_selector regprocedure := 'private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamptz)'::regprocedure;
  v_current_head text;
begin
  if current_setting('transaction_isolation') <> 'repeatable read' then
    raise exception 'Scheduler activation transport did not preserve REPEATABLE READ';
  end if;
  if jsonb_typeof(v_plan) <> 'object'
    or (select array_agg(key order by key) from jsonb_object_keys(v_plan) key) <>
      array['expected_coordinator_sha256','expected_job','expected_migration_version',
            'expected_project_url_sha256','expected_selector_sha256','operation','schema_version']::text[]
    or exists(select 1 from jsonb_each(v_plan) entry where entry.key<>'expected_job'
      and jsonb_typeof(entry.value)<>'string')
    or v_plan->>'schema_version' is distinct from 'database.derivative-scheduler703-operation.v1'
    or not coalesce(v_plan->>'operation' in ('enable25','rollback5'),false)
    or jsonb_typeof(v_plan->'expected_job') <> 'object'
    or v_plan->>'expected_coordinator_sha256' !~ '^[a-f0-9]{64}$'
    or v_plan->>'expected_selector_sha256' !~ '^[a-f0-9]{64}$'
    or v_plan->>'expected_project_url_sha256' !~ '^[a-f0-9]{64}$'
    or v_plan->>'expected_migration_version' !~ '^[0-9]{14}$' then
    raise exception 'Scheduler activation plan is invalid';
  end if;
  select max(version) into v_current_head from supabase_migrations.schema_migrations;
  if v_current_head is distinct from v_plan->>'expected_migration_version'
    or encode(extensions.digest(pg_get_functiondef(v_coordinator),'sha256'),'hex')
      is distinct from v_plan->>'expected_coordinator_sha256'
    or encode(extensions.digest(pg_get_functiondef(v_selector),'sha256'),'hex')
      is distinct from v_plan->>'expected_selector_sha256'
    or encode(extensions.digest(util.project_url(),'sha256'),'hex')
      is distinct from v_plan->>'expected_project_url_sha256'
    or pg_get_function_arguments(v_coordinator) <> 'p_limit integer DEFAULT 5'
    or not exists(select 1 from pg_attribute where
      attrelid='util.dataset_derivative_rebuild_requests'::regclass
      and attname='scheduler_selected_at' and not attisdropped and not attnotnull
      and atttypid='timestamp with time zone'::regtype) then
    raise exception 'Scheduler activation source, project or schema binding changed';
  end if;
  select count(*) into v_count from cron.job where jobname='process-dataset-derivative-rebuilds';
  if v_count <> 1 then raise exception 'Scheduler activation job identity is ambiguous'; end if;
  select to_jsonb(job) into v_before from cron.job job where jobname='process-dataset-derivative-rebuilds';
  if v_before is distinct from v_plan->'expected_job' or v_before->>'schedule' <> '* * * * *' then
    raise exception 'Scheduler activation exact before job changed';
  end if;
  if v_plan->>'operation'='enable25' then
    if v_before->>'command' not in ('select util.process_dataset_derivative_rebuilds();',
                                    'select util.process_dataset_derivative_rebuilds(5);') then
      raise exception 'Scheduler activation requires a reviewed five-visit source command';
    end if;
    v_desired := 'select util.process_dataset_derivative_rebuilds(25);';
  else
    if v_before->>'command' <> 'select util.process_dataset_derivative_rebuilds(25);' then
      raise exception 'Scheduler rollback requires the exact twenty-five-visit source command';
    end if;
    v_desired := 'select util.process_dataset_derivative_rebuilds();';
  end if;

  -- Another committed writer since this transaction's snapshot causes 40001
  -- inside this supported API. Do not catch/retry serialization failures.
  perform cron.alter_job((v_before->>'jobid')::bigint, command := v_desired);

  select count(*) into v_count from cron.job where jobname='process-dataset-derivative-rebuilds';
  select to_jsonb(job) into v_after from cron.job job where jobid=(v_before->>'jobid')::bigint;
  if v_count <> 1 or v_after is distinct from
    jsonb_set(v_before,'{command}',to_jsonb(v_desired),false) then
    raise exception 'Scheduler activation after job does not match the exact reviewed change';
  end if;
end;
$activate$;

commit;
