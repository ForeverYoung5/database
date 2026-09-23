#!/usr/bin/env python3
"""Database #703: real, bounded three-session scheduler lock regression.

This harness may connect ONLY to the named disposable local container. It does
not start Docker, change cron, invoke a worker, or use a network/database URL.
The shared synthetic fixture is committed so independent sessions can see it;
its temporary getter replacements are restored before that commit. Test calls
are rolled back. Finally, only the captured fixture IDs/audit IDs are deleted.

Run serially with other tests against this stack, for example:
  python supabase/tests/regression/20260923_derivative_scheduler_concurrency.py \
    --receipt /private/tmp/scheduler703-concurrency-01.json

The receipt must be a NEW file. Raw SQL/stdout/stderr, function definitions and
getter values never appear in it. A failed cleanup retains exact synthetic IDs
in the receipt for explicit recovery; the harness never truncates a table.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import secrets
import subprocess
import threading
import time
from typing import Any
import uuid


CONTAINER = "supabase_db_database-engine-703-scheduler"
TOTAL = 40
LOCKED_PREFIX = 5
VISIT_LIMIT = 25
COMMAND_TIMEOUT = 15.0
FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "derivative_scheduler703.sql"
SENTINELS = (
    ("flows", "703fffff-0000-4000-8000-000000000001"),
    ("processes", "703fffff-0000-4000-8000-000000000002"),
)


class HarnessError(RuntimeError):
    """Messages are authored by the harness, never raw database diagnostics."""


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def uuid_array(values: list[str]) -> str:
    # IDs come only from our synthetic fixture, but validate before SQL assembly.
    return "array[" + ",".join(literal(str(uuid.UUID(value))) for value in values) + "]::uuid[]"


def integer_array(values: list[int]) -> str:
    if any(type(value) is not int or value < 1 for value in values):
        raise HarnessError("Invalid captured synthetic audit identity.")
    return "array[" + ",".join(str(value) for value in values) + "]::bigint[]"


def local_docker_endpoint() -> str:
    """Resolve local client configuration without contacting a remote daemon."""
    explicit_host = os.environ.get("DOCKER_HOST", "").strip()
    if explicit_host and not os.environ.get("DOCKER_CONTEXT"):
        endpoint = explicit_host
    else:
        try:
            result = subprocess.run(
                ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                capture_output=True, text=True, timeout=5, check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise HarnessError("Cannot resolve the local Docker endpoint; no database connection attempted.") from exc
        if result.returncode or len(result.stdout.splitlines()) != 1:
            raise HarnessError("Local Docker context is missing or ambiguous; no database connection attempted.")
        endpoint = result.stdout.strip()
    if not endpoint.startswith(("unix:///", "npipe:////")):
        raise HarnessError("Remote or TCP Docker endpoints are forbidden for this local regression.")
    return endpoint


class Session:
    def __init__(self, label: str, run_id: str, deadline: float, docker_endpoint: str):
        self.label = label
        self.application = f"scheduler703-{run_id}-{label}"
        self.deadline = deadline
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.stderr_bytes = 0
        self.sqlstates: list[str] = []
        self.pid: int | None = None
        environment = dict(os.environ)
        for key in ("DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"):
            environment.pop(key, None)
        self.process = subprocess.Popen(
            ["docker", "--host", docker_endpoint, "exec", "-i", CONTAINER, "psql", "-X", "-qAt",
             "-h", "/var/run/postgresql", "-U", "postgres", "-d", "postgres",
             "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=sqlstate", "-v", "SHOW_CONTEXT=never"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1, env=environment,
        )
        threading.Thread(target=self._stdout, daemon=True).start()
        threading.Thread(target=self._stderr, daemon=True).start()
        try:
            self.query(
                f"set application_name = {literal(self.application)};\n"
                "set statement_timeout = '12s';\n"
                "set lock_timeout = '2s';\n"
                "set idle_in_transaction_session_timeout = '90s';\n"
                "set client_min_messages = warning;"
            )
            self.pid = int(self.scalar("select pg_backend_pid();"))
        except BaseException:
            self.close()
            raise

    def _stdout(self) -> None:
        assert self.process.stdout is not None
        try:
            for line in self.process.stdout:
                self.lines.put(line.rstrip("\r\n"))
        finally:
            self.lines.put(None)

    def _stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            # The fixture temporarily contains getter DDL. Do not retain/echo
            # psql CONTEXT or query text if a server error occurs.
            self.stderr_bytes += len(line.encode("utf-8"))
            match = re.search(r"\b(?:ERROR|FATAL):\s+([0-9A-Z]{5})\b", line)
            if match and len(self.sqlstates) < 20:
                self.sqlstates.append(match[1])

    def query(self, sql: str, *, cleanup: bool = False) -> list[str]:
        marker = "SCHEDULER703_END_" + secrets.token_hex(12)
        wait = COMMAND_TIMEOUT if cleanup else min(COMMAND_TIMEOUT, self.deadline - time.monotonic())
        if wait <= 0:
            raise HarnessError("Harness wall-clock bound exhausted.")
        if self.process.poll() is not None or self.process.stdin is None:
            raise HarnessError(f"Local {self.label} psql session is unavailable; diagnostics withheld.")
        try:
            self.process.stdin.write(sql.rstrip() + "\n\\echo " + marker + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise HarnessError(f"Local {self.label} psql input failed; outcome requires readback.") from exc
        result = []
        end = time.monotonic() + wait
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise HarnessError(f"Local {self.label} psql response exceeded its bound.")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty as exc:
                raise HarnessError(f"Local {self.label} psql response exceeded its bound.") from exc
            if line is None:
                raise HarnessError(f"Local {self.label} psql exited before its completion marker; diagnostics withheld.")
            if line == marker:
                return result
            if line:
                result.append(line)
            if len(result) > 100:
                raise HarnessError("Unexpectedly large local psql response; refusing unbounded output.")

    def scalar(self, sql: str, *, cleanup: bool = False) -> str:
        lines = self.query(sql, cleanup=cleanup)
        if len(lines) != 1:
            raise HarnessError(f"Local {self.label} query did not return exactly one scalar.")
        return lines[0]

    def json(self, sql: str, *, cleanup: bool = False) -> Any:
        try:
            return json.loads(self.scalar(sql, cleanup=cleanup))
        except ValueError as exc:
            raise HarnessError("Local fixture returned malformed structured evidence.") from exc

    def close(self) -> bool:
        rolled_back = False
        if self.process.poll() is None:
            try:
                self.query("rollback;", cleanup=True)
                rolled_back = True
            except (HarnessError, OSError):
                pass
            try:
                if self.process.stdin:
                    self.process.stdin.write("\\q\n")
                    self.process.stdin.flush()
                    self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        return rolled_back or self.process.returncode == 0


GUARD = """
do $guard$
begin
  if inet_server_addr() is not null or current_database() <> 'postgres' or current_user <> 'postgres'
    or util.project_url() is distinct from 'http://127.0.0.1:9'
    or exists (select 1 from cron.job where active)
    or exists (select 1 from public.flows)
    or exists (select 1 from public.processes)
    or exists (select 1 from util.dataset_derivative_rebuild_requests)
    or exists (select 1 from pgmq.q_embedding_jobs)
    or exists (select 1 from util.pending_embedding_jobs where status = 'pending')
    or exists (select 1 from net.http_request_queue) then
    raise exception 'Isolated scheduler703 startup guard refused; no fixture was admitted';
  end if;
  if not exists (select 1 from pg_attribute
    where attrelid = 'util.dataset_derivative_rebuild_requests'::regclass
      and attname = 'scheduler_selected_at' and not attisdropped)
    or to_regprocedure('private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamp with time zone)') is null then
    raise exception 'Scheduler703 candidate migration is not installed';
  end if;
