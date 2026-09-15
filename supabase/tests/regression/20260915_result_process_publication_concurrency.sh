#!/usr/bin/env bash
# Database #646 / workspace #1201: two-client concurrency proof for Result publication.
#
# Uses genuinely separate psql clients, real blocking, and a PERSISTENT coordinator barrier
# holder. Nothing here is simulated by sleeps or by loose "any lock" checks.
#
# Barrier protocol (the part that is easy to get wrong):
#   A coordinator psql session is started with its stdin attached to a FIFO and kept open. The
#   coordinator FIRST acquires a barrier advisory lock inside an open transaction, and we verify
#   that lock is held by that exact backend PID. Only then is a writer launched, so the writer
#   blocks on a lock somebody already owns. Releasing the barrier writes COMMIT into the same
#   session, which is the only thing that can release it.
#   A lock that nobody holds is not a barrier: the first asker simply acquires it.
#
# Ownership model: the whole harness owns a DEDICATED database that the coordinator resets. It
# performs NO fixture DELETEs and disables NO trigger, because a state-120 row is immutable and
# its attestation is append-only by contract; deleting them would require disabling exactly the
# guards under test. Preflight refuses any reused state; the manifest and every response artifact
# are retained and reported; teardown reports "coordinator reset required".
#
# `process_extract_md_trigger_insert` is AFTER INSERT with no `when` predicate, so it fires for
# every inserted row and `util.invoke_edge_function` raises without a Vault secret. The harness
# therefore provisions the two Vault values (loopback NON-PRODUCTION sink, never a real service)
# and leaves every trigger enabled. Both values vanish with the reset.
#
# Environment: RESULT120_TASK_CONTAINER, RESULT120_TASK_DB_URL,
#              RESULT120_PUBLICATION_EVIDENCE_DIR (all optional).

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

