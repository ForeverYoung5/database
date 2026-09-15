#!/usr/bin/env bash
# Database #646 / workspace #1201: negative regression for the concurrency runner's
# ownership preflight.
#
# Proves that a REFUSED start performs zero database mutations. A known toy sentinel is
# planted at one exact fixture identity, the runner is invoked, and the test asserts
# that the runner exits nonzero while the sentinel's content, state, and the egress
# trigger are all unchanged. The sentinel is then removed with an exact owned context.
#
# This is deliberately not satisfied by prose: the rejection, the unchanged content
# hash, and the unchanged trigger state are each asserted from the database.
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

runner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/20260915_result_process_state_120_concurrency.sh"
if [[ ! -x "$runner" ]]; then
  echo "runner is missing or not executable: $runner" >&2
  exit 2
fi

# The sentinel occupies one exact fixture identity the runner's preflight checks. It is
# planted as a candidate cache row rather than a public.processes row: inserting a
# Process fires the extraction webhook, which needs Vault secrets this disposable
# database does not have, and this test must leave the egress trigger enabled so it can
# prove the refused start did not disable it. The cache table carries no triggers of its
# own, and its identity is one of the three surfaces the preflight counts.
sentinel_id="64600000-0000-4000-8000-00000000ff10"
sentinel_content_hash="$(printf 'a%.0s' $(seq 1 64))"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/result120-refused.XXXXXX")"
failures=0
cleanup_failed=0
sentinel_planted=0

psql_ctl() { docker exec -i "$container" psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_json() { docker exec -i "$container" psql -X -q -t -A -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (have '$2', want '$3')"; fi; }

sentinel_fingerprint() {
  psql_json -c "set statement_timeout = '15s'; select coalesce(md5(role || '|' || canonical_content_hash || '|' || btrim(dataset_version) || '|' || source_locator_id::text), 'absent') from private.lcia_scope_closure_candidate_document_hashes where dataset_id = '$sentinel_id';" | tail -1
}

trigger_state() {
  psql_json -c "set statement_timeout = '15s'; select tgenabled from pg_trigger where tgname='process_extract_md_trigger_insert';" | tail -1
}

# The sentinel is this test's own row, at one exact identity this test created.
remove_sentinel() {
  psql_ctl <<SQL
set lock_timeout = '5s';
set statement_timeout = '30s';
delete from private.lcia_scope_closure_candidate_document_hashes
 where dataset_id = '${sentinel_id}' or source_locator_id = '${sentinel_id}';
SQL
}

cleanup() {
  local original_status=$?
  set +e
  if ((sentinel_planted == 1)); then
    if ! remove_sentinel >/dev/null 2>&1; then
      echo "CLEANUP FAIL: could not remove the planted sentinel" >&2
      cleanup_failed=1
    fi
    remaining="$(psql_json -c "set statement_timeout = '15s'; select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_id = '${sentinel_id}' or source_locator_id = '${sentinel_id}';" 2>/dev/null | tail -1)"
    if [[ "$remaining" != "0" ]]; then
      echo "CLEANUP FAIL: sentinel still present" >&2
      cleanup_failed=1
    fi
  fi
  rm -rf "$workdir"
  if ((cleanup_failed != 0)); then exit 1; fi
  exit "$original_status"
}
trap cleanup EXIT

# Preconditions: the trigger must be in the supported state and no fixture may exist,
# otherwise this test would be measuring the wrong thing.
if [[ "$(trigger_state)" != "O" ]]; then
  echo "FAIL - egress trigger is not in the supported 'O' state; refusing to run" >&2
  exit 2
fi
existing="$(psql_json -c "set statement_timeout = '15s'; select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_id = '${sentinel_id}' or source_locator_id = '${sentinel_id}';" | tail -1)"
if [[ "$existing" != "0" ]]; then
  echo "FAIL - sentinel identity already occupied; refusing to run" >&2
  exit 2
fi

# Plant exactly one known toy sentinel at the exact fixture identity.
psql_json -c "
insert into private.lcia_scope_closure_candidate_document_hashes(
  dataset_type, dataset_id, dataset_version, source_locator_id, role,
  canonical_content_hash, source_modified_at, refreshed_at)
values ('processes','${sentinel_id}','01.00.000','${sentinel_id}','unit_process',
        '${sentinel_content_hash}', now(), now());" >/dev/null
sentinel_planted=1

before_fingerprint="$(sentinel_fingerprint)"
before_trigger="$(trigger_state)"
if [[ -z "$before_fingerprint" || "$before_trigger" != "O" ]]; then
  echo "FAIL - could not establish the sentinel baseline" >&2
  exit 1
fi

# Invoke the runner and capture its real exit status.
set +e
"$runner" > "$workdir/runner.out" 2>&1
runner_status=$?
set -e

if ((runner_status != 0)); then
  ok "the runner refused to start (exit $runner_status)"
else
  bad "the runner accepted a start while an exact fixture identity was occupied"
fi

if grep -q "refusing to start so cleanup cannot delete rows this run did not create" "$workdir/runner.out"; then
  ok "the runner refused through the ownership preflight"
else
  bad "the runner did not refuse through the ownership preflight"
fi

check "the sentinel row still exists" \
  "$(psql_json -c "set statement_timeout = '15s'; select count(*) from private.lcia_scope_closure_candidate_document_hashes where dataset_id = '${sentinel_id}';" | tail -1)" "1"
check "the sentinel content, role, and version are unchanged" \
  "$(sentinel_fingerprint)" "$before_fingerprint"
check "the egress trigger was not left disabled" "$(trigger_state)" "$before_trigger"
check "no public Process row was created for the sentinel" \
  "$(psql_json -c "set statement_timeout = '15s'; select count(*) from public.processes where id = '${sentinel_id}';" | tail -1)" "0"
check "no flow or process fixture of this runner's set was created" \
  "$(psql_json -c "set statement_timeout = '15s'; select (select count(*) from public.processes where id::text like '64600000-0000-4000-8000-00000000ff%') + (select count(*) from public.flows where id::text like '64600000-0000-4000-8000-00000000ff%');" | tail -1)" "0"

echo
if ((failures > 0)); then
  echo "RESULT: FAIL ($failures assertions failed)"
  exit 1
fi
echo "RESULT: PASS (refused start performed zero database mutations)"
