#!/usr/bin/env bash
# Database #670 / workspace #1432: two-session concurrency regression for
# api.cmd_dataset_save_draft_guarded.
#
# A rollback-only single-session pgTAP suite cannot interleave two writers, so the atomic
# before-image invariant is proven here with two real independent psql sessions against one
# task-owned disposable database.
#
# Overlap discipline. Writer A performs its guarded save and then parks on a task-owned
# advisory lock the runner controls, so its row lock is provably held while the competing
# writer B runs; the runner starts B only after observing A waiting on that barrier, and it
# releases A only after observing B waiting on the row lock ("Lock"/"transactionid" in
# pg_stat_activity). Session A cannot observe B itself because the statistics snapshot is
# fixed for the duration of its transaction, so the observation and the release both live in
# the runner's short sessions. A sequential pair of calls cannot satisfy this: the conflict
# is only accepted when both waits were really observed while both transactions were open.
#
# Two scenarios run against the same fixture identity:
#   * guarded: writer A saves the exactly matching before image, writer B then saves with
#     the stale before image. B must be refused with DATASET_BEFORE_CONTENT_CHANGED / 409
#     and A's committed content must survive.
#   * legacy: both writers use the unguarded api.cmd_dataset_save_draft. The stale writer
#     wins and overwrites the committed newer content, which documents that the legacy
#     contract has no compare-and-swap and keeps that compatibility behavior; the guarded
#     facade is the atomic boundary.
#
# Safety boundary: refuses any container or URL other than the named task instance, refuses
# to start when any of its exact fixture identities already exists, and settles only the
# sessions it started, so cleanup owns only rows this run created.
#
# Environment:
#   DRAFT_GUARD_TASK_CONTAINER  (default supabase_db_database-engine-670-isolated)
#   DRAFT_GUARD_TASK_DB_URL     (default postgresql://postgres:postgres@127.0.0.1:55422/postgres)

set -euo pipefail

container="${DRAFT_GUARD_TASK_CONTAINER:-supabase_db_database-engine-670-isolated}"
db_url="${DRAFT_GUARD_TASK_DB_URL:-postgresql://postgres:postgres@127.0.0.1:55422/postgres}"

if [[ ! "$container" =~ ^supabase_db_database-engine-670-isolated$ ]]; then
  echo "refusing non-task container: $container" >&2
  exit 2
