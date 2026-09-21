#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
migration="$repo_root/supabase/migrations/20260922010000_grant_official_cli_alias_oauth_capability.sql"
prior_migration_head="20260921190000"

if [[ ! -f "$migration" ]]; then
  echo "Issue #677 migration is missing: $migration" >&2
  exit 1
fi

database_url="$(
  supabase status --output env \
    | sed -n 's/^DB_URL="\([^"]*\)"$/\1/p'
)"

if [[ -z "$database_url" ]]; then
  echo "unable to resolve the local Supabase DB_URL" >&2
  exit 1
fi

cd "$repo_root"
supabase db reset --version "$prior_migration_head" --no-seed

# No matching environment client is a valid Preview/local no-op.
psql "$database_url" -v ON_ERROR_STOP=1 -f "$migration"

psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
do $verify_zero_match_noop$
begin
  if exists (select 1 from private.oauth_client_registry) then
    raise exception 'Issue #677 zero-match run provisioned a client';
  end if;
  if exists (select 1 from private.oauth_client_registry_audit) then
    raise exception 'Issue #677 zero-match run appended an audit event';
  end if;
end
$verify_zero_match_noop$;
SQL

# The documented prior official class plus one unrelated MCP-class client.
psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
select api.svc_oauth_client_configure(
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
);
select api.svc_oauth_client_configure(
  'issue-677-unrelated-mcp',
  'mcp',
  true,
  array['DB-CORE-READ-01', 'DB-CORE-WRITE-01', 'EDGE-BUNDLE-01']
);
SQL

# RED: the deployed prior class is refused by the real pre-request hook with a
# client_id-bearing session, exactly as the hosted official OAuth session was.
if red_output="$(
  psql "$database_url" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose 2>&1 <<'SQL'
set role authenticated;
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677","client_id":"issue-677-official-cli"}',
  false
);
select set_config('request.path', '/rpc/cmd_dataset_alias_execution_read_v2', false);
select set_config('request.method', 'POST', false);
select api.oauth_client_pre_request();
SQL
)"; then
  echo "Issue #677 RED session unexpectedly passed the pre-request hook" >&2
  exit 1
fi

if [[ "$red_output" != *"OAuth client is not authorized for this API route"* ]]; then
  echo "Issue #677 RED session failed for an unexpected reason: $red_output" >&2
  exit 1
fi

if [[ "$red_output" != *"42501"* ]]; then
  echo "Issue #677 RED session did not fail with SQLSTATE 42501: $red_output" >&2
  exit 1
fi

# The transport gate is the only blocker: the same admitted request already
# reaches the application's own null-request refusal with zero writes.
psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
do $verify_direct_application_refusal$
declare
  v_result jsonb;
begin
  set local role authenticated;
  perform set_config(
    'request.jwt.claims',
    '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677","client_id":"issue-677-official-cli"}',
    true
  );
  v_result := api.cmd_dataset_alias_execution_read_v2(null);
  reset role;
  if v_result ->> 'code' <> 'ALIAS_EXECUTION_READ_INVALID_REQUEST'
     or (v_result ->> 'status')::integer <> 400 then
    raise exception 'Issue #677 direct null read did not reach the application refusal: %', v_result;
  end if;
  if exists (select 1 from util.dataset_alias_execution_v2_requests)
     or exists (select 1 from util.dataset_alias_execution_v2_preflights) then
    raise exception 'Issue #677 direct null read wrote protected rows';
  end if;
end
$verify_direct_application_refusal$;
SQL

# Hold the capability table so the migration remains open after acquiring its
# registry lock. A concurrent facade call must time out instead of introducing
# a phantom candidate inside the selection/mutation window.
psql "$database_url" -v ON_ERROR_STOP=1 -c \
  "begin; lock table private.oauth_client_capability_grants in access exclusive mode; select pg_sleep(4); commit" \
  >/dev/null &
capability_lock_pid=$!

for _ in {1..30}; do
  capability_lock_count="$(
    psql "$database_url" -v ON_ERROR_STOP=1 -Atc \
      "select count(*) from pg_locks where relation = 'private.oauth_client_capability_grants'::regclass and mode = 'AccessExclusiveLock' and granted"
  )"
  [[ "$capability_lock_count" == "1" ]] && break
  sleep 0.1
