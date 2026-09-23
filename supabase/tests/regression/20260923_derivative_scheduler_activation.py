#!/usr/bin/env python3
"""Exact local-stack tests for the submitted RR activation/rollback SQL template."""
from __future__ import annotations
import argparse
import base64
import copy
import importlib.util
import json
from pathlib import Path
import queue
import secrets
import threading
import time

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("scheduler703_sessions",
    Path(__file__).with_name("20260923_derivative_scheduler_concurrency.py"))
sessions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sessions)
TEMPLATE = ROOT / "scripts/derivative_scheduler703_activate.sql"

PLAN_SQL = """
select jsonb_build_object(
 'schema_version','database.derivative-scheduler703-operation.v1',
 'operation','enable25',
 'expected_job',(select to_jsonb(j) from cron.job j where jobname='process-dataset-derivative-rebuilds'),
 'expected_coordinator_sha256',encode(extensions.digest(pg_get_functiondef('util.process_dataset_derivative_rebuilds(integer)'::regprocedure),'sha256'),'hex'),
 'expected_selector_sha256',encode(extensions.digest(pg_get_functiondef('private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamptz)'::regprocedure),'sha256'),'hex'),
 'expected_migration_version',(select max(version) from supabase_migrations.schema_migrations),
 'expected_project_url_sha256',encode(extensions.digest(util.project_url(),'sha256'),'hex'));
"""


