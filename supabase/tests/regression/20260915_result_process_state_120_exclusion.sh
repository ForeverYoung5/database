#!/usr/bin/env bash
# Database #646 / workspace #1201: negative regression for the concurrency runner's run
# exclusion.
#
# Proves that a second invocation is refused while the first holds the run, that the
# second does not cancel, settle, or mutate anything belonging to the first, and that the
# first still completes successfully afterwards.
#
# Safety boundary: refuses any container or URL other than the named task instance.
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

bindir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="$bindir/20260915_result_process_state_120_concurrency.sh"
run_lock_dir="/tmp/result120-concurrency-646.lock"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/result120-exclusion.XXXXXX")"
failures=0
cleanup_failed=0
first_client_pid=""

psql_json() { docker exec -i "$container" psql -X -q -t -A -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (have '$2', want '$3')"; fi; }

cleanup() {
  local original_status=$?
  set +e
  # Settle only this test's own first invocation, then release only the lock this test
  # observed as pre-existing at start. Nothing else is touched.
  if [[ -n "$first_client_pid" ]] && kill -0 "$first_client_pid" 2>/dev/null; then
    kill "$first_client_pid" 2>/dev/null || true
    wait "$first_client_pid" 2>/dev/null || true
  fi
  # The lock directory belongs to the runner invocation, never to this test, so it is
  # never removed here. A lock left behind by a killed invocation is reported by the
  # final assertion instead of being cleared automatically.
  rm -rf "$workdir"
  if ((cleanup_failed != 0)); then exit 1; fi
  exit "$original_status"
}
trap cleanup EXIT

# Preconditions: the runner must be present and no other invocation may already hold the
# exclusion, otherwise this test would be measuring someone else's run.
if [[ ! -x "$runner" ]]; then
  echo "runner is missing or not executable: $runner" >&2
  exit 2
fi
if [[ -e "$run_lock_dir" ]]; then
  echo "FAIL - $run_lock_dir already exists; refusing to run" >&2
  exit 2
fi
if [[ "$(psql_json -c "set statement_timeout = '15s'; select tgenabled from pg_trigger where tgname='process_extract_md_trigger_insert';" | tail -1)" != "O" ]]; then
  echo "FAIL - egress trigger is not in the supported 'O' state; refusing to run" >&2
  exit 2
fi

# 1. Start the real runner in the background and wait until it owns the exclusion.
"$runner" > "$workdir/first.out" 2>&1 &
first_client_pid=$!

deadline=$((SECONDS + 30))
while ((SECONDS < deadline)); do
  if [[ -d "$run_lock_dir" ]]; then break; fi
  sleep 0.2
done
if [[ ! -d "$run_lock_dir" ]]; then
  echo "FAIL - the first invocation never acquired the run exclusion" >&2
  exit 1
fi
ok "the first invocation acquired the run exclusion"

# 2. A second invocation must refuse without touching the first. The first invocation's
#    lock directory staying present is the evidence that the second neither took over nor
#    released the run exclusion.
set +e
"$runner" > "$workdir/second.out" 2>&1
second_status=$?
set -e

if ((second_status != 0)); then
  ok "the second invocation was refused (exit $second_status)"
else
  bad "the second invocation started while the first held the run exclusion"
fi

if grep -q "another invocation holds it" "$workdir/second.out"; then
  ok "the second invocation refused through the run exclusion"
else
  bad "the second invocation did not refuse through the run exclusion"
fi

if grep -q "will not remove" "$workdir/second.out" || ! grep -q "could not remove this run's lock directory" "$workdir/second.out"; then
  ok "the second invocation did not attempt to remove the first invocation's lock"
else
  bad "the second invocation tried to remove the first invocation's lock"
fi

check "the first invocation's lock directory is still present" \
  "$([[ -d "$run_lock_dir" ]] && echo yes || echo no)" "yes"
check "the second invocation performed no database cleanup" \
  "$(grep -c 'CLEANUP FAIL' "$workdir/second.out")" "0"

# 3. The first invocation must be unaffected and still pass every assertion it owns.
set +e
wait "$first_client_pid"
first_status=$?
set -e
first_client_pid=""

if ((first_status == 0)); then
  ok "the first invocation completed successfully afterwards"
else
  bad "the first invocation failed after the second was refused (exit $first_status)"
fi
if grep -q "RESULT: PASS" "$workdir/first.out"; then
  ok "the first invocation reported all of its concurrency assertions passing"
else
  bad "the first invocation did not report a passing result"
fi

# 4. The first invocation released its own exclusion, and left no residue.
check "the run exclusion was released by its owner" \
  "$([[ -e "$run_lock_dir" ]] && echo present || echo released)" "released"
check "the egress trigger is still in the supported state" \
  "$(psql_json -c "set statement_timeout = '15s'; select tgenabled from pg_trigger where tgname='process_extract_md_trigger_insert';" | tail -1)" "O"
check "no fixture residue remains" \
  "$(psql_json -c "set statement_timeout = '15s'; select (select count(*) from public.processes where id::text like '64600000-0000-4000-8000-00000000ff%') + (select count(*) from public.flows where id::text like '64600000-0000-4000-8000-00000000ff%') + (select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_id::text like '64600000-0000-4000-8000-00000000ff%');" | tail -1)" "0"
check "no task session remains" \
  "$(psql_json -c "set statement_timeout = '15s'; select count(*) from pg_stat_activity where application_name like 'r120_%';" | tail -1)" "0"

echo
if ((failures > 0)); then
  echo "RESULT: FAIL ($failures assertions failed)"
  exit 1
fi
echo "RESULT: PASS (a second invocation was refused without disturbing the first)"