end;
$guard$;
"""


def seed(session: Session, fixture_sql: str) -> dict[str, Any]:
    session.query("begin;\n" + GUARD + """
create temporary table scheduler703_getters on commit drop as
select identity, pg_get_functiondef(identity) as definition
from unnest(array['util.project_url()'::regprocedure,
                  'util.project_secret_key()'::regprocedure]) identities(identity);
create temporary table scheduler703_prior_audit on commit drop as
select id from private.command_audit_log;
""" + fixture_sql + """
do $seed$ begin perform pg_temp.scheduler703_seed(0, 40, 1, 50); end; $seed$;
-- Make the first five blocking rows and their sixth same-batch peer exact,
-- without changing any primary payload or the 420-second drain relationship.
update util.dataset_derivative_rebuild_requests r
set updated_at = r.admitted_at + t.ordinal * interval '1 millisecond'
from pg_temp.scheduler703_targets t where t.request_id = r.id;
do $restore$
declare item record;
begin
  for item in select * from pg_temp.scheduler703_getters loop
    execute item.definition;
    if pg_get_functiondef(item.identity) is distinct from item.definition then
      raise exception 'Original getter DDL did not restore exactly';
    end if;
  end loop;
  if util.project_url() is distinct from 'http://127.0.0.1:9'
    or exists (select 1 from cron.job where active)
    or exists (select 1 from net.http_request_queue)
    or exists (select 1 from pgmq.q_embedding_jobs)
    or exists (select 1 from util.pending_embedding_jobs where status = 'pending')
    or exists (select 1 from util.dataset_derivative_rebuild_requests
      where status <> 'queued' or phase <> 'admitted') then
    raise exception 'Synthetic fixture is not safe to expose to other local sessions';
  end if;
  if exists (select 1 from private.command_audit_log audit
    where not exists (select 1 from pg_temp.scheduler703_prior_audit old where old.id = audit.id)
      and (audit.command <> 'cmd_dataset_derivative_rebuild_plan_guarded'
        or audit.payload->>'operation_id' is distinct from 'scheduler703-synthetic'
        or not exists (select 1 from pg_temp.scheduler703_batches b
          where b.batch_id::text = audit.payload->>'batch_id'))) then
    raise exception 'Unexpected audit write during isolated fixture creation';
  end if;
