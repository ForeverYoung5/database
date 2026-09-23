#!/usr/bin/env python3
"""Plan, activate, or reconcile the reviewed Database #703 cron change once.

Uses the authenticated Supabase CLI; never reads application credentials.
The SQL template owns the atomic database checks. This transport owns exact
project/source approval, durable local attempt exclusion, and bounded reads.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone


TEMPLATE = Path(__file__).with_name("derivative_scheduler703_activate.sql")
PLACEHOLDER = "__SCHEDULER703_PLAN_BASE64__"
MIGRATION = "20260923053141"
SCHEMA = "database.derivative-scheduler703-operation.v1"
TRANSPORT_SCHEMA = "database.derivative-scheduler703-transport.v1"
OLD_COMMAND = "select util.process_dataset_derivative_rebuilds();"
NEW_COMMAND = "select util.process_dataset_derivative_rebuilds(25);"
SNAPSHOT_SQL = """begin isolation level repeatable read read only;
set local statement_timeout = '10s';
select jsonb_build_object(
  'transaction_isolation', current_setting('transaction_isolation'),
  'transaction_read_only', current_setting('transaction_read_only'),
  'expected_project_url_sha256', encode(extensions.digest(util.project_url(),'sha256'),'hex'),
  'expected_migration_version', (select max(version) from supabase_migrations.schema_migrations),
  'expected_coordinator_sha256', encode(extensions.digest(pg_get_functiondef(
    'util.process_dataset_derivative_rebuilds(integer)'::regprocedure),'sha256'),'hex'),
  'expected_selector_sha256', encode(extensions.digest(pg_get_functiondef(
    'private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamptz)'::regprocedure),'sha256'),'hex'),
  'coordinator_arguments', pg_get_function_arguments(
    'util.process_dataset_derivative_rebuilds(integer)'::regprocedure),
  'scheduler_column', exists(select 1 from pg_attribute where
    attrelid='util.dataset_derivative_rebuild_requests'::regclass
    and attname='scheduler_selected_at' and not attisdropped and not attnotnull
    and atttypid='timestamp with time zone'::regtype),
  'jobs', (select coalesce(jsonb_agg(to_jsonb(job)), '[]'::jsonb)
    from cron.job job where jobname='process-dataset-derivative-rebuilds')
) as evidence;
commit;
"""


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_new(path: Path, value: bytes) -> None:
    """Persist before any dependent operation; never overwrite evidence."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def write_json(path: Path, value: object) -> None:
    write_new(path, json.dumps(value, indent=2, sort_keys=True).encode() + b"\n")


def query(cli: str, project: str, sql: str, directory: Path, prefix: str) -> object:
    sql_path = directory / f"{prefix}.sql"
    write_new(sql_path, sql.encode())
    try:
        result = subprocess.run(
            [cli, "db", "query", "--linked", "--project-ref", project,
             "--file", str(sql_path), "--output", "json"],
            capture_output=True, timeout=75, check=False,
        )
    except subprocess.TimeoutExpired as error:
        write_json(directory / f"{prefix}-transport.json", {
            "status": "unknown", "reason": "transport_timeout", "at": timestamp(),
        })
        raise ValueError("Transport timed out; reconcile read-only. Do not replay apply.") from error
    write_new(directory / f"{prefix}-response.json", result.stdout)
    write_json(directory / f"{prefix}-transport.json", {
        "returncode": result.returncode, "stderr_sha256": digest(result.stderr), "at": timestamp(),
    })
    if result.returncode:
        raise ValueError("Query did not confirm success; inspect private evidence and reconcile read-only.")
    return json.loads(result.stdout)


def snapshot(cli: str, project: str, directory: Path, prefix: str) -> dict:
    response = query(cli, project, SNAPSHOT_SQL, directory, prefix)
    rows = response.get("rows", []) if isinstance(response, dict) else []
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict) or not isinstance(rows[0].get("evidence"), dict):
        raise ValueError("Snapshot returned an unexpected shape.")
    state = rows[0]["evidence"]
    if state.get("transaction_isolation") != "repeatable read" or state.get("transaction_read_only") != "on":
        raise ValueError("Transport did not preserve the explicit read-only REPEATABLE READ probe.")
    return state


