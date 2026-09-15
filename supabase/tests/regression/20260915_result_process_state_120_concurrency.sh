#!/usr/bin/env bash
# Database #646 / workspace #1201: multi-session concurrency regression for
# private.maintain_lcia_scope_closure_candidate_cache.
#
# A rollback-only single-session pgTAP suite cannot interleave two writers, so the
# invariant is proven here with real independent psql sessions against one
# task-owned disposable database. This is not a generic framework: it owns one
# narrow barrier, one exact fixture allowlist, and one cleanup trap.
#
# Overlap discipline. Two shapes are used, each with proof that the writer really is
# inside its transaction holding a granted conflicting lock:
#   * "waits" cases give maintenance a lock timeout far longer than the writer's
#     bounded hold, and require observed contention (pg_stat_activity.wait_event_type
#     = 'Lock' on the maintenance session) plus a successful post-release outcome.
#     The writer sleeps only after its INSERT/UPDATE is already done, so the fixture
#     it writes is committed and visible to that post-release batch.
#   * "contended" cases give maintenance a lock timeout shorter than the hold, so the
#     only possible outcome is the fail-closed lock_timeout result.
#
# Safety boundary: refuses any container or URL other than the named task instance.
# Creates committed fixtures, so it always settles its own clients and removes them.
#
# Environment:
#   RESULT120_TASK_CONTAINER  (default supabase_db_database-engine-646-result120)
#   RESULT120_TASK_DB_URL     (default postgresql://postgres:postgres@127.0.0.1:61322/postgres)

set -euo pipefail

container="${RESULT120_TASK_CONTAINER:-supabase_db_database-engine-646-result120}"
db_url="${RESULT120_TASK_DB_URL:-postgresql://postgres:postgres@127.0.0.1:61322/postgres}"

if [[ ! "$container" =~ ^supabase_db_database-engine-646-result120$ ]]; then
  echo "refusing non-task container: $container" >&2
  exit 2