fi
if [[ ! "$db_url" =~ ^postgresql://postgres:postgres@127\.0\.0\.1:55422/postgres$ ]]; then
  echo "refusing non-task database url" >&2
  exit 2
fi

# Exact fixtures this runner may create or remove. Nothing else is ever targeted.
actor_id="67000000-0000-4000-8000-00000000c001"
contact_id="67000000-0000-4000-8000-00000000c101"
fixture_actor_ids=("$actor_id")
fixture_dataset_ids=("$contact_id")

barrier_lock_key=670142
barrier_app="draft_guard_barrier"

v0='{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"race-v0"}}'
v1='{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"race-a-write"}}'
v2='{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"race-b-stale-write"}}'
l1='{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"legacy-a-write"}}'
l2='{"contactDataSet":{"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}},"payload":{"name":"legacy-b-stale-write"}}'

workdir="$(mktemp -d "${TMPDIR:-/tmp}/draft-guard-concurrency.XXXXXX")"
failures=0
cleanup_failed=0
fixtures_armed=0
barrier_pid=""
session_app_names=("$barrier_app" "draft_guard_guarded_a" "draft_guard_guarded_b" "draft_guard_legacy_a" "draft_guard_legacy_b")

psql_ctl() { docker exec -i "$container" psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_json() { docker exec -i "$container" psql -X -q -t -A -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_session_file() {
  docker exec -i -e PGAPPNAME="$1" "$container" psql -X -q -t -A -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -v actor="$actor_id" -v v0="$v0" -v v1="$v1" -v v2="$v2" \
    -v l1="$l1" -v l2="$l2" -v contact="$contact_id" -f - < "$2"
}

ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (have '$2', want '$3')"; fi; }

check_response_field() { # label, response, jsonb field path, expected
  if [[ -z "$2" ]]; then
    return 0
  fi
  check "$1" "$(psql_json -c "select (\$json\$$2\$json\$::jsonb $3)::text;")" "$4"
}

settle_runner_sessions() {
  local app_list
  app_list="$(printf "'%s'," "${session_app_names[@]}")"
  app_list="${app_list%,}"
  psql_json -c "select count(*) from (select pg_terminate_backend(pid) from pg_stat_activity where application_name in ($app_list)) as settled;" >/dev/null 2>&1 || true
}

cleanup() {
  local status=$?
  if [[ -n "$barrier_pid" ]]; then
    kill "$barrier_pid" 2>/dev/null || true
    wait "$barrier_pid" 2>/dev/null || true
  fi
  settle_runner_sessions
  if [[ "$fixtures_armed" == "1" ]]; then
    local dataset_list actor_list
    dataset_list="$(printf "'%s'," "${fixture_dataset_ids[@]}")"
    dataset_list="${dataset_list%,}"
    actor_list="$(printf "'%s'," "${fixture_actor_ids[@]}")"
    actor_list="${actor_list%,}"
    psql_ctl -c "
      delete from private.command_audit_log where target_id in ($dataset_list);
      delete from private.lcia_scope_closure_candidate_document_hashes where dataset_id in ($dataset_list);
      delete from public.contacts where id in ($dataset_list);
      delete from private.users where id in ($actor_list);
      delete from auth.users where id in ($actor_list);" >/dev/null 2>&1 || cleanup_failed=1
  fi
  rm -rf "$workdir"
  if [[ "$cleanup_failed" == "1" ]]; then
    echo "FAIL - fixture cleanup did not complete" >&2
    exit 1
  fi
  exit "$status"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight: the guarded contract must exist and the fixture identities must be free.
# ---------------------------------------------------------------------------

guard_present="$(psql_json -c "select to_regprocedure('api.cmd_dataset_save_draft_guarded(text,uuid,text,jsonb,jsonb,uuid,boolean,jsonb,text)') is not null;")"
if [[ "$guard_present" != "t" ]]; then
  echo "refusing to start: api.cmd_dataset_save_draft_guarded is absent" >&2
  exit 2
fi

existing="$(psql_json -c "select (select count(*) from public.contacts where id = '$contact_id') + (select count(*) from auth.users where id = '$actor_id');")"
if [[ "$existing" != "0" ]]; then
  echo "refusing to start: a fixture identity already exists (cleanup owns only its own rows)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Fixture: one verified actor and one owner state-0 contact draft.
# ---------------------------------------------------------------------------

psql_ctl -c "
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, is_sso_user, is_anonymous
  ) values (
    '00000000-0000-0000-0000-000000000000', '$actor_id',
    'authenticated', 'authenticated', 'draft-guard-race@example.com', 'test-password-hash',
    now(), '{\"provider\":\"email\",\"providers\":[\"email\"]}'::jsonb,
    '{\"sub\":\"$actor_id\",\"email\":\"draft-guard-race@example.com\"}'::jsonb,
    now(), now(), false, false
  );
  insert into public.contacts (id, version, json_ordered, user_id, state_code, team_id, rule_verification)
  values ('$contact_id', '01.00.000', \$json\$$v0\$json\$::json, '$actor_id', 0, null, true);" >/dev/null
fixtures_armed=1

# ---------------------------------------------------------------------------
# Writer session scripts: save, park on the runner-owned advisory barrier, commit.
# ---------------------------------------------------------------------------

cat >"$workdir/guarded_a.sql" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"$actor_id"}', true);
select set_config('request.jwt.claim.sub', '$actor_id', true);
select 'A_RESPONSE=' || api.cmd_dataset_save_draft_guarded(
  'contacts',
  '$contact_id',
  '01.00.000',
  :'v1'::jsonb,
  :'v0'::jsonb,
  null,
  false,
  '{"command":"dataset_save_draft","guarded":true,"writer":"a"}'::jsonb,
  null
)::text;
reset role;
select pg_advisory_lock($barrier_lock_key);
select 'A_RELEASED=true';
commit;
SQL

cat >"$workdir/guarded_b.sql" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"$actor_id"}', true);
select set_config('request.jwt.claim.sub', '$actor_id', true);
select 'B_RESPONSE=' || api.cmd_dataset_save_draft_guarded(
  'contacts',
  '$contact_id',
  '01.00.000',
  :'v2'::jsonb,
  :'v0'::jsonb,
  null,
  false,
  '{"command":"dataset_save_draft","guarded":true,"writer":"b"}'::jsonb,
  null
)::text;
commit;
SQL

cat >"$workdir/legacy_a.sql" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"$actor_id"}', true);
select set_config('request.jwt.claim.sub', '$actor_id', true);
select 'A_RESPONSE=' || api.cmd_dataset_save_draft(
  'contacts', '$contact_id', '01.00.000', :'l1'::jsonb, null, false,
  '{"command":"dataset_save_draft","writer":"legacy_a"}'::jsonb
)::text;
reset role;
select pg_advisory_lock($barrier_lock_key);
select 'A_RELEASED=true';
commit;
SQL

cat >"$workdir/legacy_b.sql" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"$actor_id"}', true);
select set_config('request.jwt.claim.sub', '$actor_id', true);
select 'B_RESPONSE=' || api.cmd_dataset_save_draft(
  'contacts', '$contact_id', '01.00.000', :'l2'::jsonb, null, false,
  '{"command":"dataset_save_draft","writer":"legacy_b"}'::jsonb
)::text;
commit;
SQL

# ---------------------------------------------------------------------------
# Overlap orchestration.
# ---------------------------------------------------------------------------

