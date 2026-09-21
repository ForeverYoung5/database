-- Foundry #60 / Database #673 — Time alias v2 wire RED baseline.
--
-- Purpose: pin the frozen v1 contract (must stay green forever) and the v2 contract surface that is
-- RED until the v2 wire is agreed (see /tmp/foundry60-v2-wire-proposal.md §7) and implemented. A
-- v2-shaped payload is refused by the v1 façade with a stable envelope code; v2 must admit a
-- single-dimension plan with zero flow-property actions and must fail closed on count drift.
--
-- The real cohort fixture (113 flows / 274 processes / 654 exchanges / 4,147 unrelated exchanges)
-- extends this file once the wire is confirmed; nothing here writes business data and the whole run
-- is rolled back.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;

select plan(14);

-- A. v1 public surface stays exactly as deployed (green today, regression guard).
select has_function(
  'api',
  'cmd_dataset_alias_execution_preflight_guarded',
  array['jsonb'],
  'v1 protected preflight remains exposed'
);
select has_function(
  'api',
  'cmd_dataset_alias_execution_gate_guarded',
  array['uuid', 'text', 'text'],
  'v1 protected gate remains exposed'
);
select has_function(
  'api',
  'cmd_dataset_alias_execution_admit_guarded',
  array['jsonb'],
  'v1 protected admit remains exposed'
);
select has_function(
  'api',
  'cmd_dataset_alias_execution_read',
  array['uuid'],
  'v1 protected read remains exposed'
);

-- B. v1 executors keep their frozen constants (byte-level markers, not a whole-body hash).
select ok(
  position(
    'dataset-alias-plan.v1'
    in pg_get_functiondef('private.cmd_dataset_alias_plan_guarded(jsonb)'::regprocedure)
  ) > 0,
  'v1 plan executor still pins the plan schema version'
);
select ok(
  position(
    'ALIAS_BATCH_INVALID_COUNTS'
    in pg_get_functiondef('private.cmd_dataset_alias_batch_guarded(jsonb)'::regprocedure)
  ) > 0,
  'v1 batch executor still pins its exact-count failure code'
);
select ok(
  position(
    '0.00011415525114155251'
    in pg_get_functiondef('private.cmd_dataset_alias_batch_guarded(jsonb)'::regprocedure)
  ) > 0,
  'v1 batch executor still pins the reviewed hour-to-year factor'
);

select ok(
  position(
    'share row exclusive'
    in lower(pg_get_functiondef('private.cmd_dataset_alias_batch_guarded(jsonb)'::regprocedure))
  ) > 0
  and position(
    'public.flowproperties, public.flows, public.processes'
    in pg_get_functiondef('private.cmd_dataset_alias_batch_guarded(jsonb)'::regprocedure)
  ) > 0,
  'v1 batch executor still pins its exact three-table lock statement'
);

-- C. v1 must refuse a v2 envelope: the current cohort can never travel the historical path.
-- The executors return their frozen envelopes (they never raise for a refused request). They are private
-- by design, so the suite reaches them through a definer-owned probe exactly as the behaviour suite does.
create or replace function pg_temp.v2_plan_probe(p_plan jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return private.cmd_dataset_alias_plan_v2_guarded(p_plan);
end
$$;
grant execute on function pg_temp.v2_plan_probe(jsonb) to authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.email', 'fixture@example.invalid', true);
select set_config('role', 'authenticated', true);
select is(
  (
    api.cmd_dataset_alias_execution_preflight_guarded(
      '{"schema_version":"dataset-alias-plan.v2"}'::jsonb
    )
  )->>'code',
  'ALIAS_EXECUTION_PREFLIGHT_INVALID_REQUEST',
  'v1 refuses a v2-shaped plan with its stable code and no writes'
);

-- D. v2 contract surface (RED until the wire is confirmed and implemented).
select has_function(
  'private',
  'cmd_dataset_alias_plan_v2_guarded',
  array['jsonb'],
  'v2 plan executor exists'
);
select has_function(
  'private',
  'cmd_dataset_alias_batch_v2_guarded',
  array['jsonb'],
  'v2 batch executor exists'
);
select has_function(
  'api',
  'cmd_dataset_alias_execution_preflight_v2_guarded',
  array['jsonb'],
  'v2 protected preflight is exposed'
);
select is(
  (pg_temp.v2_plan_probe('{}'::jsonb) ->> 'code'),
  'ALIAS_V2_PLAN_INVALID',
  'v2 refuses an empty plan with its stable code'
);
-- The single `time` dimension and zero flow-property actions of this cohort shape are never the reason for
-- a refusal: the envelope check fails on the missing identity/evidence/action list, and the plan behaviour
-- suite proves the well-formed version of this shape applies on real rows.
select is(
  (pg_temp.v2_plan_probe(
      '{"schema_version":"dataset-alias-plan.v2","counts":{"flowproperty_count":0},"dimensions":[{"dimension":"time"}]}'::jsonb
    ) ->> 'code'),
  'ALIAS_V2_PLAN_INVALID',
  'a plan without identity, evidence and actions is refused as an invalid envelope'
);

select * from finish();
rollback;