fi
if [[ ! "$db_url" =~ ^postgresql://postgres:postgres@127\.0\.0\.1:61322/postgres$ ]]; then
  echo "refusing non-task database url" >&2
  exit 2
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/result120-concurrency.XXXXXX")"
failures=0
cleanup_failed=0
original_trigger_state=""
original_lifecycle_guard_state=""
# Cleanup owns database rows only after the ownership and trigger preflight have both
# succeeded. Until this is armed, a rejected start performs zero DB mutations and does
# not settle or cancel any session, so a refused run cannot touch another run's rows.
db_cleanup_armed=0
# Narrow task-owned exclusion so two copies of this runner cannot race. A local
# exclusive directory is sufficient for the supported scope because this runner already
# hard-refuses every target except this one local disposable task instance, and it
# avoids any guessed database session identity. Ownership is tracked only in this shell;
# another invocation's lock directory is never removed. The directory is deliberately
# left empty so the owning invocation can release it with a plain rmdir.
run_lock_dir="/tmp/result120-concurrency-646.lock"
run_lock_owned=0

# Exact fixtures this runner may create or remove. Nothing else is ever targeted.
fixture_ids=(
  64600000-0000-4000-8000-00000000ff10
  64600000-0000-4000-8000-00000000ff11
  64600000-0000-4000-8000-00000000ff12
  64600000-0000-4000-8000-00000000ff13
  64600000-0000-4000-8000-00000000ff14
  64600000-0000-4000-8000-00000000ff15
  64600000-0000-4000-8000-00000000ff16
  64600000-0000-4000-8000-00000000ff17
  64600000-0000-4000-8000-00000000ff18
  64600000-0000-4000-8000-00000000ff19
  64600000-0000-4000-8000-00000000ff20
  64600000-0000-4000-8000-00000000ff21
)
fixture_list="$(printf "'%s'," "${fixture_ids[@]}")"
fixture_list="${fixture_list%,}"

# Sessions this runner starts, so cleanup settles only its own clients.
writer_app_names=(r120_writer_s1 r120_writer_s2 r120_writer_s5 r120_writer_s6)

psql_ctl() { docker exec -i "$container" psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_json() { docker exec -i "$container" psql -X -q -t -A -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_file() { docker exec -i "$container" psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < "$1"; }
# application_name must be set by the client: a production function must not rename
# the caller's session. -e PGAPPNAME is the libpq variable psql reads.
psql_writer_file() {
  docker exec -i -e PGAPPNAME="$1" "$container" psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < "$2"
}

ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (have '$2', want '$3')"; fi; }
abort() { echo "FAIL - $1" >&2; exit 1; }

json_field() {
  python3 -c '
import json, sys
value = json.loads(sys.argv[1])[sys.argv[2]]
print("true" if value is True else "false" if value is False else value)
' "$1" "$2"
}

session_pid() {
  psql_json -c "select coalesce(max(pid),0) from pg_stat_activity where application_name = '$1';"
}

granted_source_lock_count() {
  psql_json -c "select count(*) from pg_locks where pid = $1 and relation = 'public.processes'::regclass and mode = 'RowExclusiveLock' and granted;"
}

# Wait until the writer exists AND holds a granted ROW EXCLUSIVE lock on
# public.processes, i.e. it is provably inside its transaction. Deadline expiry fails.
wait_for_writer_lock() {
  local app_name="$1" deadline=$((SECONDS + 20)) pid granted
  while ((SECONDS < deadline)); do
    pid="$(session_pid "$app_name")"
    if [[ "$pid" != "0" ]]; then
      granted="$(granted_source_lock_count "$pid")"
      if [[ "${granted:-0}" -ge 1 ]]; then
        echo "$pid"
        return 0
      fi
    fi
    sleep 0.1
  done
  abort "writer $app_name never held a granted source-table lock within the deadline"
}

settle_writer() {
  local app_name="$1" deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if [[ "$(session_pid "$app_name")" == "0" ]]; then return 0; fi
    sleep 0.2
  done
  psql_ctl -c "select pg_cancel_backend(pid) from pg_stat_activity where application_name = '$app_name';" >/dev/null 2>&1 || true
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(session_pid "$app_name")" == "0" ]]; then return 0; fi
    sleep 0.2
  done
  return 1
}

cache_row_count() {
  psql_json -c "select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_type='processes' and dataset_id='$1' and dataset_version='01.00.000';"
}

# Plant a cache row whose source may or may not exist yet. This is exactly the shape
# a database that recorded rows under the old 100..199 rule can hold.
insert_cache_row() {
  psql_json -c "
insert into private.lcia_scope_closure_candidate_document_hashes(
  dataset_type, dataset_id, dataset_version, source_locator_id, role,
  canonical_content_hash, source_modified_at, refreshed_at)
values ('processes','$1','01.00.000','$1','unit_process',repeat('$2',64),now(),now());" >/dev/null
}

insert_process() {
  local id="$1" state="$2"
  psql_json -c "
insert into public.processes(id, version, state_code, json_ordered)
values ('$id','01.00.000',$state,
  '{\"processDataSet\":{\"processInformation\":{\"dataSetInformation\":{\"common:UUID\":\"$id\"}},\"administrativeInformation\":{\"publicationAndOwnership\":{\"common:dataSetVersion\":\"01.00.000\"}}}}');" >/dev/null
}

# One batch per short autocommit transaction. The caller sets its own statement_timeout
# because the table fence is released only at transaction end, which is after the
# function returns.
maintain() {
  psql_json -c "set statement_timeout = '30s'; select private.maintain_lcia_scope_closure_candidate_cache($1, $2);"
}

# Start maintenance in its own client session so its wait state is observable, then
# poll until that session is actually blocked on a lock. Fails on deadline expiry.
# Launch maintenance as a background child of THIS shell. It must not be started
# inside command substitution: that would run in a subshell, and a later `wait`
# in the main shell could not reap it.
maintenance_client_pid=""
start_maintenance_client() {
  local max_rows="$1" lock_timeout_ms="$2" out="$3"
  docker exec -i -e PGAPPNAME=r120_maintenance "$container" psql -X -q -t -A -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "set statement_timeout = '30s'; select private.maintain_lcia_scope_closure_candidate_cache($max_rows, $lock_timeout_ms);" > "$out" 2>&1 &
  maintenance_client_pid=$!
}

# Poll until the maintenance session is observably blocked on a lock. Deadline
# expiry fails the run rather than falling through.
await_maintenance_lock_wait() {
  local deadline=$((SECONDS + 20)) db_pid waiting
  while ((SECONDS < deadline)); do
    db_pid="$(psql_json -c "select coalesce(max(pid),0) from pg_stat_activity where application_name = 'r120_maintenance';")"
    if [[ "$db_pid" != "0" ]]; then
      waiting="$(psql_json -c "select count(*) from pg_stat_activity where pid = $db_pid and wait_event_type = 'Lock';")"
      if [[ "${waiting:-0}" -ge 1 ]]; then
        return 0
      fi
    fi
    sleep 0.1
  done
  abort "maintenance never blocked on the source-table lock within the deadline"
}

# Teardown for this task-owned, hard-allowlisted runner.
#
# A state-120 fixture is immutable by design, so this runner's own committed Results
# cannot be removed while the lifecycle guard is enabled. Teardown therefore runs one
# short transaction that takes an exclusive table fence, disables ONLY
# zzz_guard_process_result_lifecycle, deletes exactly the already-owned fixture
# allowlist, and re-enables the guard BEFORE commit.
#
# Failing closed: an explicit begin/commit wraps every statement in one transaction. The
# re-enabling alter and the setting restore run while that transaction is still open and
# the commit is the final statement, so any failure before it rolls back both the DDL and
# the deletes and leaves the guard enabled. This is test-only teardown DDL confined to
# this runner; it adds no production helper, no GUC bypass, and no guard change. All
# scenarios above run with the guard enabled.
#
#   * lock_timeout bounds waiting behind a stuck writer;
#   * the table fence plus the existing settings make the DDL deterministic;
#   * every fixture identity was verified absent before the run, so cleanup owns them.
cleanup_sql() {
  psql_ctl <<SQL
begin;
set lock_timeout = '5s';
set statement_timeout = '30s';
select set_config('app.review_controlled_write', 'on', false);
lock table public.processes in access exclusive mode;
alter table public.processes disable trigger zzz_guard_process_result_lifecycle;
delete from private.lcia_scope_closure_candidate_document_hashes
 where dataset_id in (${fixture_list}) or source_locator_id in (${fixture_list});
delete from public.processes where id in (${fixture_list});
delete from public.flows where id in (${fixture_list});
alter table public.processes enable trigger zzz_guard_process_result_lifecycle;
select set_config('app.review_controlled_write', 'off', false);
commit;
SQL
}

cleanup() {
  local original_status=$?
  set +e

  if ((db_cleanup_armed == 1)); then
    for app_name in "${writer_app_names[@]}" r120_maintenance; do
      if ! settle_writer "$app_name"; then
        echo "CLEANUP FAIL: session $app_name could not be settled" >&2
        cleanup_failed=1
      fi
    done

    # Restore the egress trigger to O, the only state this runner accepts. The run
    # refuses to start in any other state, so O is always the correct restore target.
    if [[ "$original_trigger_state" == "O" ]]; then
      psql_ctl -c "alter table public.processes enable trigger process_extract_md_trigger_insert;" >/dev/null 2>&1 \
        || { echo "CLEANUP FAIL: could not restore egress trigger" >&2; cleanup_failed=1; }
      restored="$(psql_json -c "set statement_timeout = '15s'; select tgenabled from pg_trigger where tgname='process_extract_md_trigger_insert';" 2>/dev/null | tail -1)"
      if [[ "$restored" != "O" ]]; then
        echo "CLEANUP FAIL: egress trigger state '$restored' != expected 'O'" >&2
        cleanup_failed=1
      fi
    fi

    if ! cleanup_sql >/dev/null 2>&1; then
      echo "CLEANUP FAIL: fixture delete errored" >&2
      cleanup_failed=1
    fi

    residue="$(psql_json -c "set lock_timeout = '5s'; set statement_timeout = '30s'; select (select count(*) from public.processes where id in (${fixture_list})) + (select count(*) from public.flows where id in (${fixture_list})) + (select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_id in (${fixture_list}) or source_locator_id in (${fixture_list}));" 2>/dev/null | tail -1)"
    if [[ "$residue" != "0" ]]; then
      echo "CLEANUP FAIL: $residue task fixture rows remain" >&2
      cleanup_failed=1
    fi

    # Final readback: teardown must leave the Result lifecycle guard enabled.
    guard_after="$(psql_json -c "set statement_timeout = '15s'; select coalesce((select tgenabled from pg_trigger where tgname = 'zzz_guard_process_result_lifecycle' and not tgisinternal), 'missing');" 2>/dev/null | tail -1)"
    if [[ "$guard_after" != "O" ]]; then
      echo "CLEANUP FAIL: Result lifecycle guard state '$guard_after' != expected 'O'" >&2
      cleanup_failed=1
    fi
  fi
  rm -rf "$workdir"

  # Release run exclusion LAST, after database cleanup has finished, so the exclusion
  # covers the whole run. Only this shell's own lock is removed; a lock directory this
  # invocation did not create is left untouched for an operator to inspect.
  if ((run_lock_owned == 1)); then
    if ! rmdir "$run_lock_dir" 2>/dev/null; then
      echo "CLEANUP FAIL: could not remove this run's lock directory $run_lock_dir" >&2
      cleanup_failed=1
    fi
  fi

  # Preserve the original exit status unless cleanup itself failed.
  if ((cleanup_failed != 0)); then
    exit 1
  fi
  exit "$original_status"
}
# Only the temporary directory is cleaned before the preflight succeeds. Database
# cleanup stays disarmed so a refused start cannot delete or settle anything.
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight. Everything here is read-only against the database; the run exclusion is a
# local mkdir directory and holds no database state. No fixture, trigger, or setting is
# touched until all three checks pass.
# ---------------------------------------------------------------------------

# 1. Narrow task-owned exclusion. mkdir is atomic, so exactly one invocation creates the
#    directory and therefore owns the run. No database session is involved, so there is
#    no guessed PID and no TTL that could expire independently of the run.
if mkdir "$run_lock_dir" 2>/dev/null; then
  run_lock_owned=1
else
  if [[ -d "$run_lock_dir" ]]; then
    abort "run lock directory $run_lock_dir already exists; another invocation holds it (stale locks are never removed automatically, clear it manually only after confirming no run is active)"
  fi
  abort "run lock directory $run_lock_dir could not be created"
fi

# 2. Trigger state. ALWAYS (A) would need a bounded restore this runner does not
#    implement, so anything other than the plain enabled O is refused before mutation.
original_trigger_state="$(psql_json -c "select tgenabled from pg_trigger where tgname='process_extract_md_trigger_insert';" | tail -1)"
if [[ "$original_trigger_state" != "O" ]]; then
  abort "egress trigger state is '$original_trigger_state'; only 'O' is supported, refusing before any mutation"
fi

# 2b. The Result lifecycle guard must exist and be enabled before the run: every
# scenario below depends on it, and teardown is only sound when it started enabled.
original_lifecycle_guard_state="$(psql_json -c "set statement_timeout = '15s'; select coalesce((select tgenabled from pg_trigger where tgname = 'zzz_guard_process_result_lifecycle' and not tgisinternal), 'missing');" | tail -1)"
if [[ "$original_lifecycle_guard_state" != "O" ]]; then
  abort "Result lifecycle guard state is '$original_lifecycle_guard_state'; expected enabled 'O', refusing before any mutation"
fi

# 3. Ownership. Every fixture identity this runner will use must be absent, so cleanup
#    can only ever delete rows this run created.
preexisting="$(psql_json -c "set statement_timeout = '15s'; select (select count(*) from public.processes where id in (${fixture_list})) + (select count(*) from public.flows where id in (${fixture_list})) + (select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_id in (${fixture_list}) or source_locator_id in (${fixture_list}));" | tail -1)"
if [[ "$preexisting" != "0" ]]; then
  abort "$preexisting task fixture rows already exist; refusing to start so cleanup cannot delete rows this run did not create"
fi

# Preflight passed. Arm database cleanup before the first mutation.
db_cleanup_armed=1

# Outbound extraction webhooks need Vault secrets a disposable task database does not
# have. Disabling only that egress trigger is the established repo test technique and
# leaves the candidate cache trigger, the immutability guard, and every other guard
# fully active.
psql_ctl -c "alter table public.processes disable trigger process_extract_md_trigger_insert;" >/dev/null

# ---------------------------------------------------------------------------
# 1. WAITS: an orphan cache row plus a concurrent source INSERT. The writer commits
#    its INSERT first and then holds the lock, so after release the fixture is
#    visible. The row is evictable only if maintenance could read a stale snapshot of
#    public.processes, which the fence prevents.
# ---------------------------------------------------------------------------
echo "# 1. maintenance waits out a concurrent orphan source insert"

insert_cache_row 64600000-0000-4000-8000-00000000ff10 a
check "orphan insert: the stale row exists before the race" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff10)" "1"

cat > "$workdir/s1.sql" <<'SQL'
begin;
insert into public.processes(id, version, state_code, json_ordered)
values (
  '64600000-0000-4000-8000-00000000ff10', '01.00.000', 100,
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64600000-0000-4000-8000-00000000ff10"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
);
select pg_sleep(4);
commit;
SQL

psql_writer_file r120_writer_s1 "$workdir/s1.sql" >/dev/null &
writer_client_pid=$!
wait_for_writer_lock r120_writer_s1 >/dev/null
start_maintenance_client 10 25000 "$workdir/s1.out"
await_maintenance_lock_wait
ok "orphan insert: maintenance was observably blocked on the source-table lock"
wait "$maintenance_client_pid"
wait "$writer_client_pid"

s1_response="$(cat "$workdir/s1.out")"
check "orphan insert: the waiting batch completed cleanly" "$(json_field "$s1_response" status)" "ok"
check "orphan insert: the eligible orphan row was not evicted" \
  "$(json_field "$s1_response" removedCount)" "0"
check "orphan insert: the row is still present for later use" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff10)" "1"

# ---------------------------------------------------------------------------
# 2. WAITS: same protocol for an ineligible -> 100 update.
# ---------------------------------------------------------------------------
echo "# 2. maintenance waits out a concurrent ineligible -> 100 update"

# The ineligible source for this case is state 200, not 120. Both are excluded from the
# numeric candidate universe, so the cache and contention assertions are unchanged, but
# only 200 is still allowed to become 100: a Result 120 -> 100 downgrade is now rejected
# by the Result lifecycle guard and is covered separately by
# supabase/tests/20260915_result_process_lifecycle_protection.sql. Using 120 here would
# test the lifecycle guard, not this maintenance fence.
insert_process 64600000-0000-4000-8000-00000000ff11 200
insert_cache_row 64600000-0000-4000-8000-00000000ff11 b

cat > "$workdir/s2.sql" <<'SQL'
begin;
update public.processes set state_code = 100
 where id = '64600000-0000-4000-8000-00000000ff11' and version = '01.00.000';
select pg_sleep(4);
commit;
SQL

psql_writer_file r120_writer_s2 "$workdir/s2.sql" >/dev/null &
writer_client_pid=$!
wait_for_writer_lock r120_writer_s2 >/dev/null
start_maintenance_client 10 25000 "$workdir/s2.out"
await_maintenance_lock_wait
ok "re-eligibility: maintenance was observably blocked on the source-table lock"
wait "$maintenance_client_pid"
wait "$writer_client_pid"

s2_response="$(cat "$workdir/s2.out")"
check "re-eligibility: the waiting batch completed cleanly" "$(json_field "$s2_response" status)" "ok"
check "re-eligibility: the re-eligible row was not evicted" \
  "$(json_field "$s2_response" removedCount)" "0"
check "re-eligibility: the row is still present for later use" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff11)" "1"

# ---------------------------------------------------------------------------
# 3. Legitimate eviction still removes exactly the exact candidate, both through the
#    source trigger and through maintenance.
# ---------------------------------------------------------------------------
echo "# 3. legitimate 100 -> 120 eviction still removes the exact candidate"

insert_process 64600000-0000-4000-8000-00000000ff16 100
check "eviction: the eligible row is cached before the transition" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff16)" "1"