start_barrier() {
  docker exec -i -e PGAPPNAME="$barrier_app" "$container" psql -X -q -t -A -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "begin; select pg_advisory_xact_lock($barrier_lock_key); select pg_sleep(600); commit;" \
    >"$workdir/barrier.out" 2>&1 &
  barrier_pid=$!

  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    local granted
    granted="$(psql_json -c "select count(*) from pg_locks as held join pg_stat_activity as activity on activity.pid = held.pid where activity.application_name = '$barrier_app' and held.locktype = 'advisory' and held.granted;")"
    if [[ "$granted" != "0" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

release_barrier() {
  psql_json -c "select count(*) from (select pg_terminate_backend(pid) from pg_stat_activity where application_name = '$barrier_app') as terminated;" >/dev/null
  if [[ -n "$barrier_pid" ]]; then
    wait "$barrier_pid" 2>/dev/null || true
    barrier_pid=""
  fi
}

wait_for_locked_holder() { # writer application name
  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    local state
    state="$(psql_json -c "select count(*) from pg_stat_activity as activity join pg_locks as held on held.pid = activity.pid where activity.application_name = '$1' and activity.wait_event_type = 'Lock' and activity.wait_event = 'advisory' and held.locktype = 'transactionid' and held.granted;")"
    if [[ "$state" != "0" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_blocked_writer() { # competing writer application name
  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    local state
    state="$(psql_json -c "select count(*) from pg_stat_activity where application_name = '$1' and wait_event_type = 'Lock' and wait_event = 'transactionid';")"
    if [[ "$state" != "0" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

run_race() { # label, holder sql, competitor sql
  local label="$1" a_sql="$2" b_sql="$3"
  local a_out="$workdir/${label}_a.out" b_out="$workdir/${label}_b.out"
  a_response=""
  b_response=""

  if ! start_barrier; then
    bad "$label: task-owned advisory barrier was never granted"
    return 0
  fi

  psql_session_file "draft_guard_${label}_a" "$a_sql" >"$a_out" 2>&1 &
  local a_pid=$!

  if ! wait_for_locked_holder "draft_guard_${label}_a"; then
    bad "$label: writer A never held its row lock behind the barrier"
    sed 's/^/    A| /' "$a_out"
    kill "$a_pid" 2>/dev/null || true
    wait "$a_pid" 2>/dev/null || true
    release_barrier
    return 0
  fi

  psql_session_file "draft_guard_${label}_b" "$b_sql" >"$b_out" 2>&1 &
  local b_pid=$!

  if wait_for_blocked_writer "draft_guard_${label}_b"; then
    ok "$label: competing writer observed blocked on the held row lock"
  else
    bad "$label: competing writer never observed blocked on the row lock"
  fi

  release_barrier

  if ! wait "$a_pid"; then
    bad "$label: writer A failed (see below)"
    sed 's/^/    A| /' "$a_out"
  fi
  if ! wait "$b_pid"; then
    bad "$label: writer B failed (see below)"
    sed 's/^/    B| /' "$b_out"
  fi

  a_response="$(grep '^A_RESPONSE=' "$a_out" | sed 's/^A_RESPONSE=//')"
  b_response="$(grep '^B_RESPONSE=' "$b_out" | sed 's/^B_RESPONSE=//')"
  if [[ -z "$a_response" ]]; then
    bad "$label: no writer A response captured"
    sed 's/^/    A| /' "$a_out"
  fi
  if [[ -z "$b_response" ]]; then
    bad "$label: no writer B response captured"
    sed 's/^/    B| /' "$b_out"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 1: the guarded facade refuses the stale competing writer.
# ---------------------------------------------------------------------------

run_race "guarded" "$workdir/guarded_a.sql" "$workdir/guarded_b.sql"

check_response_field "guarded: first writer succeeded" "$a_response" "->> 'ok'" "true"
check_response_field "guarded: stale writer code" "$b_response" "->> 'code'" "DATASET_BEFORE_CONTENT_CHANGED"
check_response_field "guarded: stale writer status" "$b_response" "->> 'status'" "409"
check "guarded: the first writer's content survived the stale competitor" \
  "$(psql_json -c "select json_ordered::jsonb->'payload'->>'name' from public.contacts where id = '$contact_id';")" "race-a-write"
check "guarded: exactly one guarded save audit entry exists" \
  "$(psql_json -c "select count(*) from private.command_audit_log where target_id = '$contact_id' and payload->>'guarded' = 'true';")" "1"
check "guarded: the refused writer wrote no audit entry" \
  "$(psql_json -c "select count(*) from private.command_audit_log where target_id = '$contact_id' and payload->>'writer' = 'b';")" "0"

# Reset the fixture content to v0 for the legacy scenario.
psql_ctl -c "update public.contacts set json_ordered = \$json\$$v0\$json\$::json where id = '$contact_id';" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 2: the legacy unguarded command still accepts the stale writer, which is the
# compatibility contract the guarded facade deliberately replaces for CLI/Foundry.
# ---------------------------------------------------------------------------

run_race "legacy" "$workdir/legacy_a.sql" "$workdir/legacy_b.sql"

check_response_field "legacy: stale writer is still accepted by the unguarded command" "$b_response" "->> 'ok'" "true"
check "legacy: the stale overwrite wins without compare-and-swap" \
  "$(psql_json -c "select json_ordered::jsonb->'payload'->>'name' from public.contacts where id = '$contact_id';")" "legacy-b-stale-write"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "concurrency regression: PASS"
else
  echo "concurrency regression: FAIL ($failures)"
  exit 1
fi