def render(template, plan):
    marker = "__SCHEDULER703_PLAN_BASE64__"
    if template.count(marker) != 1:
        raise RuntimeError("Reviewed template placeholder changed")
    encoded = base64.b64encode(json.dumps(plan, sort_keys=True).encode()).decode()
    return template.replace(marker, encoded)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    if args.receipt.exists():
        raise RuntimeError("Receipt must be a new file")
    template = TEMPLATE.read_text()
    endpoint = sessions.local_docker_endpoint()
    run_id = secrets.token_hex(8)
    control = sessions.Session("activation-control", run_id, time.monotonic()+180, endpoint)
    original = None
    checks = []
    restored = False

    def job():
        return control.json("select to_jsonb(j) from cron.job j where jobname='process-dataset-derivative-rebuilds';")

    def restore(record):
        control.query("select cron.alter_job("+str(record["jobid"])+
            ",schedule:="+sessions.literal(record["schedule"])+
            ",command:="+sessions.literal(record["command"])+
            ",active:="+str(record["active"]).lower()+");")
        if job() != record:
            raise RuntimeError("Exact local cron state failed to restore")

    def invoke(sql, name, expected_error=None):
        actor = sessions.Session(name, run_id, time.monotonic()+30, endpoint)
        refused = False
        try:
            actor.query(sql)
        except sessions.HarnessError:
            refused = expected_error in actor.sqlstates if expected_error else False
            if not refused:
                raise
        finally:
            actor.close()
        if expected_error and not refused:
            raise RuntimeError("Expected server refusal was not observed")

    try:
        control.query(sessions.GUARD)
        original = job()
        before = dict(original, command="select util.process_dataset_derivative_rebuilds();")
        restore(before)
        plan = control.json(PLAN_SQL)
        invoke(render(template, plan), "enable")
        enabled = dict(before, command="select util.process_dataset_derivative_rebuilds(25);")
        assert job() == enabled
        checks.append({"case":"enable25", "passed":True, "whole_job_changed_only_command":True})
        invoke(render(template, plan), "replay", "P0001")
        assert job() == enabled
        checks.append({"case":"stale_plan_replay", "passed":True, "sqlstate":"P0001"})
        rollback = control.json(PLAN_SQL)
        rollback["operation"] = "rollback5"
        invoke(render(template, rollback), "rollback")
        assert job() == before
        checks.append({"case":"rollback5", "passed":True, "whole_job_changed_only_command":True})

        for field, value in (("expected_coordinator_sha256", "0"*64),
                             ("expected_selector_sha256", "0"*64),
                             ("expected_project_url_sha256", "0"*64),
                             ("expected_migration_version", "19990101000000"),
                             ("operation", None)):
            bad = copy.deepcopy(plan)
            bad[field] = value
            invoke(render(template, bad), "binding", "P0001")
            assert job() == before
            checks.append({"case":"refuse_"+field, "passed":True, "sqlstate":"P0001"})
        stale_owner = copy.deepcopy(plan)
        stale_owner["expected_job"]["username"] = "another-reviewed-owner"
        invoke(render(template, stale_owner), "owner", "P0001")
        assert job() == before
        checks.append({"case":"stale_owner_before", "passed":True, "sqlstate":"P0001"})
        weaker = template.replace("begin isolation level repeatable read;", "begin;")
        assert weaker != template
        invoke(render(weaker, plan), "isolation", "P0001")
        assert job() == before
        checks.append({"case":"transport_lost_repeatable_read", "passed":True, "sqlstate":"P0001"})
        unknown = dict(before, command="select 1;")
        restore(unknown)
        unknown_plan = control.json(PLAN_SQL)
        invoke(render(template, unknown_plan), "unknown-command", "P0001")
        assert job() == unknown
        restore(before)
        checks.append({"case":"unknown_source_command", "passed":True, "sqlstate":"P0001"})

        blocker = sessions.Session("activation-lock-holder", run_id, time.monotonic()+30, endpoint)
        try:
            blocker.query("begin; select cron.alter_job("+str(before["jobid"])+
                          ",command:="+sessions.literal(before["command"])+");")
            started = time.monotonic()
            invoke(render(template, plan), "lock-timeout", "55P03")
            elapsed = time.monotonic()-started
            if not 4.5 <= elapsed <= 10:
                raise RuntimeError("Cron lock refusal did not honor the configured five-second bound")
            checks.append({"case":"bounded_cron_lock_wait", "passed":True,"sqlstate":"55P03",
                           "elapsed_seconds":round(elapsed,3),"automatic_retries":0})
        finally:
            blocker.close()
        assert job() == before

        for field, replacement in (("command", "select 1;"), ("schedule", "*/2 * * * *")):
            barrier = "scheduler703-cas-"+secrets.token_hex(8)
            literal = sessions.literal(barrier)
            control.query("select pg_advisory_lock(hashtext("+literal+"));")
            actor = sessions.Session("concurrent-"+field, run_id, time.monotonic()+30, endpoint)
            outcomes = queue.Queue()
            anchor = "  perform cron.alter_job((v_before->>'jobid')::bigint, command := v_desired);"
            assert template.count(anchor) == 1
            instrumented = template.replace(anchor,
                "  perform pg_advisory_lock(hashtext("+literal+"));\n"
                "  perform pg_advisory_unlock(hashtext("+literal+"));\n"+anchor)

            def execute():
                try:
                    actor.query(render(instrumented, plan))
                    outcomes.put("unexpected_success")
                except sessions.HarnessError:
                    outcomes.put("serialization_refused" if "40001" in actor.sqlstates else "wrong_error")

            worker = threading.Thread(target=execute, daemon=True)
            worker.start()
            try:
                deadline = time.monotonic()+5
                while time.monotonic()<deadline:
                    blocked = control.scalar("select count(*) from pg_stat_activity where pid="+str(actor.pid)+
                        " and application_name="+sessions.literal(actor.application)+" and wait_event='advisory';")
                    if blocked == "1":
                        break
                    time.sleep(0.02)
                else:
                    raise RuntimeError("Concurrent writer barrier was not reached")
                control.query("select cron.alter_job("+str(before["jobid"])+","+field+":="+
                              sessions.literal(replacement)+");")
                changed = dict(before, **{field:replacement})
                control.query("select pg_advisory_unlock(hashtext("+literal+"));")
                assert outcomes.get(timeout=5) == "serialization_refused"
                assert job() == changed  # the deployment did not overwrite the other administrator
                checks.append({"case":"concurrent_"+field,"passed":True,"sqlstate":"40001",
                               "other_admin_change_preserved":True,"automatic_retries":0})
            finally:
                control.query("select pg_advisory_unlock(hashtext("+literal+"));", cleanup=True)
                actor.close()
                worker.join(timeout=2)
                restore(before)
    finally:
        if original is not None:
            restore(original)
            restored = True
        control.close()
        receipt = {"container":sessions.CONTAINER,"checks":checks,
                   "exact_original_cron_restored":restored,"no_business_rows_or_workers":True,
                   "passed":len(checks)==14 and restored}
        with args.receipt.open("x",encoding="utf-8") as output:
            json.dump(receipt,output,indent=2)
            output.write("\n")
        print(json.dumps(receipt,sort_keys=True))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