def validate_source(state: dict, plan: dict) -> None:
    for key in ("expected_project_url_sha256", "expected_migration_version",
                "expected_coordinator_sha256", "expected_selector_sha256"):
        if state.get(key) != plan[key]:
            raise ValueError(f"Source binding changed: {key}.")
    if state.get("coordinator_arguments") != "p_limit integer DEFAULT 5" or state.get("scheduler_column") is not True:
        raise ValueError("Coordinator signature or nullable scheduler column changed.")
    if not isinstance(state.get("jobs"), list) or len(state["jobs"]) != 1:
        raise ValueError("Scheduler job is missing or ambiguous.")


def validate_plan(plan: dict) -> None:
    expected_keys = {"schema_version", "operation", "expected_job", "expected_migration_version",
                     "expected_coordinator_sha256", "expected_selector_sha256", "expected_project_url_sha256"}
    if not isinstance(plan, dict) or set(plan) != expected_keys or plan["schema_version"] != SCHEMA:
        raise ValueError("Invalid operation plan schema.")
    if plan["operation"] not in ("enable25", "rollback5"):
        raise ValueError("Unknown scheduler operation.")
    for key in ("expected_coordinator_sha256", "expected_selector_sha256", "expected_project_url_sha256"):
        if not isinstance(plan[key], str) or not re.fullmatch(r"[a-f0-9]{64}", plan[key]):
            raise ValueError(f"Invalid {key}.")
    if not isinstance(plan["expected_migration_version"], str) or not re.fullmatch(r"[0-9]{14}", plan["expected_migration_version"]):
        raise ValueError("Invalid migration head.")
    job = plan["expected_job"]
    if not isinstance(job, dict) or job.get("jobname") != "process-dataset-derivative-rebuilds" or job.get("schedule") != "* * * * *":
        raise ValueError("Unexpected scheduler job or cadence.")
    allowed = (OLD_COMMAND, "select util.process_dataset_derivative_rebuilds(5);") if plan["operation"] == "enable25" else (NEW_COMMAND,)
    if job.get("command") not in allowed:
        raise ValueError("Scheduler command is not the reviewed source for this operation.")


def desired_job(plan: dict) -> dict:
    return {**plan["expected_job"], "command": NEW_COMMAND if plan["operation"] == "enable25" else OLD_COMMAND}


def render(plan: dict, template_bytes: bytes) -> str:
    validate_plan(plan)
    template = template_bytes.decode("utf-8")
    if template.count(PLACEHOLDER) != 1:
        raise ValueError("Activation template has an unexpected placeholder count.")
    return template.replace(PLACEHOLDER, base64.b64encode(canonical(plan)).decode("ascii"))


def load_plan(path: Path, project: str) -> tuple[dict, bytes]:
    canonical_path = path.resolve(strict=True)
    envelope = json.loads(canonical_path.read_text())
    if set(envelope) != {"schema_version", "created_at", "project_ref", "template_sha256", "evidence_directory", "plan"} or envelope["schema_version"] != TRANSPORT_SCHEMA:
        raise ValueError("Invalid transport plan.")
    if envelope["evidence_directory"] != str(canonical_path.parent):
        raise ValueError("Plan was moved from its bound evidence directory; do not bypass attempt history.")
    template_bytes = TEMPLATE.read_bytes()
    if envelope["project_ref"] != project or envelope["template_sha256"] != digest(template_bytes):
        raise ValueError("Project or reviewed activation template changed.")
    validate_plan(envelope["plan"])
    if envelope["plan"]["expected_project_url_sha256"] != digest(f"https://{project}.supabase.co".encode()):
        raise ValueError("Project URL binding differs from the explicit target.")
    return envelope, template_bytes