# A state-100 row is immutable by contract, so the publishing path this slice does not
# yet ship must enter the same review-controlled write context those commands use. No
# guard is disabled; only the guarded command context is entered.
psql_ctl <<'SQL' >/dev/null
select set_config('app.review_controlled_write', 'on', false);
update public.processes set state_code = 120
 where id = '64600000-0000-4000-8000-00000000ff16' and version = '01.00.000';
select set_config('app.review_controlled_write', 'off', false);
SQL
check "eviction: 100 -> 120 removes the exact candidate through the trigger" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff16)" "0"

insert_process 64600000-0000-4000-8000-00000000ff15 120
insert_cache_row 64600000-0000-4000-8000-00000000ff15 e
check "eviction: the ineligible row is cached before maintenance" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff15)" "1"

evict_response="$(maintain 10 5000)"
check "eviction: maintenance removes the ineligible exact candidate" \
  "$(json_field "$evict_response" removedCount)" "1"
check "eviction: the evicted row is gone" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff15)" "0"

# ---------------------------------------------------------------------------
# 4. Bounded drain preserves unrelated eligible and support entries.
# ---------------------------------------------------------------------------
echo "# 4. bounded drain preserves unrelated eligible and support entries"

insert_process 64600000-0000-4000-8000-00000000ff13 100
psql_json -c "
insert into public.flows(id, version, state_code, json_ordered)
values ('64600000-0000-4000-8000-00000000ff14','01.00.000',100,
  '{\"flowDataSet\":{\"flowInformation\":{\"dataSetInformation\":{\"common:UUID\":\"64600000-0000-4000-8000-00000000ff14\"}},\"administrativeInformation\":{\"publicationAndOwnership\":{\"common:dataSetVersion\":\"01.00.000\"}}}}');" >/dev/null