done

if [[ "$capability_lock_count" != "1" ]]; then
  echo "Issue #677 could not establish the concurrency test blocker" >&2
  wait "$capability_lock_pid" || true
  exit 1
fi

psql "$database_url" -v ON_ERROR_STOP=1 -f "$migration" >/dev/null &
migration_pid=$!

for _ in {1..30}; do
  registry_lock_count="$(
    psql "$database_url" -v ON_ERROR_STOP=1 -Atc \
      "select count(*) from pg_locks where relation = 'private.oauth_client_registry'::regclass and mode = 'ShareRowExclusiveLock' and granted"
  )"
  [[ "$registry_lock_count" == "1" ]] && break
  sleep 0.1
done

if [[ "$registry_lock_count" != "1" ]]; then
  echo "Issue #677 migration did not acquire the registry serialization lock" >&2
  wait "$capability_lock_pid" || true
  wait "$migration_pid" || true
  exit 1
fi

if concurrent_output="$(
  PGOPTIONS='-c statement_timeout=500ms' psql "$database_url" -v ON_ERROR_STOP=1 -c \
    "select api.svc_oauth_client_configure('issue-677-concurrent-client', 'cli', true, array['CLI-RPC-01', 'DB-CORE-READ-01', 'DB-CORE-WRITE-01', 'EDGE-BUNDLE-01', 'NX-CORE-02'])" \
    2>&1
)"; then
  echo "Issue #677 concurrent client configuration unexpectedly crossed the migration lock" >&2
  wait "$capability_lock_pid" || true
  wait "$migration_pid" || true
  exit 1
fi

if [[ "$concurrent_output" != *"canceling statement due to statement timeout"* ]]; then
  echo "Issue #677 concurrent client configuration failed for an unexpected reason" >&2
  wait "$capability_lock_pid" || true
  wait "$migration_pid" || true
  exit 1
fi

wait "$capability_lock_pid"
wait "$migration_pid"

# Exactly one matching client is repaired through the audited service facade.
psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
do $verify_single_repair$
declare
  v_actual text[];
  v_expected_before constant text[] := array[
    'CLI-RPC-01',
    'DB-CORE-READ-01',
    'DB-CORE-WRITE-01',
    'EDGE-BUNDLE-01',
    'NX-CORE-02'
  ];
  v_expected_after constant text[] := array[
    'CLI-ALIAS-02',
    'CLI-RPC-01',
    'DB-CORE-READ-01',
    'DB-CORE-WRITE-01',
    'EDGE-BUNDLE-01',
    'NX-CORE-02'
  ];
begin
  select array_agg(capability_id order by capability_id) filter (where allowed)
  into v_actual
  from private.oauth_client_capability_grants
  where client_id = 'issue-677-official-cli';

  if v_actual is distinct from v_expected_after then
    raise exception 'Issue #677 single-client repair mismatch: %', v_actual;
  end if;

  if (
    select count(*)
    from private.oauth_client_registry_audit
    where client_id = 'issue-677-official-cli'
      and action = 'replace'
      and before_state -> 'capabilities' = to_jsonb(v_expected_before)
      and after_state -> 'capabilities' = to_jsonb(v_expected_after)
  ) <> 1 then
    raise exception 'Issue #677 expected one exact replace audit event';
  end if;

  if (
    select array_agg(capability_id order by capability_id) filter (where allowed)
    from private.oauth_client_capability_grants
    where client_id = 'issue-677-unrelated-mcp'
  ) is distinct from array['DB-CORE-READ-01', 'DB-CORE-WRITE-01', 'EDGE-BUNDLE-01']::text[] then
    raise exception 'Issue #677 repair changed an unrelated client';
  end if;

  if exists (
    select 1
    from private.oauth_client_registry_audit
    where client_id = 'issue-677-unrelated-mcp'
      and action <> 'create'
  ) then
    raise exception 'Issue #677 repair audited an unrelated client';
  end if;
end
$verify_single_repair$;
SQL

# GREEN: the same client_id-bearing session now passes the hook on every actor
# route and reaches the application's null-request refusal with no writes.
psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
do $verify_green_session$
declare
  v_result jsonb;
  v_route text;
