begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;

select plan(26);

-- ================================================================================================
-- 1. The five protected Time-alias v2 routes keep their exact capability manifest.
-- ================================================================================================
select is(
  (
    select count(*)
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity) = any (array[
      'api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_gate_v2_guarded(uuid,text,text)'::regprocedure,
      'api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_read_v2(uuid)'::regprocedure,
      'api.cmd_dataset_alias_execution_execute_v2(uuid,text)'::regprocedure
    ])
  ),
  5::bigint,
  'all five protected v2 routes carry exactly one capability manifest row'
);
select is(
  (
    select count(*)
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity) = any (array[
      'api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_gate_v2_guarded(uuid,text,text)'::regprocedure,
      'api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_read_v2(uuid)'::regprocedure
    ])
      and manifest.capability_id = 'CLI-ALIAS-02'
      and manifest.allow_authenticated
      and not manifest.allow_anon
      and not manifest.allow_service_role
  ),
  4::bigint,
  'the four actor-facing protected routes are CLI-ALIAS-02 authenticated-only'
);
select is(
  (
    select count(*)
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity)
        = 'api.cmd_dataset_alias_execution_execute_v2(uuid,text)'::regprocedure
      and manifest.capability_id = 'CLI-ALIAS-02'
      and manifest.allow_service_role
      and not manifest.allow_anon
      and not manifest.allow_authenticated
  ),
  1::bigint,
  'the service-only executor callback stays service-role-only with no actor reach'
);
select is(
  (
    select count(*)
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity) = any (array[
      'api.cmd_dataset_alias_execution_preflight_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_gate_v2_guarded(uuid,text,text)'::regprocedure,
      'api.cmd_dataset_alias_execution_admit_v2_guarded(jsonb)'::regprocedure,
      'api.cmd_dataset_alias_execution_read_v2(uuid)'::regprocedure,
      'api.cmd_dataset_alias_execution_execute_v2(uuid,text)'::regprocedure
    ])
      and manifest.capability_id <> 'CLI-ALIAS-02'
  ),
  0::bigint,
  'no other capability maps onto the protected v2 routes'
);

-- This stack holds no enabled CLI client whose capability set equals the documented
-- prior official class, which is exactly the drift-repair precondition: the migration
-- deployed here is therefore a zero-match no-op.
select is(
  (
    select count(*)
    from private.oauth_client_registry as client
    where client.client_kind = 'cli'
      and client.enabled
      and coalesce((
        select array_agg(grant_row.capability_id order by grant_row.capability_id)
          filter (where grant_row.allowed)
        from private.oauth_client_capability_grants as grant_row
        where grant_row.client_id = client.client_id
      ), array[]::text[]) = array[
        'CLI-RPC-01',
        'DB-CORE-READ-01',
        'DB-CORE-WRITE-01',
        'EDGE-BUNDLE-01',
        'NX-CORE-02'
      ]::text[]
  ),
  0::bigint,
  'no enabled CLI client matches the drift-repair precondition, so it is a no-op here'
);

-- ================================================================================================
-- 2. A synthetic client holding the documented prior official class is refused on every
--    protected route by the real pre-request hook (the reproduced hosted RED denial).
-- ================================================================================================
create temporary table cli_alias_oauth_results (
  label text primary key,
  value jsonb not null
) on commit drop;
grant all on cli_alias_oauth_results to service_role;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into cli_alias_oauth_results (label, value)
values (
  'official_create',
  api.svc_oauth_client_configure(
    'issue-677-official-cli',
    'cli',
    true,
    array[
      'CLI-RPC-01',
      'DB-CORE-READ-01',
      'DB-CORE-WRITE-01',
      'EDGE-BUNDLE-01',
      'NX-CORE-02'
    ]
  )
);
insert into cli_alias_oauth_results (label, value)
values (
  'unrelated_create',
  api.svc_oauth_client_configure(
    'issue-677-unrelated-mcp',
    'mcp',
    true,
    array['DB-CORE-READ-01', 'DB-CORE-WRITE-01', 'EDGE-BUNDLE-01']
  )
);
reset role;

select is(
  (
    select array_agg(grant_row.capability_id order by grant_row.capability_id)
      filter (where grant_row.allowed)
    from private.oauth_client_capability_grants as grant_row
    where grant_row.client_id = 'issue-677-official-cli'
  ),
  array[
    'CLI-RPC-01',
    'DB-CORE-READ-01',
    'DB-CORE-WRITE-01',
    'EDGE-BUNDLE-01',
    'NX-CORE-02'
  ]::text[],
  'the synthetic official client holds the documented prior five-capability class'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677","client_id":"issue-677-official-cli"}',
  true
);