insert_cache_row 64600000-0000-4000-8000-00000000ff17 c
insert_cache_row 64600000-0000-4000-8000-00000000ff18 c
insert_cache_row 64600000-0000-4000-8000-00000000ff19 c

step1="$(maintain 1 5000)"
step2="$(maintain 1 5000)"
step3="$(maintain 1 5000)"

check "drain: first batch removes exactly one row"  "$(json_field "$step1" removedCount)" "1"
check "drain: first batch reports more work"        "$(json_field "$step1" moreRemaining)" "true"
check "drain: second batch makes forward progress"  "$(json_field "$step2" removedCount)" "1"
check "drain: second batch still reports more work" "$(json_field "$step2" moreRemaining)" "true"
check "drain: third batch removes the last row"     "$(json_field "$step3" removedCount)" "1"
check "drain: third batch reports a drained cache"  "$(json_field "$step3" moreRemaining)" "false"
check "drain: drained cache reports a clean status" "$(json_field "$step3" status)" "ok"
check "drain: unrelated eligible process row is preserved" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff13)" "1"
check "drain: unrelated support row is preserved" \
  "$(psql_json -c "select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_type='flows' and dataset_id='64600000-0000-4000-8000-00000000ff14' and role='support';")" "1"

# ---------------------------------------------------------------------------
# 5. CONTENDED: a lock timeout shorter than the hold can only yield the fail-closed
#    result, which proves the fence was actually contended.
# ---------------------------------------------------------------------------
echo "# 5. a contended fence reports lock_timeout without deleting"