def make_plan(args: argparse.Namespace) -> dict:
    args.out_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
    state = snapshot(args.supabase_cli, args.project_ref, args.out_dir, "before")
    plan = {
        "schema_version": SCHEMA, "operation": args.operation,
        "expected_project_url_sha256": digest(f"https://{args.project_ref}.supabase.co".encode()),
        "expected_migration_version": args.expected_migration_version,
        "expected_coordinator_sha256": args.expected_coordinator_sha256,
        "expected_selector_sha256": args.expected_selector_sha256,
        "expected_job": state["jobs"][0] if state.get("jobs") else {},
    }
    validate_source(state, plan)
    validate_plan(plan)
    template_bytes = TEMPLATE.read_bytes()
    envelope = {"schema_version": TRANSPORT_SCHEMA, "created_at": timestamp(),
                "project_ref": args.project_ref, "template_sha256": digest(template_bytes),
                "evidence_directory": str(args.out_dir.resolve()), "plan": plan}
    write_json(args.out_dir / "plan.json", envelope)
    write_new(args.out_dir / "review.sql", render(plan, template_bytes).encode())
    return {"status": "planned", "project_ref": args.project_ref, "operation": args.operation,
            "plan": str(args.out_dir / "plan.json"), "approve_sha256": digest(canonical(envelope))}


def apply_plan(args: argparse.Namespace) -> dict:
    envelope, template_bytes = load_plan(args.plan, args.project_ref)
    plan_hash = digest(canonical(envelope))
    if args.approve_sha256 != plan_hash:
        raise ValueError("Approval digest does not match the complete plan.")
    directory = Path(envelope["evidence_directory"])
    # Claim before sending even a read: two callers cannot share one attempt.
    write_json(directory / "attempt.json", {"plan_sha256": plan_hash, "at": timestamp(),
               "operation": envelope["plan"]["operation"], "project_ref": args.project_ref})
    before = snapshot(args.supabase_cli, args.project_ref, directory, "preapply")
    validate_source(before, envelope["plan"])
    if before["jobs"][0] != envelope["plan"]["expected_job"]:
        raise ValueError("Exact before job changed; no mutation sent.")
    # Exactly one invocation; SQL performs the authoritative atomic recheck.
    query(args.supabase_cli, args.project_ref, render(envelope["plan"], template_bytes), directory, "apply")
    after = snapshot(args.supabase_cli, args.project_ref, directory, "after")
    validate_source(after, envelope["plan"])
    if after["jobs"][0] != desired_job(envelope["plan"]):
        raise ValueError("Activation returned but exact after-state did not match; reconcile read-only.")
    result = {"status": "applied_and_verified", "project_ref": args.project_ref,
              "operation": envelope["plan"]["operation"], "plan_sha256": plan_hash}
    write_json(directory / "result.json", result)
    return result


def verify_plan(args: argparse.Namespace) -> dict:
    envelope, _template_bytes = load_plan(args.plan, args.project_ref)
    args.out_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
    after = snapshot(args.supabase_cli, args.project_ref, args.out_dir, "readback")
    validate_source(after, envelope["plan"])
    job = after["jobs"][0]
    state = "desired" if job == desired_job(envelope["plan"]) else "before" if job == envelope["plan"]["expected_job"] else "changed"
    result = {"status": state, "read_only": True, "project_ref": args.project_ref,
              "plan_sha256": digest(canonical(envelope)),
              "note": "Current state only; this read does not prove who committed an uncertain attempt."}
    write_json(args.out_dir / "result.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "apply", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--project-ref", required=True)
        command.add_argument("--supabase-cli", default="supabase")
        if name in ("plan", "verify"):
            command.add_argument("--out-dir", type=Path, required=True, help="New private evidence directory; parent must exist")
        if name != "plan":
            command.add_argument("--plan", type=Path, required=True)
        if name == "apply":
            command.add_argument("--approve-sha256", required=True)
        if name == "plan":
            command.add_argument("--operation", choices=("enable25", "rollback5"), required=True)
            command.add_argument("--expected-coordinator-sha256", required=True, help="Independently qualified migration-build digest")
            command.add_argument("--expected-selector-sha256", required=True, help="Independently qualified migration-build digest")
            command.add_argument("--expected-migration-version", default=MIGRATION)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[a-z0-9]{20}", args.project_ref):
            raise ValueError("Project ref must be an explicit 20-character Supabase reference.")
        result = {"plan": make_plan, "apply": apply_plan, "verify": verify_plan}[args.command](args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(json.dumps({"status": "refused_or_unconfirmed", "reason": str(error), "automatic_retry": False}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