begin
  set local role authenticated;
  perform set_config(
    'request.jwt.claims',
    '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677","client_id":"issue-677-official-cli"}',
    true
  );
  perform set_config('request.method', 'POST', true);
  foreach v_route in array array[
    'cmd_dataset_alias_execution_preflight_v2_guarded',
    'cmd_dataset_alias_execution_gate_v2_guarded',
    'cmd_dataset_alias_execution_admit_v2_guarded',
    'cmd_dataset_alias_execution_read_v2'
  ] loop
    perform set_config('request.path', '/rpc/' || v_route, true);
    perform api.oauth_client_pre_request();
  end loop;

  v_result := api.cmd_dataset_alias_execution_read_v2(null);
  reset role;
  if v_result ->> 'code' <> 'ALIAS_EXECUTION_READ_INVALID_REQUEST'
     or (v_result ->> 'status')::integer <> 400 then
    raise exception 'Issue #677 admitted null read did not reach the application refusal: %', v_result;
  end if;
  if exists (select 1 from util.dataset_alias_execution_v2_requests)
     or exists (select 1 from util.dataset_alias_execution_v2_preflights) then
    raise exception 'Issue #677 admitted null read wrote protected rows';
  end if;
end
$verify_green_session$;

-- The service-only executor callback stays unreachable to the repaired OAuth actor.
do $verify_service_only_isolation$
begin
  set local role authenticated;
  perform set_config(
    'request.jwt.claims',
    '{"role":"authenticated","sub":"56600000-0000-4000-8000-000000000677","client_id":"issue-677-official-cli"}',
    true
  );
  perform set_config('request.method', 'POST', true);
  perform set_config('request.path', '/rpc/cmd_dataset_alias_execution_execute_v2', true);
  begin
    perform api.oauth_client_pre_request();
    reset role;
    raise exception 'Issue #677 service-only callback was reachable to the OAuth actor';
  exception
    when insufficient_privilege then
      reset role;
      if sqlerrm <> 'OAuth client is not authorized for this API route' then
        raise exception 'Issue #677 service-only callback refused with an unexpected message: %', sqlerrm;
      end if;
  end;
end
$verify_service_only_isolation$;
SQL

audit_count_before="$(
  psql "$database_url" -v ON_ERROR_STOP=1 -Atc \
    "select count(*) from private.oauth_client_registry_audit where client_id = 'issue-677-official-cli'"
)"
psql "$database_url" -v ON_ERROR_STOP=1 -f "$migration"
audit_count_after="$(
  psql "$database_url" -v ON_ERROR_STOP=1 -Atc \
    "select count(*) from private.oauth_client_registry_audit where client_id = 'issue-677-official-cli'"
)"

if [[ "$audit_count_after" != "$audit_count_before" ]]; then
  echo "Issue #677 idempotent replay appended an audit event" >&2
  exit 1
fi

psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
select api.svc_oauth_client_configure(
  'issue-677-ambiguous-a',
  'cli',
  true,
  array['CLI-RPC-01', 'DB-CORE-READ-01', 'DB-CORE-WRITE-01', 'EDGE-BUNDLE-01', 'NX-CORE-02']
);
select api.svc_oauth_client_configure(
  'issue-677-ambiguous-b',
  'cli',
  true,
  array['CLI-RPC-01', 'DB-CORE-READ-01', 'DB-CORE-WRITE-01', 'EDGE-BUNDLE-01', 'NX-CORE-02']
);
SQL

if ambiguous_output="$(psql "$database_url" -v ON_ERROR_STOP=1 -f "$migration" 2>&1)"; then
  echo "Issue #677 ambiguous client state unexpectedly succeeded" >&2
  exit 1
fi

if [[ "$ambiguous_output" != *"expected at most one matching enabled CLI client"* ]]; then
  echo "Issue #677 ambiguous client state failed for an unexpected reason" >&2
  exit 1
fi

psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
do $verify_ambiguous_rollback$
begin
  if exists (
    select 1
    from private.oauth_client_capability_grants
    where client_id in ('issue-677-ambiguous-a', 'issue-677-ambiguous-b')
      and capability_id = 'CLI-ALIAS-02'
      and allowed
  ) then
    raise exception 'Issue #677 ambiguous repair changed a client';
  end if;
end
$verify_ambiguous_rollback$;
SQL

echo "Issue #677 OAuth CLI alias grant upgrade checks passed"