end;
$restore$;
""")
    result = session.json("""
select jsonb_build_object(
  'targets', (select jsonb_agg(jsonb_build_object('ordinal', ordinal,
    'table', target_table, 'id', target_id, 'version', target_version,
    'request_id', request_id, 'actor_user_id', actor_user_id, 'batch_id', batch_id)
    order by ordinal) from pg_temp.scheduler703_targets),
  'audit_ids', (select coalesce(jsonb_agg(audit.id order by audit.id), '[]'::jsonb)
    from private.command_audit_log audit where not exists
      (select 1 from pg_temp.scheduler703_prior_audit old where old.id = audit.id)),
  'getters_restored', true,
  'primary_hashes', (select jsonb_object_agg(identity, fingerprint) from (
    select 'flows/' || row_value.id || '/' || btrim(row_value.version::text) identity,
      util.dataset_derivative_rebuild_sha256(to_jsonb(row_value)::text) fingerprint
    from public.flows row_value
    union all
    select 'processes/' || row_value.id || '/' || btrim(row_value.version::text),
      util.dataset_derivative_rebuild_sha256(to_jsonb(row_value)::text)
    from public.processes row_value) rows));
""")
    if (not isinstance(result, dict) or len(result.get("targets", [])) != TOTAL
            or not result.get("getters_restored") or not result.get("audit_ids")):
        raise HarnessError("Synthetic fixture evidence is incomplete; refusing commit.")
    targets = result["targets"]
    if ([target["ordinal"] for target in targets] != list(range(1, TOTAL + 1))
            or len({target["actor_user_id"] for target in targets}) != 1
            or len({target["batch_id"] for target in targets}) != 1):
        raise HarnessError("Fixture is not the intended one-actor, one-batch ordered cohort.")
    uuid_array([target["request_id"] for target in targets])
    return result


def state(session: Session, ids: list[str]) -> dict[str, Any]:
    return session.json(f"""
select jsonb_build_object(
  'request_digest', (select md5(jsonb_agg(to_jsonb(r) order by r.id)::text)
    from util.dataset_derivative_rebuild_requests r where r.id = any({uuid_array(ids)})),
  'audit_count', (select count(*) from private.command_audit_log),
  'http_count', (select count(*) from net.http_request_queue),
  'embedding_count', (select count(*) from pgmq.q_embedding_jobs),
  'pending_count', (select count(*) from util.pending_embedding_jobs where status = 'pending'));
""")


def probe_locks(probe: Session, ids: list[str]) -> list[str]:
    blocked = []
    probe.query("begin;")
    try:
        for request_id in ids:
            row_id = literal(str(uuid.UUID(request_id)))
            # The successful row lock is acquired inside a subtransaction and
            # deliberately rolled back. The probe cannot accumulate row locks.
            probe.query(f"""
do $probe$
declare found_id uuid;
begin
  begin
    select id into found_id from util.dataset_derivative_rebuild_requests
      where id = {row_id}::uuid for update nowait;
    if found_id is null then raise exception using errcode='P7031', message='Synthetic request disappeared'; end if;
    raise exception using errcode='P7030', message='Release successful probe lock';
  exception
    when sqlstate 'P7030' then perform set_config('scheduler703.probe', 'free', true);
    when lock_not_available then perform set_config('scheduler703.probe', 'blocked', true);
  end;