insert_cache_row 64600000-0000-4000-8000-00000000ff20 d

cat > "$workdir/s5.sql" <<'SQL'
begin;
lock table public.processes in row exclusive mode;
select pg_sleep(4);
commit;
SQL

psql_writer_file r120_writer_s5 "$workdir/s5.sql" >/dev/null &
writer_client_pid=$!
wait_for_writer_lock r120_writer_s5 >/dev/null
s5_response="$(maintain 10 500)"
wait "$writer_client_pid"

check "fence: a contended batch reports lock_timeout"     "$(json_field "$s5_response" status)" "lock_timeout"
check "fence: a contended batch removes nothing"          "$(json_field "$s5_response" removedCount)" "0"
check "fence: a contended batch claims more work remains" "$(json_field "$s5_response" moreRemaining)" "true"
check "fence: the stale row is still there to retry" \
  "$(cache_row_count 64600000-0000-4000-8000-00000000ff20)" "1"

after_response="$(maintain 10 5000)"
check "fence: retry after release drains the row"       "$(json_field "$after_response" removedCount)" "1"
check "fence: retry after release reports a clean status" "$(json_field "$after_response" status)" "ok"

# ---------------------------------------------------------------------------
# 6. Setting preservation on the success, lock-timeout, and exception paths.
# ---------------------------------------------------------------------------
echo "# 6. maintenance preserves the caller lock_timeout setting"