select set_config('request.path', '/rpc/cmd_dataset_alias_execution_read_v2', true);
select set_config('request.method', 'POST', true);
select throws_ok(
  'select api.oauth_client_pre_request()',
  '42501',
  'OAuth client is not authorized for this API route',
  'the prior official class is refused on the protected read route (hosted RED denial)'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_preflight_v2_guarded', true);
select throws_ok(
  'select api.oauth_client_pre_request()',
  '42501',
  'OAuth client is not authorized for this API route',
  'the prior official class is refused on the protected preflight route'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_gate_v2_guarded', true);
select throws_ok(
  'select api.oauth_client_pre_request()',
  '42501',
  'OAuth client is not authorized for this API route',
  'the prior official class is refused on the protected gate route'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_admit_v2_guarded', true);
select throws_ok(
  'select api.oauth_client_pre_request()',
  '42501',
  'OAuth client is not authorized for this API route',
  'the prior official class is refused on the protected admit route'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_execute_v2', true);
select throws_ok(
  'select api.oauth_client_pre_request()',
  '42501',
  'OAuth client is not authorized for this API route',
  'the service-only executor callback is unreachable to the OAuth actor'
);

-- The unrelated MCP-class client may never reach the protected lifecycle either.
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677","client_id":"issue-677-unrelated-mcp"}',
  true
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_read_v2', true);
select throws_ok(
  'select api.oauth_client_pre_request()',
  '42501',
  'OAuth client is not authorized for this API route',
  'an unrelated MCP-class client is refused on the protected read route'
);
select set_config('request.path', '/processes', true);
select set_config('request.method', 'GET', true);
select set_config('request.headers', '{"accept-profile":"public"}', true);
select lives_ok(
  'select api.oauth_client_pre_request()',
  'the unrelated MCP-class client keeps its granted public relation read'
);

-- A first-party session without a client_id claim keeps its existing behavior.
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677"}',
  true
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_read_v2', true);
select set_config('request.method', 'POST', true);
select lives_ok(
  'select api.oauth_client_pre_request()',
  'a first-party session without client_id bypasses the OAuth capability hook'
);

-- ================================================================================================
-- 3. The additive CLI-ALIAS-02 grant turns the exact same request green, and the admitted
--    request reaches the application's own null-request refusal with zero writes.
-- ================================================================================================
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into cli_alias_oauth_results (label, value)
values (
  'official_replace',
  api.svc_oauth_client_configure(
    'issue-677-official-cli',
    'cli',
    true,
    array[
      'CLI-ALIAS-02',
      'CLI-RPC-01',
      'DB-CORE-READ-01',
      'DB-CORE-WRITE-01',
      'EDGE-BUNDLE-01',
      'NX-CORE-02'
    ]
  )
);
reset role;

select is(
  (
    select array_agg(grant_row.capability_id order by grant_row.capability_id)
      filter (where grant_row.allowed)
    from private.oauth_client_capability_grants as grant_row
    where grant_row.client_id = 'issue-677-official-cli'
  ),
  array[
    'CLI-ALIAS-02',
    'CLI-RPC-01',
    'DB-CORE-READ-01',
    'DB-CORE-WRITE-01',
    'EDGE-BUNDLE-01',
    'NX-CORE-02'
  ]::text[],
  'the additive repair grants exactly CLI-ALIAS-02 on top of the prior class'
);
select is(
  (
    select count(*)
    from private.oauth_client_registry_audit as audit
    where audit.client_id = 'issue-677-official-cli'
      and audit.action = 'replace'
      and audit.before_state -> 'capabilities' = to_jsonb(array[
        'CLI-RPC-01',
        'DB-CORE-READ-01',
        'DB-CORE-WRITE-01',
        'EDGE-BUNDLE-01',
        'NX-CORE-02'
      ]::text[])
      and audit.after_state -> 'capabilities' = to_jsonb(array[
        'CLI-ALIAS-02',
        'CLI-RPC-01',
        'DB-CORE-READ-01',
        'DB-CORE-WRITE-01',
        'EDGE-BUNDLE-01',
        'NX-CORE-02'
      ]::text[])
  ),
  1::bigint,
  'the repair records exactly one replace audit event with exact before/after state'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677","client_id":"issue-677-official-cli"}',
  true
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_read_v2', true);
select set_config('request.method', 'POST', true);
select lives_ok(
  'select api.oauth_client_pre_request()',
  'the repaired official client passes the hook on the protected read route'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_preflight_v2_guarded', true);
select lives_ok(
  'select api.oauth_client_pre_request()',
  'the repaired official client passes the hook on the protected preflight route'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_gate_v2_guarded', true);
select lives_ok(
  'select api.oauth_client_pre_request()',
  'the repaired official client passes the hook on the protected gate route'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_admit_v2_guarded', true);
select lives_ok(
  'select api.oauth_client_pre_request()',
  'the repaired official client passes the hook on the protected admit route'
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_execute_v2', true);
select throws_ok(
  'select api.oauth_client_pre_request()',
  '42501',
  'OAuth client is not authorized for this API route',
  'the service-only executor callback stays unreachable after the repair'
);

-- The admitted read-only null request now reaches the application and is refused there.
select is(
  api.cmd_dataset_alias_execution_read_v2(null) ->> 'code',
  'ALIAS_EXECUTION_READ_INVALID_REQUEST'::text,
  'the admitted null read reaches the application null-request refusal'
);
select is(
  (api.cmd_dataset_alias_execution_read_v2(null) ->> 'status')::integer,
  400,
  'the application null-request refusal is a client error, not a transport denial'
);
reset role;
select is(
  (
    select count(*)
    from util.dataset_alias_execution_v2_requests
  ),
  0::bigint,
  'the admitted null read writes no protected request rows'
);

-- ================================================================================================
-- 4. The unrelated MCP-class client is untouched by the official repair.
-- ================================================================================================
reset role;
select is(
  (
    select array_agg(grant_row.capability_id order by grant_row.capability_id)
      filter (where grant_row.allowed)
    from private.oauth_client_capability_grants as grant_row
    where grant_row.client_id = 'issue-677-unrelated-mcp'
  ),
  array['DB-CORE-READ-01', 'DB-CORE-WRITE-01', 'EDGE-BUNDLE-01']::text[],
  'the unrelated MCP-class client keeps its exact three-capability class'
);
select is(
  (
    select count(*)
    from private.oauth_client_registry_audit as audit
    where audit.client_id = 'issue-677-unrelated-mcp'
      and audit.action <> 'create'
  ),
  0::bigint,
  'the official repair appends no audit event to the unrelated client'
);

select * from finish();
rollback;