run_id="$$"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_lock_dir="/tmp/result120-publication-646.lock"
evidence_dir="${RESULT120_PUBLICATION_EVIDENCE_DIR:-}"
if [[ -n "$evidence_dir" ]]; then
  if [[ "$evidence_dir" != /* || ! -d "$evidence_dir" || -L "$evidence_dir" || ! -O "$evidence_dir" ]]; then
    echo "RESULT120_PUBLICATION_EVIDENCE_DIR must be an existing absolute owned directory" >&2
    exit 2
  fi
else
  evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/result120-publication-evidence.XXXXXX")"
fi
workdir="$evidence_dir"

failures=0
mutex_owned=0
barrier_fd_open=0
barrier_pid=""
fence_fd_open=0
fence_holder_pid=""

fixture_ids=(
  64c00000-0000-4000-8000-000000000010
  64c00000-0000-4000-8000-000000000011
  64c00000-0000-4000-8000-000000000012
  64c00000-0000-4000-8000-000000000013
)
fixture_list="$(printf "'%s'," "${fixture_ids[@]}")"
fixture_list="${fixture_list%,}"

actor_id="64c00000-0000-4000-8000-000000000001"
actor_email="pub-conc-${run_id}@example.invalid"
client_a="pub_a_${run_id}"
client_b="pub_b_${run_id}"
barrier_app="pub_barrier_${run_id}"
# A separate application name for the fence holder, so PID lookups are unambiguous: reusing the
# barrier session's name would make max(pid) select an arbitrary one of the two.
fence_app="pub_fence_${run_id}"

# Bounded supervision: every client gets its own timeouts, so a wedged session fails rather
# than hanging the run. The publication command legitimately waits on barriers this harness
# controls, so statement_timeout is generous while lock_timeout stays short.
CLIENT_TIMEOUTS="set statement_timeout = '120s'; set lock_timeout = '60s';"

psql_ctl() { docker exec -i "$container" psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_json() { docker exec -i "$container" psql -X -q -t -A -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_client() {
  # The application name is consumed here; it must NOT be forwarded into psql's argv.
  local app_name="$1"; shift
  docker exec -i -e PGAPPNAME="$app_name" "$container" psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

record() { printf '%s\n' "$1" >> "$workdir/manifest.txt"; }
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (have '$2', want '$3')"; fi; }
abort() { echo "FAIL - $1" >&2; exit 1; }

session_pid_of() {
  psql_json -c "select coalesce(max(pid),0) from pg_stat_activity where application_name = '$1';"
}

# Typed receipt validator. A missing or null field FAILS; it never compares empty to empty.
check_json_field() {
  local label="$1" doc="$2" path="$3" expected="$4" actual
  if ! actual="$(python3 "$script_dir/json_path_value.py" "$doc" "$path")"; then
    bad "$label (field '$path' absent or null)"; return
  fi
  if [[ -z "$actual" ]]; then bad "$label (field '$path' is empty)"; return; fi
  if [[ "$actual" == "$expected" ]]; then ok "$label"; else bad "$label (have '$actual', want '$expected')"; fi
}

# Assert a field exists and is non-null, without prescribing its value.
check_json_present() {
  local label="$1" doc="$2" path="$3" actual
  if ! actual="$(python3 "$script_dir/json_path_value.py" "$doc" "$path")"; then
    bad "$label (field '$path' absent or null)"; return
  fi
  if [[ -z "$actual" ]]; then bad "$label (field '$path' is empty)"; else ok "$label"; fi
}

settle_owned_client() {
  local app_name="$1" deadline=$((SECONDS + 15)) pid
  while ((SECONDS < deadline)); do
    if [[ "$(session_pid_of "$app_name")" == "0" ]]; then return 0; fi
    sleep 0.2
  done
  pid="$(session_pid_of "$app_name")"
  if [[ -n "$pid" && "$pid" != "0" ]]; then
    psql_ctl -c "select pg_cancel_backend($pid);" >/dev/null 2>&1 || true
  fi
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(session_pid_of "$app_name")" == "0" ]]; then return 0; fi
    sleep 0.2
  done
  return 1
}

teardown() {
  local original_status=$?
  set +e
  # The barrier holder is a docker exec reading a FIFO, so closing the shell's FIFO handle does
  # NOT reliably end it: docker exec keeps its own handle. After releasing the barrier normally,
  # settle the exact owned sessions, and terminate the exact captured backend PID as the
  # fallback. Only PIDs this run captured are ever touched.
  if ((barrier_fd_open == 1)); then exec 9>&- 2>/dev/null || true; fi
  if ((fence_fd_open == 1)); then exec 8>&- 2>/dev/null || true; fi
  if ((mutex_owned == 1)); then
    for app_name in "$client_a" "$client_b" "$barrier_app" "$fence_app"; do
      settle_owned_client "$app_name" || echo "TEARDOWN: session $app_name still active; its exact PID was cancelled" >&2
    done
    # Targeted teardown for both captured holder PIDs, so an interrupted run cannot leave a
    # barrier or fence holder behind. Only PIDs this run captured are ever touched.
    for held_pid in "${barrier_pid:-}" "${fence_holder_pid:-}"; do
      if [[ -n "$held_pid" && "$held_pid" != "0" ]]; then
        psql_ctl -c "select pg_terminate_backend($held_pid);" >/dev/null 2>&1 || true
      fi
    done
    if [[ -n "${barrier_pid:-}" && "${barrier_pid:-0}" != "0" ]]; then
      psql_ctl -c "select pg_terminate_backend($barrier_pid);" >/dev/null 2>&1 || true
    fi
  fi
  if ((mutex_owned == 1)); then
    rmdir "$run_lock_dir" 2>/dev/null || echo "TEARDOWN: mutex not removable" >&2
  fi
  echo
  echo "EVIDENCE RETAINED: $workdir"
  echo "MANIFEST: $workdir/manifest.txt"
  if ((mutex_owned != 1)); then
    echo "TEARDOWN: this invocation was refused at the mutex, performed no database work and"
    echo "          committed no objects."
    exit "$original_status"
  fi
  echo "TEARDOWN: no fixture DELETE was performed. A state-120 row and its append-only"
  echo "          attestation cannot be removed without disabling the guards under test, so"
  echo "          the dedicated database requires a COORDINATOR RESET. Test-only objects"
  echo "          committed here and removed by that reset:"
  echo "            table  public.zz_publication_conc_requests"
  echo "            func   public.zz_publication_conc_build(text,text,text)"
  echo "            grant  select on that table to authenticated (narrowest possible)"
  echo "            vault  project_url, project_secret_key (description"
  echo "                   result120-publication-${run_id}; loopback non-production sink)"
  echo "          plus this run's auth.users / private.roles rows for actor"
  echo "          ${actor_id}, the raw-writer auth row"
  echo "          64c00000-0000-4000-8000-0000000000ff, and the fixture Process rows this"
  echo "          run published."
  echo "          No trigger, policy or production guard was disabled at any point."
  exit "$original_status"
}
trap teardown EXIT

# ------------------------------------------------------------------------- mutex
if mkdir "$run_lock_dir" 2>/dev/null; then
  mutex_owned=1
else
  abort "run mutex $run_lock_dir already exists; another publication run holds it (stale locks are removed manually, never automatically)"
fi

# ---------------------------------------------------------------- fixture preflight
record "run_id=$run_id"
record "container=$container"
record "actor=$actor_id"
record "fixtures=$(printf '%s ' "${fixture_ids[@]}")"

preexisting="$(psql_json -c "set statement_timeout = '15s'; select
    (select count(*) from public.processes where id in (${fixture_list}))
  + (select count(*) from private.result_process_publications where dataset_id in (${fixture_list}))
  + (select count(*) from auth.users where id = '$actor_id')
  + (select count(*) from auth.users where id = '64c00000-0000-4000-8000-0000000000ff')
  + (select count(*) from private.roles where user_id = '$actor_id')
  + (select count(*) from vault.secrets where name in ('project_url','project_secret_key'))
  + (select count(*) from pg_proc where proname = 'zz_publication_conc_build')
  + (select count(*) from pg_class where relname = 'zz_publication_conc_requests');" | tail -1)"
if [[ "$preexisting" != "0" ]]; then
  abort "$preexisting pre-existing resource rows found; this database is not fresh. The harness never adopts or overwrites existing actors, roles or secrets."
fi
ok "the dedicated database is fresh for every surface this harness touches"

guard_state="$(psql_json -c "set statement_timeout = '15s'; select coalesce((select tgenabled from pg_trigger where tgname = 'zzz_guard_process_result_lifecycle' and not tgisinternal), 'missing');" | tail -1)"
check "the Result lifecycle guard is enabled before the run" "$guard_state" "O"
record "lifecycle_guard=$guard_state"

# ------------------------------------------------------------------------ fixtures
# A non-production loopback sink: net.http_post cannot connect to it, which is fine. The only
# requirement is that the egress call is ATTEMPTED without the missing-secret error, so the
# publisher path runs unmodified with every trigger enabled.
psql_ctl <<SQL >/dev/null
select vault.create_secret('http://127.0.0.1:61322', 'project_url', 'result120-publication-${run_id}');
select vault.create_secret('result120-publication-test-secret', 'project_secret_key', 'result120-publication-${run_id}');
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_sso_user,is_anonymous)
values ('00000000-0000-0000-0000-000000000000','${actor_id}',
  'authenticated','authenticated','${actor_email}','x',now(),'{}','{}',now(),now(),false,false);
insert into private.roles(user_id, team_id, role)
values ('${actor_id}','00000000-0000-0000-0000-000000000000','data_product_manager');
SQL
record "vault=project_url,project_secret_key description result120-publication-${run_id} (loopback non-production sink)"
ok "provisioned the Vault values the extraction egress trigger requires; every trigger stays enabled"
# private.users is created by the governed auth-to-profile mirror trigger, so this harness
# deliberately does not insert it; doing so would conflict with that trigger's own row.
ok "created this run's own actor and platform role without ON CONFLICT updating an existing actor"

# Frozen request storage plus the builder. The builder calls prepare, which requires a live
# actor identity and manager role, so the JWT claims are bound to the exact fixture actor and
# each row is asserted to carry a valid 64-hex preparation hash BEFORE it is stored.
psql_ctl <<'SQL' >/dev/null
create table public.zz_publication_conc_requests (
  label text primary key,
  request jsonb not null
);
create function public.zz_publication_conc_build(p_uuid text, p_key text, p_reason text)
returns jsonb language plpgsql as $build$
declare
  v_text text;
  v_prepare jsonb;
  v_execute jsonb;
begin
  v_text := '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"'
    || p_uuid || '"}},"administrativeInformation":{"publicationAndOwnership":'
    || '{"common:dataSetVersion":"01.00.000"}}}}';
  v_prepare := jsonb_build_object(
    'table','processes','id',p_uuid,'version','01.00.000',
    'contentText',v_text,
    'contentSha256',encode(extensions.digest(convert_to(v_text,'UTF8'),'sha256'),'hex'),
    'sourceKind','manager_attestation',
    'source',jsonb_build_object('candidateSetHash',repeat('a',64),'sourceManifestHash',repeat('b',64)),
    'audit',jsonb_build_object('reason',p_reason));
  v_execute := jsonb_set(v_prepare,'{source}',(v_prepare->'source')||jsonb_build_object(
    'executablePlanHash',repeat('c',64),'approvalHash',repeat('d',64)));
  v_execute := jsonb_set(v_execute,'{idempotencyKey}',to_jsonb(p_key));
  return jsonb_set(v_execute,'{expectedPreparationHash}',to_jsonb(
    api.qry_result_process_publish_prepare_v1(v_prepare)#>>'{data,preparationHash}'));
end $build$;
SQL

psql_ctl <<SQL >/dev/null
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
create temporary table built as
select label, public.zz_publication_conc_build(uuid, key, reason) as request
from (values
  ('contested_a','64c00000-0000-4000-8000-000000000010','key-a','contested first writer A'),
  ('contested_b','64c00000-0000-4000-8000-000000000010','key-b','contested first writer B'),
  ('retry_a','64c00000-0000-4000-8000-000000000011','retry-key','lost response retry'),
  ('race_raw','64c00000-0000-4000-8000-000000000012','race-key','non cooperating writer race')
  ,('fence_busy','64c00000-0000-4000-8000-000000000013','fence-busy-key','same actor fence contention')
) as spec(label, uuid, key, reason);

do \$check\$
declare v_bad integer;
begin
  select count(*) into v_bad from built
  where request ->> 'expectedPreparationHash' !~ '^[0-9a-f]{64}\$'
     or request ->> 'idempotencyKey' is null
     or request ->> 'contentSha256' !~ '^[0-9a-f]{64}\$'
     or request ? 'role' or request ? 'targetState' or request ? 'actorUserId';
  if v_bad <> 0 then
    raise exception 'frozen request builder produced % invalid request(s)', v_bad;
  end if;
end \$check\$;

insert into public.zz_publication_conc_requests(label, request) select label, request from built;

do \$verify\$
declare v_bad integer;
begin
  select count(*) into v_bad from (
    select api.qry_result_process_publish_prepare_v1(
      (frozen.request - 'expectedPreparationHash' - 'idempotencyKey')
      || jsonb_build_object('source',
           (frozen.request -> 'source') - 'executablePlanHash' - 'approvalHash')) as envelope
    from public.zz_publication_conc_requests as frozen) as checked
  where envelope ->> 'ok' is distinct from 'true';
  if v_bad <> 0 then
    raise exception '% frozen request(s) do not pass prepare', v_bad;
  end if;
end \$verify\$;

grant select on public.zz_publication_conc_requests to authenticated;
SQL
record "requests_frozen=contested_a,contested_b,retry_a,race_raw,fence_busy (each asserted ok with a 64-hex preparation hash)"
record "requests_grant=select on public.zz_publication_conc_requests to authenticated"
ok "froze every request once with actor-bound claims, asserted valid, and granted only SELECT"

# --------------------------------------------------------------------- barrier holder
# A persistent coordinator session whose stdin is a FIFO. It acquires a barrier advisory lock
# FIRST, and we verify that exact lock is held by that exact backend PID before any writer is
# launched. Releasing it means writing COMMIT into this same session, which is the only thing
# that can release it. A barrier nobody pre-holds is not a barrier: the first asker would just
# acquire it.
barrier_fifo="$workdir/barrier.fifo"
rm -f "$barrier_fifo"
mkfifo "$barrier_fifo"

# Keep a read-write descriptor open so the coordinator session does not see EOF between writes.
exec 9<>"$barrier_fifo"
barrier_fd_open=1

psql_client "$barrier_app" -f - < "$barrier_fifo" > "$workdir/barrier.out" 2>&1 &
barrier_shell=$!

# Handshake: the holder announces itself by taking a named advisory lock, then waits on the
# barrier lock inside the same transaction. Both are released only by the COMMIT we send later.
printf '%s\n' \
  "\\set ON_ERROR_STOP on" \
  "begin;" \
  "select pg_advisory_xact_lock(6461209, 1);" \
  "select pg_advisory_xact_lock(6461210, 1);" \
  > "$barrier_fifo"

barrier_pid=""
barrier_deadline=$((SECONDS + 20))
while ((SECONDS < barrier_deadline)); do
  candidate="$(session_pid_of "$barrier_app")"
  if [[ -n "$candidate" && "$candidate" != "0" ]]; then
    # Exact evidence: this PID holds classid 6461210, objsubid 2, objid 1 (the two-int form).
    held="$(psql_json -c "select count(*) from pg_locks where pid = $candidate and locktype = 'advisory' and granted and classid = 6461210 and objsubid = 2 and objid::bigint = 1;")"
    if [[ "${held:-0}" -ge 1 ]]; then barrier_pid="$candidate"; break; fi
  fi
  sleep 0.1
done
if [[ -z "$barrier_pid" ]]; then
  abort "the barrier holder never acquired the exact barrier lock (classid 6461210, objsubid 2, objid 1); refusing to continue because a barrier nobody holds is not a barrier"
fi
ok "the barrier holder owns the barrier lock as PID $barrier_pid before any writer starts"
record "barrier_holder_pid=$barrier_pid lock=6461210/1"

echo "# 1. two simultaneous first writers on one identity"

run_client() {
  local app_name="$1" label="$2" out="$3"
  psql_client "$app_name" -c "
${CLIENT_TIMEOUTS}
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
set role authenticated;
select api.cmd_result_process_publish_v1(request) from public.zz_publication_conc_requests where label = '$label';" \
    > "$out" 2>&1
}

response_json() {
  python3 "$script_dir/last_json_object.py" "$1"
}
json_field() {
  python3 -c '
import json, sys
value = json.loads(sys.argv[1])[sys.argv[2]]
print("true" if value is True else "false" if value is False else value)
' "$1" "$2"
}
row_count() { psql_json -c "select count(*) from public.processes where id = '$1';"; }
receipt_count() { psql_json -c "select count(*) from private.result_process_publications where dataset_id = '$1';"; }

# The two writers race the SAME identity with DIFFERENT keys. Neither is barrier-blocked here:
# this is a genuine uniqueness race, and the outcome is resolved by the database.
run_client "$client_a" contested_a "$workdir/a1.out" &
a_shell=$!
run_client "$client_b" contested_b "$workdir/b1.out" &
b_shell=$!
wait "$a_shell" || true
wait "$b_shell" || true

a1="$(response_json "$workdir/a1.out")"
b1="$(response_json "$workdir/b1.out")"
a_ok="$(json_field "$a1" ok)"
b_ok="$(json_field "$b1" ok)"

if [[ "$a_ok" == "true" && "$b_ok" == "false" ]] || [[ "$a_ok" == "false" && "$b_ok" == "true" ]]; then
  ok "exactly one of two simultaneous first writers published"
else
  bad "two first writers produced an unexpected outcome (a=$a_ok b=$b_ok)"
fi
loser="$( [[ "$a_ok" == "true" ]] && echo "$b1" || echo "$a1" )"
winner_json="$( [[ "$a_ok" == "true" ]] && echo "$a1" || echo "$b1" )"
winner_label="$( [[ "$a_ok" == "true" ]] && echo contested_a || echo contested_b )"
check_json_field "the losing writer reports a typed publication conflict" "$loser" code "result_publication_conflict"
check "exactly one Process row exists" "$(row_count 64c00000-0000-4000-8000-000000000010)" "1"
check "exactly one receipt exists" "$(receipt_count 64c00000-0000-4000-8000-000000000010)" "1"
check "the contested row is at 120" \
  "$(psql_json -c "select state_code from public.processes where id='64c00000-0000-4000-8000-000000000010';")" "120"

echo "# 2. exact retry replays identical frozen bytes and returns the identical receipt"

# Replay the winner's ORIGINAL frozen request. Its preparation hash was computed while the row
# was absent, so a recompute-first protocol would wrongly reject this; the receipt must win and
# the returned receipt must equal the first one field by field.
run_client "$client_a" "$winner_label" "$workdir/a2.out"
a2="$(response_json "$workdir/a2.out")"
check_json_field "the replayed retry succeeds" "$a2" ok "true"
check_json_field "the replayed retry is reported as reused" "$a2" reused "true"
check_json_field "the replayed retry returns the identical receipt identity" \
  "$a2" data.receiptId "$(python3 "$script_dir/json_path_value.py" "$winner_json" data.receiptId)"
check_json_field "the replayed retry returns the original preparation hash" \
  "$a2" data.preparationHash "$(python3 "$script_dir/json_path_value.py" "$winner_json" data.preparationHash)"
check_json_field "the replayed retry returns the identical content hash" \
  "$a2" data.contentSha256 "$(python3 "$script_dir/json_path_value.py" "$winner_json" data.contentSha256)"
check_json_present "the replayed receipt still carries the attested approval hash" "$a2" data.approvalHash
check "the exact retry created no second receipt" \
  "$(receipt_count 64c00000-0000-4000-8000-000000000010)" "1"

echo "# 3. observed barrier: a second writer really waits on the held transaction"

# Client A opens an explicit transaction, publishes, and then blocks on the coordinator's
# ALREADY-HELD barrier lock inside that same transaction, so its row stays uncommitted.
cat > "$workdir/hold.sql" <<SQL
${CLIENT_TIMEOUTS}
begin;
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
set role authenticated;
select api.cmd_result_process_publish_v1(request) from public.zz_publication_conc_requests where label = 'retry_a';
select pg_advisory_xact_lock(6461210, 1);
commit;
SQL

psql_client "$client_a" -f - < "$workdir/hold.sql" > "$workdir/hold.out" 2>&1 &
hold_shell=$!

# Wait until A is provably inside the command: its own PID holds the publication identity lock
# whose objid is exactly the migration's hashtext(<id>:<version>), unsigned.
hold_pid=""
hold_deadline=$((SECONDS + 25))
while ((SECONDS < hold_deadline)); do
  candidate="$(session_pid_of "$client_a")"
  if [[ -n "$candidate" && "$candidate" != "0" ]]; then
    held="$(psql_json -c "select count(*) from pg_locks where pid = $candidate and locktype = 'advisory' and granted and classid = 6461201 and objsubid = 2 and objid::bigint = (hashtext('64c00000-0000-4000-8000-000000000011:01.00.000')::bigint & 4294967295);")"
    if [[ "${held:-0}" -ge 1 ]]; then hold_pid="$candidate"; break; fi
  fi
  sleep 0.1
done
if [[ -z "$hold_pid" ]]; then
  abort "client A never held the exact publication identity advisory lock for the retry identity"
fi
ok "client A holds the exact publication identity lock as PID $hold_pid"

# Now A must also be blocked on the coordinator's barrier, which proves the hold is real and
# that the coordinator owns the lock rather than A having acquired a free one.
barrier_blocked=0
barrier_deadline=$((SECONDS + 20))
while ((SECONDS < barrier_deadline)); do
  if [[ "$(psql_json -c "select count(*) from pg_stat_activity where pid = $hold_pid and wait_event_type = 'Lock' and $barrier_pid = any(pg_blocking_pids(pid));")" -ge 1 ]]; then
    barrier_blocked=1; break
  fi
  sleep 0.1
done
check "client A is blocked by the coordinator barrier holder's PID" "$barrier_blocked" "1"
record "hold_pid=$hold_pid blocked_by_barrier_pid=$barrier_pid"

# Client B publishes the SAME identity. It must be observed blocked BY A's PID.
psql_client "$client_b" -c "
${CLIENT_TIMEOUTS}
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
set role authenticated;
select api.cmd_result_process_publish_v1(request) from public.zz_publication_conc_requests where label = 'retry_a';" \
  > "$workdir/waiting.out" 2>&1 &
waiting_shell=$!

waiting_observed=0
wait_deadline=$((SECONDS + 20))
while ((SECONDS < wait_deadline)); do
  b_pid="$(session_pid_of "$client_b")"
  if [[ -n "$b_pid" && "$b_pid" != "0" ]]; then
    blocked="$(psql_json -c "select count(*) from pg_stat_activity where pid = $b_pid and wait_event_type = 'Lock' and $hold_pid = any(pg_blocking_pids(pid));")"
    if [[ "${blocked:-0}" -ge 1 ]]; then waiting_observed=1; break; fi
  fi
  sleep 0.1
done
check "the second writer was observed blocked by the first writer's PID" "$waiting_observed" "1"
record "waiter_pid=$(session_pid_of "$client_b") blocked_by_holder_pid=$hold_pid"

# Release the barrier: COMMIT in the holder's own session is the only thing that can release it.
printf 'commit;\n' > "$barrier_fifo"
ok "released the barrier by committing in the holder's own session"

wait "$hold_shell" || true
wait "$waiting_shell" || true

check "the blocked second writer produced no second receipt" \
  "$(receipt_count 64c00000-0000-4000-8000-000000000011)" "1"
check_json_field "the blocked second writer resolved as reuse" \
  "$(response_json "$workdir/waiting.out")" reused "true"

echo "# 4. non-cooperating writer holding the identity uncommitted"

# A raw client inserts the fixture identity itself and then blocks on a SECOND coordinator-held
# barrier, so its row is genuinely uncommitted and provably complete. The publisher is then
# invoked from another client while that row is invisible: it must classify the identity as
# absent, attempt its own insert, and be blocked by the raw transaction rather than succeeding.
#
# The raw writer uses a DIFFERENT user_id on purpose. `private.dataset_flow_identity_active_fence`
# takes a non-blocking actor lock keyed on the row's user_id, so a raw writer using the publisher's
# own actor would make the publisher raise 55P03 before it ever reached the unique index. Using a
# distinct owner isolates the case under test: the primary-key uniqueness race.
raw_owner="64c00000-0000-4000-8000-0000000000ff"
psql_ctl -c "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_sso_user,is_anonymous) values ('00000000-0000-0000-0000-000000000000','${raw_owner}','authenticated','authenticated','pub-raw-${run_id}@example.invalid','x',now(),'{}','{}',now(),now(),false,false);" >/dev/null
record "raw_writer_owner=${raw_owner} (distinct from the publisher actor by design)"
psql_ctl -c "select 1;" >/dev/null
printf 'begin;\nselect pg_advisory_xact_lock(6461211, 1);\n' > "$barrier_fifo"

barrier2_pid=""
barrier2_deadline=$((SECONDS + 20))
while ((SECONDS < barrier2_deadline)); do
  candidate="$(session_pid_of "$barrier_app")"
  if [[ -n "$candidate" && "$candidate" != "0" ]]; then
    held="$(psql_json -c "select count(*) from pg_locks where pid = $candidate and locktype = 'advisory' and granted and classid = 6461211 and objsubid = 2 and objid::bigint = 1;")"
    if [[ "${held:-0}" -ge 1 ]]; then barrier2_pid="$candidate"; break; fi
  fi
  sleep 0.1
done
if [[ -z "$barrier2_pid" ]]; then
  abort "the coordinator never acquired the second barrier lock (6461211/1)"
fi
ok "the coordinator owns the second barrier lock as PID $barrier2_pid"

raw_text='{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"64c00000-0000-4000-8000-000000000012"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}'
cat > "$workdir/raw.sql" <<SQL
${CLIENT_TIMEOUTS}
begin;
insert into public.processes (id, version, json_ordered, user_id, state_code)
values ('64c00000-0000-4000-8000-000000000012','01.00.000','${raw_text}'::json, '${raw_owner}', 120);
select pg_advisory_xact_lock(6461211, 1);
commit;
SQL

psql_client "$client_a" -f - < "$workdir/raw.sql" > "$workdir/raw.out" 2>&1 &
raw_shell=$!

# Deterministic completion barrier: the raw writer has finished its insert only when it holds an
# uncommitted transactionid lock AND is blocked by the coordinator's second barrier.
raw_pid=""
raw_deadline=$((SECONDS + 25))
while ((SECONDS < raw_deadline)); do
  candidate="$(session_pid_of "$client_a")"
  if [[ -n "$candidate" && "$candidate" != "0" ]]; then
    holds_row="$(psql_json -c "select count(*) from pg_locks where pid = $candidate and locktype = 'transactionid' and granted;")"
    on_barrier="$(psql_json -c "select count(*) from pg_stat_activity where pid = $candidate and wait_event_type = 'Lock' and $barrier2_pid = any(pg_blocking_pids(pid));")"
    if [[ "${holds_row:-0}" -ge 1 && "${on_barrier:-0}" -ge 1 ]]; then raw_pid="$candidate"; break; fi
  fi
  sleep 0.1
done
if [[ -z "$raw_pid" ]]; then
  abort "the raw writer never completed its insert and reached the held barrier"
fi
ok "the raw writer completed its insert and is blocked on the coordinator barrier as PID $raw_pid"

check "the uncommitted raw row is invisible to other clients" \
  "$(psql_json -c "select count(*) from public.processes where id='64c00000-0000-4000-8000-000000000012';" | tail -1)" "0"

psql_client "$client_b" -c "
${CLIENT_TIMEOUTS}
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
set role authenticated;
select api.cmd_result_process_publish_v1(request) from public.zz_publication_conc_requests where label = 'race_raw';" \
  > "$workdir/race.out" 2>&1 &
race_shell=$!

# The publisher must be blocked by the RAW writer's PID specifically.
race_waiting=0
race_deadline=$((SECONDS + 20))
while ((SECONDS < race_deadline)); do
  b_pid="$(session_pid_of "$client_b")"
  if [[ -n "$b_pid" && "$b_pid" != "0" ]]; then
    blocked="$(psql_json -c "select count(*) from pg_stat_activity where pid = $b_pid and wait_event_type = 'Lock' and $raw_pid = any(pg_blocking_pids(pid));")"
    if [[ "${blocked:-0}" -ge 1 ]]; then race_waiting=1; break; fi
  fi
  sleep 0.1
done
check "the publisher was observed blocked by the raw writer's own PID" "$race_waiting" "1"
record "raw_writer_pid=$raw_pid publisher_pid=$(session_pid_of "$client_b") blocked_by_raw=$race_waiting"

# Release the raw writer by committing in the coordinator's own session.
printf 'commit;\n' > "$barrier_fifo"
record "raw_writer_released=committed in the coordinator session that held barrier 6461211/1"

wait "$raw_shell" || true
wait "$race_shell" || true

if grep -qi "duplicate key\|unique constraint" "$workdir/race.out"; then
  bad "the publisher surfaced a raw uniqueness error instead of a typed conflict"
else
  race_out="$(response_json "$workdir/race.out")"
  if [[ -n "$race_out" ]]; then
    check_json_field "the publisher resolved the race with a typed conflict" "$race_out" code "result_publication_conflict"
  else
    bad "the publisher produced no parseable response for the non-cooperating race"
  fi
fi
check "the non-cooperating race left exactly one row" \
  "$(row_count 64c00000-0000-4000-8000-000000000012)" "1"
check "the non-cooperating race left no publisher receipt" \
  "$(receipt_count 64c00000-0000-4000-8000-000000000012)" "0"

echo "# 5. generic readers still cannot see published Results"

echo "# 4b. same-actor row-fence contention is reported as typed retryable busy"

# The governed row fence takes a NON-BLOCKING actor lock on
# 'dataset-flow-identity-actor:<user_id>'. A separate session holds that exact 64-bit advisory
# key, so a publisher using the SAME actor cannot insert and must receive the typed retryable
# envelope rather than a raw SQLSTATE. This is real two-session contention.
#
# Identity 013 is a FOURTH, distinct fixture identity: it is proven absent at preflight and is
# not touched by any earlier scenario, so the busy result cannot be confused with the conflict
# that scenario 4 legitimately produces on its own (already committed) identity.
fence_fifo="$workdir/fence.fifo"
rm -f "$fence_fifo"
mkfifo "$fence_fifo"
exec 8<>"$fence_fifo"
fence_fd_open=1

fence_key="dataset-flow-identity-actor:${actor_id}"
fence_key_hi="((hashtextextended('${fence_key}', 0) >> 32) & 4294967295)"
fence_key_lo="(hashtextextended('${fence_key}', 0) & 4294967295)"

psql_client "$fence_app" -f - < "$fence_fifo" > "$workdir/fence.out" 2>&1 &
fence_shell=$!
printf '%s\n' \
  "\\set ON_ERROR_STOP on" \
  "begin;" \
  "select pg_advisory_xact_lock(6461209, 2);" \
  "select pg_try_advisory_xact_lock(hashtextextended('${fence_key}', 0));" \
  > "$fence_fifo"

fence_deadline=$((SECONDS + 20))
while ((SECONDS < fence_deadline)); do
  candidate="$(session_pid_of "$fence_app")"
  if [[ -n "$candidate" && "$candidate" != "0" ]]; then
    # Full 64-bit match: a hashtextextended key stores its HIGH 32 bits in classid, its LOW 32
    # bits in objid, with objsubid = 1 for the one-argument bigint form. Matching only the low
    # bits would accept an unrelated key that happens to share them.
    held="$(psql_json -c "select count(*) from pg_locks where pid = $candidate and locktype = 'advisory' and granted and objsubid = 1 and classid::bigint = ${fence_key_hi} and objid::bigint = ${fence_key_lo};")"
    if [[ "${held:-0}" -ge 1 ]]; then fence_holder_pid="$candidate"; break; fi
  fi
  sleep 0.1
done
if [[ -z "$fence_holder_pid" ]]; then
  abort "the fence holder never acquired the exact 64-bit actor lock for ${fence_key}"
fi
ok "a separate session holds the exact actor fence key (classid/objid/objsubid=1) as PID $fence_holder_pid"
record "fence_holder_pid=$fence_holder_pid app=${fence_app} key=${fence_key}"

publish_fenced() {
  local out="$1"
  psql_client "$client_b" -c "
${CLIENT_TIMEOUTS}
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
set role authenticated;
select api.cmd_result_process_publish_v1(request) from public.zz_publication_conc_requests where label = 'fence_busy';" \
    > "$out" 2>&1
}

publish_fenced "$workdir/fence-publish.out"
fence_out="$(response_json "$workdir/fence-publish.out")"
if [[ -n "$fence_out" ]]; then
  check_json_field "same-actor fence contention reports the typed retryable code" "$fence_out" code "result_publication_busy"
  check_json_field "the busy envelope carries the conflict class" "$fence_out" status "409"
  check_json_present "the busy envelope carries bounded retry guidance" "$fence_out" message
else
  if grep -qE "FLOW_IDENTITY_ACTIVE_SCOPE_ACTOR_FENCE_BUSY" "$workdir/fence-publish.out"; then
    bad "the publisher surfaced a raw actor-fence SQLSTATE instead of the typed busy envelope"
  else
    bad "the publisher produced no parseable response under fence contention"
  fi
fi
check "fence contention left no Process row" \
  "$(row_count 64c00000-0000-4000-8000-000000000013)" "0"
check "fence contention left no receipt" \
  "$(receipt_count 64c00000-0000-4000-8000-000000000013)" "0"
check "fence contention left no attestation audit row" \
  "$(psql_json -c "select count(*) from private.command_audit_log where command='cmd_result_process_publish_v1' and target_id='64c00000-0000-4000-8000-000000000013';")" "0"

# Release the holder: COMMIT then an explicit quit INSIDE its own session, then bound the wait.
# The holder is a persistent psql reading a FIFO, so waiting on it with the write end still open
# would block forever; \q makes it exit on its own.
printf 'commit;\n\\q\n' > "$fence_fifo"
exec 8>&- 2>/dev/null || true
fence_fd_open=0
fence_wait_deadline=$((SECONDS + 20))
while ((SECONDS < fence_wait_deadline)); do
  kill -0 "$fence_shell" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$fence_shell" 2>/dev/null; then
  if [[ -n "$fence_holder_pid" && "$fence_holder_pid" != "0" ]]; then
    psql_ctl -c "select pg_terminate_backend($fence_holder_pid);" >/dev/null 2>&1 || true
  fi
  bad "the fence holder did not exit after commit + quit; its exact PID was terminated"
else
  ok "the fence holder committed and exited in its own session"
fi
wait "$fence_shell" 2>/dev/null || true
record "fence_released=commit then quit in the holder session that owned ${fence_key}"

# The SAME frozen request must now succeed, and repeating it must return the identical receipt.
publish_fenced "$workdir/fence-after.out"
fence_after="$(response_json "$workdir/fence-after.out")"
check_json_field "the identical request succeeds once the fence is released" "$fence_after" ok "true"
publish_fenced "$workdir/fence-repeat.out"
fence_repeat="$(response_json "$workdir/fence-repeat.out")"
check_json_field "repeating the same frozen request returns the same receipt" "$fence_repeat" reused "true"
check_json_field "the repeated receipt identity is unchanged" \
  "$fence_repeat" data.receiptId "$(python3 "$script_dir/json_path_value.py" "$fence_after" data.receiptId)"

psql_client "$client_b" -c "
${CLIENT_TIMEOUTS}
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
set role authenticated;
select count(*) from public.processes where id = '64c00000-0000-4000-8000-000000000010';" \
  > "$workdir/generic.out" 2>&1
# psql prints a formatted result followed by a trailing blank line, so take the LAST non-blank
# line, strip surrounding whitespace, and require it to be numeric. `tail -1` would compare an
# empty string and report a false failure.
generic_value="$(tr -d ' \r' < "$workdir/generic.out" | grep -E '^[0-9]+$' | tail -1)"
check "a generic authenticated read cannot see the published Result" \
  "$generic_value" "0"

# Authorized readback still works for the same actor, which is why the isolation is a read-path
# restriction rather than a loss of the publication itself.
psql_client "$client_b" -c "
${CLIENT_TIMEOUTS}
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','${actor_id}',false);
set role authenticated;
select api.qry_result_process_publication_readback_v1(jsonb_build_object(
  'id','64c00000-0000-4000-8000-000000000010','version','01.00.000','idempotencyKey','$( [[ "$winner_label" == "contested_a" ]] && echo key-a || echo key-b )'));
" > "$workdir/readback.out" 2>&1
check_json_field "the authorized readback still resolves the publication" \
  "$(response_json "$workdir/readback.out")" ok "true"

echo
if ((failures > 0)); then
  echo "RESULT: FAIL ($failures assertions failed)"
  exit 1
fi
echo "RESULT: PASS (all publication concurrency assertions passed)"
