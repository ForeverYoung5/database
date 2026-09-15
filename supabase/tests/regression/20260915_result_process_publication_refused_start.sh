#!/usr/bin/env bash
# Database #646 / workspace #1201: local negative contract for the publication concurrency
# harness.
#
# Proves, WITHOUT touching any database, that the harness refuses to start when the run mutex
# is already held and that it never removes a mutex it does not own. It exercises only the
# mutex preflight, so it needs no DB window and cannot mutate anything.
#
# Environment: RESULT120_PUBLICATION_EVIDENCE_DIR (optional, forwarded).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$script_dir/20260915_result_process_publication_concurrency.sh"
run_lock_dir="/tmp/result120-publication-646.lock"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/result120-pub-refused.XXXXXX")"
failures=0
mutex_planted=0

ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (have '$2', want '$3')"; fi; }

cleanup() {
  set +e
  # Remove ONLY the mutex this test planted itself. The harness's own mutex is never removed.
  if ((mutex_planted == 1)); then
    rmdir "$run_lock_dir" 2>/dev/null || echo "cleanup: planted mutex already gone" >&2
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

if [[ ! -x "$harness" ]]; then
  echo "harness is missing or not executable: $harness" >&2
  exit 2
fi

# Precondition: no other run may hold the mutex, otherwise this test would be measuring
# someone else's run.
if [[ -e "$run_lock_dir" ]]; then
  echo "FAIL - $run_lock_dir already exists; refusing to run" >&2
  exit 2
fi

# Plant the mutex exactly as a concurrent invocation would.
mkdir "$run_lock_dir"
mutex_planted=1

set +e
"$harness" > "$workdir/out.txt" 2>&1
status=$?
set -e

if ((status != 0)); then
  ok "the harness refused to start while the run mutex was held (exit $status)"
else
  bad "the harness started while the run mutex was held"
fi

if grep -q "another publication run holds it" "$workdir/out.txt"; then
  ok "the refusal names the held mutex"
else
  bad "the harness did not refuse through the mutex path"
fi

if grep -q "stale locks are removed manually, never automatically" "$workdir/out.txt"; then
  ok "the refusal states that stale mutexes are never removed automatically"
else
  bad "the refusal did not state the stale-mutex policy"
fi

check "the refusing invocation left the mutex in place" \
  "$([[ -d "$run_lock_dir" ]] && echo present || echo absent)" "present"

# Prove ZERO database calls, not merely "failed early". `docker` is invoked only after the
# mutex check would have passed, so its complete absence from the output is the observable
# proof. The teardown banner legitimately mentions the word "database", so that word alone is
# deliberately not matched.
if grep -qE "docker|psql|connection to server|FATAL:|password authentication" "$workdir/out.txt"; then
  bad "the refusing invocation performed or attempted database work"
else
  ok "the refusal performed zero database calls (no docker/psql invocation at all)"
fi

echo
if ((failures > 0)); then
  echo "RESULT: FAIL ($failures assertions failed)"
  exit 1
fi
echo "RESULT: PASS (the harness refuses a held mutex without touching the database)"