preserved_ok="$(psql_json -c "set lock_timeout = '4321ms'; select private.maintain_lcia_scope_closure_candidate_cache(1, 5000); select current_setting('lock_timeout');" | tail -1)"
check "settings: success path restores the caller lock_timeout" "$preserved_ok" "4321ms"

insert_cache_row 64600000-0000-4000-8000-00000000ff21 f
psql_writer_file r120_writer_s6 "$workdir/s5.sql" >/dev/null &
writer_client_pid=$!
wait_for_writer_lock r120_writer_s6 >/dev/null
preserved_timeout="$(psql_json -c "set lock_timeout = '4321ms'; select private.maintain_lcia_scope_closure_candidate_cache(10, 300); select current_setting('lock_timeout');" | tail -1)"
wait "$writer_client_pid"
check "settings: lock-timeout path restores the caller lock_timeout" "$preserved_timeout" "4321ms"

preserved_error="$(psql_json -c "set lock_timeout = '4321ms'; do \$\$ begin perform private.maintain_lcia_scope_closure_candidate_cache(0, 5000); exception when others then null; end \$\$; select current_setting('lock_timeout');" | tail -1)"
check "settings: exception path restores the caller lock_timeout" "$preserved_error" "4321ms"

echo
if ((failures > 0)); then
  echo "RESULT: FAIL ($failures assertions failed)"
  exit 1
fi
echo "RESULT: PASS (all concurrency assertions passed)"