end;
$probe$;
""")
            outcome = probe.scalar("select current_setting('scheduler703.probe');")
            if outcome == "blocked":
                blocked.append(request_id)
            elif outcome != "free":
                raise HarnessError("Unexpected NOWAIT probe classification.")
    finally:
        probe.query("rollback;", cleanup=True)
    return blocked


def verify_primary(session: Session, fixture: dict[str, Any]) -> None:
    target_ids = [target["id"] for target in fixture["targets"]]
    target_ids.extend(identity for _table, identity in SENTINELS)
    result = session.json(f"""
select jsonb_object_agg(identity, fingerprint) from (
  select 'flows/' || r.id || '/' || btrim(r.version::text) identity,
    util.dataset_derivative_rebuild_sha256(to_jsonb(r)::text) fingerprint
  from public.flows r where r.id = any({uuid_array(target_ids)})
  union all
  select 'processes/' || r.id || '/' || btrim(r.version::text),
    util.dataset_derivative_rebuild_sha256(to_jsonb(r)::text)
  from public.processes r where r.id = any({uuid_array(target_ids)})
) rows;
""")
    if result != fixture["primary_hashes"]:
        raise HarnessError("Synthetic primary rows or untouched sentinels changed.")


def cleanup_fixture(control: Session, fixture: dict[str, Any]) -> dict[str, Any]:
    requests = uuid_array([target["request_id"] for target in fixture["targets"]])
    process_ids = uuid_array([target["id"] for target in fixture["targets"] if target["table"] == "processes"]
                            + [SENTINELS[1][1]])
    flow_ids = uuid_array([target["id"] for target in fixture["targets"] if target["table"] == "flows"]
                         + [SENTINELS[0][1]])
    audits = integer_array(fixture["audit_ids"])
    control.query("begin;", cleanup=True)
    try:
        present = control.json(f"""
select coalesce(jsonb_object_agg(identity, fingerprint), '{{}}'::jsonb) from (
  select 'flows/' || r.id || '/' || btrim(r.version::text) identity,
    util.dataset_derivative_rebuild_sha256(to_jsonb(r)::text) fingerprint
  from public.flows r where r.id=any({flow_ids})
  union all
  select 'processes/' || r.id || '/' || btrim(r.version::text),
    util.dataset_derivative_rebuild_sha256(to_jsonb(r)::text)
  from public.processes r where r.id=any({process_ids})
) rows;
""", cleanup=True)
        if any(fixture["primary_hashes"].get(identity) != value for identity, value in present.items()):
            raise HarnessError("Cleanup refuses a synthetic row changed outside the rollback-only tests.")
        control.query(f"""
do $cleanup$
begin
  if util.project_url() is distinct from 'http://127.0.0.1:9'
    or exists (select 1 from cron.job where active) then
    raise exception 'Cleanup local isolation guard changed';
  end if;
  if exists (select 1 from public.processes p where p.id = any({process_ids})
      and (coalesce(p.json_ordered::jsonb->>'fixture', '') not in ('scheduler703', 'outside-process')
        or btrim(p.version::text) <> '00.00.001'))
    or exists (select 1 from public.flows f where f.id = any({flow_ids})
      and (coalesce(f.json_ordered::jsonb->>'fixture', '') not in ('scheduler703', 'outside-flow')
        or btrim(f.version::text) <> '00.00.001')) then
    raise exception 'Cleanup refuses a changed fixture identity';
  end if;
end;
$cleanup$;
delete from util.dataset_derivative_rebuild_requests where id = any({requests});
delete from private.command_audit_log where id = any({audits});
delete from public.processes where id = any({process_ids}) and btrim(version::text)='00.00.001';
delete from public.flows where id = any({flow_ids}) and btrim(version::text)='00.00.001';
""", cleanup=True)
        result = control.json(f"""
select jsonb_build_object(
 'owned_requests_remaining', (select count(*) from util.dataset_derivative_rebuild_requests where id=any({requests})),
 'owned_audits_remaining', (select count(*) from private.command_audit_log where id=any({audits})),
 'owned_processes_remaining', (select count(*) from public.processes where id=any({process_ids})),
 'owned_flows_remaining', (select count(*) from public.flows where id=any({flow_ids})),
 'http_count', (select count(*) from net.http_request_queue),
 'embedding_count', (select count(*) from pgmq.q_embedding_jobs),
 'pending_count', (select count(*) from util.pending_embedding_jobs where status='pending'));
