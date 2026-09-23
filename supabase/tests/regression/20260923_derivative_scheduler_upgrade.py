#!/usr/bin/env python3
"""Rollback-only populated schema upgrade: completed history and cron stay unchanged."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

CONTAINER = "supabase_db_database-engine-703-scheduler"
BASELINE_SHA256 = "ac2e23a21c92088c64dae64108a6f0ceff3523d05a1765bea6f4b17baff616c3"
ROOT = Path(__file__).resolve().parents[3]


def run(sql):
    return subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-X", "-qAt", "-U", "postgres",
         "-h", "/var/run/postgresql", "-d", "postgres", "-v", "ON_ERROR_STOP=1"], input=sql, text=True,
        capture_output=True, timeout=90,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ddl", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    if args.receipt.exists():
        raise RuntimeError("Receipt already exists")
    original = args.baseline_ddl.read_bytes()
    if hashlib.sha256(original).hexdigest() != BASELINE_SHA256:
        raise RuntimeError("Baseline is not the reviewed production function definition")
    baseline = original.decode().rstrip().rstrip(";") + ";"
    migration = (ROOT / "supabase/migrations/20260923053141_derivative_rebuild_ready_scheduler.sql").read_text()
    fixture = (ROOT / "supabase/tests/fixtures/derivative_scheduler703.sql").read_text()
    guard = run("select (not exists(select 1 from public.flows) and not exists(select 1 from public.processes) "
                "and not exists(select 1 from util.dataset_derivative_rebuild_requests) "
                "and not exists(select 1 from cron.job where active) "
                "and util.project_url()='http://127.0.0.1:9')::text;")
    if guard.returncode or guard.stdout.strip() != "true":
        raise RuntimeError("Exact local stack must be empty, cron-disabled and black-holed; no writes performed")
    records = []
    for case in ("paused", "active", "unknown-command"):
        active = "true" if case == "active" else "false"
        command = "select 1;" if case == "unknown-command" else "select util.process_dataset_derivative_rebuilds();"
        setup = """
begin;
drop function private.pick_dataset_derivative_rebuild_request(uuid[],text,boolean,timestamptz);
alter table util.dataset_derivative_rebuild_requests drop column scheduler_selected_at;
""" + baseline + "\n" + fixture + """
select pg_temp.scheduler703_seed(0,1,1,1);
do $complete$
begin
  for i in 1..4 loop
    perform util.process_dataset_derivative_rebuilds(5);
    perform pg_temp.scheduler703_ideal_worker();
  end loop;
  if (select count(*) from util.dataset_derivative_rebuild_requests where status='completed') <> 1 then
    raise exception 'Historical fixture did not complete through the actual original coordinator';
  end if;
end;
$complete$;
create temporary table historical_before as select id,to_jsonb(r) payload
from util.dataset_derivative_rebuild_requests r;
create temporary table heap_before as select pg_relation_filenode('util.dataset_derivative_rebuild_requests') node;
""" + "select cron.alter_job(jobid,command:='" + command + "',active:=" + active + ") from cron.job where jobname='process-dataset-derivative-rebuilds';\n" + """
create temporary table cron_before as select to_jsonb(j) metadata
from cron.job j where jobname='process-dataset-derivative-rebuilds';
"""
        candidate = migration
        validation = """
do $verify$
begin
  if exists(select 1 from util.dataset_derivative_rebuild_requests r join historical_before old using(id)
    where (to_jsonb(r)-'scheduler_selected_at') <> old.payload or r.scheduler_selected_at is not null) then
    raise exception 'Upgrade rewrote historical completed state or its public hash inputs';
  end if;
  if (select node from heap_before) <> pg_relation_filenode('util.dataset_derivative_rebuild_requests') then
    raise exception 'Nullable scheduling metadata caused a heap rewrite';
  end if;
  if (select metadata from cron_before) is distinct from
    (select to_jsonb(j) from cron.job j where jobname='process-dataset-derivative-rebuilds') then
    raise exception 'Schema migration must not change any cron field; activation is a separate RR operation';
  end if;
end;
$verify$;
rollback;
"""
        result = run(setup + "\n" + candidate + "\n" + validation)
        passed = result.returncode == 0
        records.append({"case": case, "passed": passed, "entire_cron_record_preserved": True,
                        "exit_code": result.returncode, "rolled_back": True})
        if not passed:
            print(result.stderr, file=sys.stderr)
            break
    clean = run("select (not exists(select 1 from public.flows) and not exists(select 1 from public.processes) "
                "and not exists(select 1 from util.dataset_derivative_rebuild_requests) "
                "and not exists(select 1 from cron.job where active))::text;")
    restored = clean.returncode == 0 and clean.stdout.strip() == "true"
    payload = {"container": CONTAINER, "boundary": "isolated synthetic upgrade; never hosted",
               "cases": records, "empty_and_cron_paused_after_rollback": restored,
               "passed": len(records) == 3 and all(x["passed"] for x in records) and restored}
    with args.receipt.open("x", encoding="utf-8") as output:
        json.dump(payload, output, indent=2)
        output.write("\n")
    print(json.dumps(payload, sort_keys=True))
    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