""", cleanup=True)
        if any(result.values()):
            raise HarnessError("Owned synthetic cleanup or queue emptiness was not verified.")
        control.query("commit;", cleanup=True)
        return {"status": "passed", **result, "sequence_values_restored": False}
    except BaseException:
        try:
            control.query("rollback;", cleanup=True)
        except (HarnessError, OSError):
            pass
        raise


def run(receipt: dict[str, Any], save, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    run_id = secrets.token_hex(6)
    sessions: list[Session] = []
    fixture: dict[str, Any] | None = None
    fixture_exposed = False
    control: Session | None = None
    docker_endpoint = local_docker_endpoint()
    fixture_sql = FIXTURE.read_text(encoding="utf-8")
    receipt["fixture_sha256"] = hashlib.sha256(fixture_sql.encode("utf-8")).hexdigest()
    receipt["local_docker_transport"] = "unix_socket_or_named_pipe"
    try:
        control = Session("coordinator", run_id, deadline, docker_endpoint)
        sessions.append(control)
        control.query(GUARD)
        receipt["startup_guard"] = "passed"
        fixture = seed(control, fixture_sql)
        receipt["fixture"] = {key: fixture[key] for key in ("targets", "audit_ids", "getters_restored")}
        # Arm exact-ID cleanup before COMMIT, including an ambiguous response.
        fixture_exposed = True
        receipt["seed_commit"] = "attempted"
        save()
        control.query("commit;")
        receipt["seed_commit"] = "confirmed"
        save()
        request_ids = [target["request_id"] for target in fixture["targets"]]
        prefix = request_ids[:LOCKED_PREFIX]
        baseline = state(control, request_ids)
        blocker = Session("blocker", run_id, deadline, docker_endpoint)
        sessions.append(blocker)

        blocker.query("begin; select pg_advisory_xact_lock(hashtext('util.process_dataset_derivative_rebuilds'));")
        try:
            control.query("begin;")
            visits = int(control.scalar("select util.process_dataset_derivative_rebuilds(25);"))
            unchanged = state(control, request_ids) == baseline
            if visits != 0 or not unchanged:
                raise HarnessError("Advisory-lock contention did not return zero without effects.")
            receipt["checks"].append({"name": "advisory_lock", "status": "passed", "visits": visits,
                                      "request_audit_queue_unchanged": unchanged})
        finally:
            control.query("rollback;", cleanup=True)
            blocker.query("rollback;", cleanup=True)
        save()

        blocker.query(f"begin; select id from util.dataset_derivative_rebuild_requests "
                      f"where id=any({uuid_array(prefix)}) order by updated_at, admitted_at, id for update;")
        control.query("begin;")
        visits = int(control.scalar("select util.process_dataset_derivative_rebuilds(25);"))
        progress = control.json(f"""
select jsonb_build_object('progress_ids', coalesce(jsonb_agg(id order by id)
  filter(where status='dispatching' and phase='quarantining' and scheduler_selected_at is not null), '[]'::jsonb),
  'external_requests', count(*) filter(where markdown_request_id is not null))
from util.dataset_derivative_rebuild_requests where id=any({uuid_array(request_ids)});
""")
        if visits != VISIT_LIMIT or request_ids[LOCKED_PREFIX] not in progress["progress_ids"]:
            raise HarnessError("Locked same-batch prefix starved the sixth due request or the visit count drifted.")
        if progress["external_requests"] != 0:
            raise HarnessError("Queued-only lock test unexpectedly dispatched external work.")
        receipt["checks"].append({"name": "locked_prefix", "status": "passed", "visits": visits,
                                  "sixth_request_progressed": True, "progress_count": len(progress["progress_ids"]),
                                  "external_requests": 0})

        probe = Session("probe", run_id, deadline, docker_endpoint)
        sessions.append(probe)
        blocked = probe_locks(probe, request_ids)
        blocked_set = set(blocked)
        coordinator_locks = blocked_set - set(prefix)
        if (not set(prefix).issubset(blocked_set) or len(coordinator_locks) != visits
                or len(coordinator_locks) > VISIT_LIMIT
                or request_ids[LOCKED_PREFIX] not in coordinator_locks
                or not set(progress["progress_ids"]).issubset(coordinator_locks)):
            raise HarnessError("NOWAIT probes did not prove the exact bounded coordinator row-lock set.")
        receipt["checks"].append({"name": "actual_row_lock_budget", "status": "passed",
                                  "blocker_locks": len(prefix), "coordinator_locks": len(coordinator_locks),
                                  "free_rows": TOTAL - len(blocked_set), "probed_rows": TOTAL,
                                  "coordinator_request_ids": sorted(coordinator_locks)})
        control.query("rollback;", cleanup=True)
        blocker.query("rollback;", cleanup=True)
        if state(control, request_ids) != baseline:
            raise HarnessError("Rolled-back concurrency tests left durable request/audit/queue changes.")
        verify_primary(control, fixture)
        receipt["checks"].append({"name": "rollback_and_primary_invariance", "status": "passed",
                                  "primary_rows_and_sentinels_unchanged": True})
        save()
    finally:
        cleanup_error = None
        # Settle only our other two sessions before exact-ID fixture cleanup.
        for session in reversed(sessions):
            if session is control:
                continue
            try:
                session.close()
            except (OSError, subprocess.SubprocessError):
                # The exact pid/application pair is settled below, never a
                # blanket session termination or container restart.
                pass
        if control is not None:
            try:
                control.query("rollback;", cleanup=True)
            except (HarnessError, OSError):
                try:
                    control.close()
                except (OSError, subprocess.SubprocessError):
                    pass
                control = None
        if fixture_exposed and fixture is not None:
            try:
                if control is None:
                    control = Session("cleanup", run_id, time.monotonic() + 45, docker_endpoint)
                    sessions.append(control)
                owned = [(session.pid, session.application) for session in sessions
                         if session is not control and session.pid is not None]
                if owned:
                    predicates = " or ".join(f"(pid={pid} and application_name={literal(name)})" for pid, name in owned)
                    control.query("select pg_terminate_backend(pid) from pg_stat_activity "
                                  f"where datname='postgres' and usename='postgres' and ({predicates});", cleanup=True)
                receipt["cleanup"] = cleanup_fixture(control, fixture)
            except (HarnessError, OSError, ValueError) as exc:
                receipt["cleanup"] = {"status": "failed", "error_type": type(exc).__name__,
                                      "message": "Exact-ID cleanup could not be verified; retain the fixture receipt for recovery."}
                cleanup_error = exc
        if control is not None:
            try:
                control.close()
            except (OSError, subprocess.SubprocessError) as exc:
                cleanup_error = cleanup_error or exc
        receipt["session_diagnostics"] = [{"label": session.label, "psql_exit_code": session.process.returncode,
                                           "sqlstates": session.sqlstates,
                                           "stderr_bytes_withheld": session.stderr_bytes} for session in sessions]
        save()
        if cleanup_error is not None:
            raise HarnessError("Local synthetic fixture/session cleanup requires attention.") from cleanup_error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--receipt", type=Path, required=True, help="NEW private local JSON receipt file.")
    parser.add_argument("--timeout-seconds", type=int, default=180, help="Work bound, 30..300 seconds; cleanup has separate bounded waits.")
    args = parser.parse_args()
    if not 30 <= args.timeout_seconds <= 300:
        parser.error("--timeout-seconds must be 30..300")
    descriptor = os.open(args.receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    receipt: dict[str, Any] = {"schema": "database.scheduler703-concurrency.v1", "status": "running",
        "started_at": datetime.now(timezone.utc).isoformat(), "container": CONTAINER,
        "synthetic_only": True, "checks": [], "cleanup": {"status": "not_needed"}}
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        def save() -> None:
            handle.seek(0)
            json.dump(receipt, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
        save()
        try:
            run(receipt, save, args.timeout_seconds)
            receipt["status"] = "passed"
            code = 0
        except BaseException as exc:
            receipt["status"] = "failed"
            receipt["failure"] = {"type": type(exc).__name__,
                "message": str(exc) if isinstance(exc, HarnessError) else "Harness failed; raw diagnostics withheld."}
            code = 130 if isinstance(exc, KeyboardInterrupt) else 1
        receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
        save()
    print(json.dumps({"status": receipt["status"], "receipt": str(args.receipt.absolute()),
                      "checks": len(receipt["checks"]), "cleanup": receipt["cleanup"]["status"]}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
