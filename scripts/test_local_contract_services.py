#!/usr/bin/env python3
"""Pure fixtures for the CI-only local Supabase service boundary."""

from __future__ import annotations

import contextlib
import importlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/supabase-dev.yml"
REQUIRED = ("db", "auth", "storage", "kong", "rest", "pg_meta", "realtime", "edge_runtime")
EXCLUDED = ("studio", "inbucket", "analytics", "vector")


def names(suffixes=REQUIRED):
    return [f"supabase_{suffix}_database-engine" for suffix in suffixes]


def step_script(name):
    text = WORKFLOW.read_text()
    step = text.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]
    run = step.split("        run: ", 1)[1]
    if run.startswith("|\n"):
        return "\n".join(line[10:] for line in run.splitlines()[1:] if line.startswith("          "))
    return run.splitlines()[0]


class WorkflowTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "the local-contract runner is Linux/bash")
    def test_schema_type_drift_and_sql_failures_still_block_the_actual_steps(self):
        with tempfile.TemporaryDirectory(prefix="database-gate-failure-") as directory:
            trace = Path(directory) / "trace"
            # Shell functions replace every command used by these negative paths.
            # The SQL path stops at its first failed fixture, before upgrade.
            functions = '''
python() {
  printf 'python %s\n' "$1" >> "$TRACE"
  if [ "$1" = "$FAIL_SCRIPT" ]; then return 7; fi
}
python3() { python "$@"; }
git() {
  printf 'git %s\n' "$1" >> "$TRACE"
  if [ "$1" = diff ] && [ "$DRIFT" = tracked ]; then return 7; fi
  if [ "$1" = status ] && [ "$DRIFT" = untracked ]; then printf '?? unexpected-type.ts\n'; fi
}
supabase() { printf 'supabase %s\n' "$1" >> "$TRACE"; return 7; }
'''
            for fail_script, drift, expected_lines in (
                ("scripts/build_schema_workspace.py", "", 1),
                ("scripts/build_database_types.py", "", 2),
                ("", "tracked", 3),
                ("", "untracked", 4),
            ):
                with self.subTest(fail_script=fail_script, drift=drift):
                    trace.write_text("")
                    result = subprocess.run(
                        ["bash", "-e", "-c", functions + step_script("Verify generated schema and Data API types")],
                        cwd=ROOT,
                        env={**os.environ, "TRACE": str(trace), "FAIL_SCRIPT": fail_script, "DRIFT": drift},
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(len(trace.read_text().splitlines()), expected_lines)
            trace.write_text("")
            result = subprocess.run(
                ["bash", "-e", "-c", functions + step_script("Verify schema and capability contracts")],
                cwd=ROOT, env={**os.environ, "TRACE": str(trace)},
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(trace.read_text().splitlines(), ["supabase test"])

    @unittest.skipUnless(os.name == "posix", "the local-contract runner is Linux/bash")
    def test_actual_rebuild_script_keeps_gates_and_stops_on_failures(self):
        # Execute the real workflow command block, but every Docker/Supabase
        # process is a local stub; no daemon, database or network is contacted.
        stub = '''import json, os, sys
kind, args = sys.argv[1], sys.argv[2:]
with open(os.environ['TRACE'], 'a') as f: f.write(json.dumps([kind, *args]) + '\\n')
if kind == 'supabase':
    sys.exit(int(os.environ.get('START_EXIT' if args[0] == 'start' else 'RESET_EXIT', '0')))
if os.environ.get('DOCKER_EXIT'): sys.exit(7)
required = json.loads(os.environ['CONTAINERS'])
if args[:2] == ['container', 'ls']:
    print('\\n'.join(required)); sys.exit(0)
if args[:2] == ['container', 'inspect']:
    for name in required: print('/' + name + '|running|healthy')
    sys.exit(0)
sys.exit(9)
'''
        with tempfile.TemporaryDirectory(prefix="database-services-") as directory:
            folder = Path(directory)
            (folder / "stub.py").write_text(stub)
            for command in ("supabase", "docker"):
                script = folder / command
                script.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(folder / 'stub.py'))} {command} \"$@\"\n")
                script.chmod(0o755)
            python = folder / "python3"
            python.symlink_to(sys.executable)
            trace = folder / "trace.jsonl"
            env = {**os.environ, "PATH": f"{folder}:/usr/bin:/bin", "TRACE": str(trace), "CONTAINERS": json.dumps(names())}
            for overrides, expected_success, expected_reset in (
                ({}, True, True),
                ({"START_EXIT": "7"}, False, False),
                ({"DOCKER_EXIT": "7"}, False, False),
                ({"CONTAINERS": json.dumps(names() + names(("inbucket",)))}, False, False),
                ({"CONTAINERS": json.dumps(names()[1:])}, False, False),
                ({"RESET_EXIT": "7"}, False, True),
            ):
                with self.subTest(overrides=overrides):
                    trace.write_text("")
                    result = subprocess.run(["bash", "-e", "-c", step_script("Rebuild migration history")], cwd=ROOT, env={**env, **overrides}, capture_output=True, text=True, timeout=20)
                    calls = [json.loads(line) for line in trace.read_text().splitlines()]
                    self.assertEqual(result.returncode == 0, expected_success, result.stderr + result.stdout)
                    self.assertEqual(calls[0], ["supabase", "start", "--exclude", "studio,mailpit,logflare,vector"])
                    self.assertEqual(["supabase", "db", "reset", "--no-seed"] in calls, expected_reset)
                    if expected_success:
                        self.assertEqual(sum(call[:3] == ["docker", "container", "inspect"] for call in calls), 2)

    def test_existing_sql_upgrade_types_and_always_cleanup_remain(self):
        text = WORKFLOW.read_text().split("  deploy-and-verify:", 1)[0]
        self.assertEqual(len(re.findall(r"supabase test db (\S+[.]sql)", text)), 28)
        for command in (
            "python scripts/build_schema_workspace.py --environment local",
            "python scripts/build_database_types.py --environment local",
            "git diff --exit-code -- supabase/workspace",
            "git status --porcelain --untracked-files=all -- supabase/workspace",
            "scripts/test_full_schema_cutover_upgrade.sh\n          python3 scripts/check_local_contract_services.py",
            "python3 scripts/test_portal_composite_names_graph.py --local-container supabase_db_database-engine",
            "python3 scripts/build_portal_contract_types.py --check",
            "if: always()\n        run: supabase stop --no-backup",
            "python3 scripts/test_local_contract_services.py",
        ):
            self.assertIn(command, text)
        self.assertNotIn("ignore-health-check", text)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.checker = importlib.import_module("check_local_contract_services")

    def test_exact_inventory_accepts_unrelated_projects_but_rejects_every_auxiliary(self):
        self.checker.verify_names("\n".join(names() + ["supabase_studio_other-project"]))
        for suffix in EXCLUDED:
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                self.checker.verify_names("\n".join(names() + names((suffix,))))
        for missing in names():
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                self.checker.verify_names("\n".join(name for name in names() if name != missing))
        with self.assertRaises(ValueError):
            self.checker.verify_names("")
        for suffix in ("pooler", "unexpected"):
            with self.subTest(unexpected=suffix), self.assertRaises(ValueError):
                self.checker.verify_names("\n".join(names() + names((suffix,))))

    def test_required_containers_must_run_and_report_healthy_when_available(self):
        healthy = "\n".join(f"/{name}|running|healthy" for name in names())
        self.assertTrue(self.checker.verify_states(healthy))
        self.assertTrue(self.checker.verify_states(healthy.replace("|healthy", "|none")))
        for health in ("starting", "unhealthy"):
            self.assertFalse(self.checker.verify_states(healthy.replace("healthy", health, 1)))
        for state in ("exited|healthy", "restarting|healthy", "running|", "running|unknown"):
            with self.subTest(state=state), self.assertRaises(ValueError):
                self.checker.verify_states(healthy.replace("running|healthy", state, 1))
        for malformed in ("", healthy + "\n" + healthy.splitlines()[0], "\n".join(healthy.splitlines()[1:]), healthy.replace(names()[0], "foreign", 1)):
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                self.checker.verify_states(malformed)

    def test_daemon_errors_and_timeouts_fail_without_raw_output(self):
        for error in (FileNotFoundError("PRIVATE_SENTINEL"), subprocess.CalledProcessError(7, ["docker"], stderr="PRIVATE_SENTINEL"), subprocess.TimeoutExpired(["docker"], 30, stderr="PRIVATE_SENTINEL")):
            with self.subTest(error=type(error).__name__), patch.object(self.checker.subprocess, "run", side_effect=error), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(self.checker.main(), 1)
                self.assertNotIn("PRIVATE_SENTINEL", output.getvalue())

    def test_reads_only_formatted_inventory_and_required_state(self):
        replies = [subprocess.CompletedProcess([], 0, "\n".join(names())), subprocess.CompletedProcess([], 0, "\n".join(f"/{name}|running|healthy" for name in names()))]
        with patch.object(self.checker.subprocess, "run", side_effect=replies) as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.checker.main(), 0)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0][:3], ["docker", "container", "ls"])
        self.assertEqual(run.call_args_list[1].args[0][:3], ["docker", "container", "inspect"])
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["timeout"], 30)
            self.assertTrue(call.kwargs["check"])
            self.assertFalse(call.kwargs.get("shell", False))

    def test_different_project_config_blocks_before_docker(self):
        with tempfile.TemporaryDirectory(prefix="database-project-") as directory:
            config = Path(directory) / "supabase"
            config.mkdir()
            (config / "config.toml").write_text('project_id = "other-project"\n')
            with patch.object(self.checker, "REPO_ROOT", Path(directory)), patch.object(self.checker.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(self.checker.main(), 1)
                run.assert_not_called()


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.checker = importlib.import_module("check_local_contract_services")
        self.now = 0.0
        self.calls = []
        self.healthy = "\n".join(f"/{name}|running|healthy" for name in names())

    def run_with(self, respond):
        def run(argv, **options):
            self.calls.append((argv, options))
            return subprocess.CompletedProcess(argv, 0, respond(argv, options))

        def sleep(seconds):
            self.now += seconds

        with patch("time.monotonic", side_effect=lambda: self.now), patch("time.sleep", side_effect=sleep), patch.object(self.checker.subprocess, "run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            return self.checker.main()

    def test_starting_and_transient_unhealthy_wait_for_healthy(self):
        for transient in ("starting", "unhealthy"):
            with self.subTest(transient=transient):
                self.calls = []
                self.now = 0
                replies = iter([
                    "\n".join(names()),
                    self.healthy.replace("healthy", transient),
                    "\n".join(names()),
                    self.healthy,
                ])
                self.assertEqual(self.run_with(lambda *_: next(replies)), 0)
                self.assertEqual(len(self.calls), 4)
                self.assertEqual(self.now, 1)

    def test_permanent_pending_health_exhausts_one_total_deadline(self):
        for health in ("starting", "unhealthy"):
            with self.subTest(health=health):
                self.now = 0
                self.calls = []
                def respond(argv, _options):
                    if argv[2] == "ls":
                        return "\n".join(names())
                    return self.healthy.replace("healthy", health)
                self.assertEqual(self.run_with(respond), 1)
                self.assertEqual(self.now, 60)
                self.assertEqual(len(self.calls), 120)
                self.assertTrue(all(0 < call[1]["timeout"] <= 30 for call in self.calls))

    def test_each_docker_call_uses_remaining_budget_and_late_health_cannot_pass(self):
        responses = iter([
            (30, 25, "\n".join(names())),
            (30, 5, self.healthy.replace("healthy", "starting")),
            (29, 10, "\n".join(names())),
            (19, 19, self.healthy),
        ])
        def respond(argv, options):
            timeout, duration, response = next(responses)
            self.assertEqual(options["timeout"], timeout)
            self.now += duration
            return response
        self.assertEqual(self.run_with(respond), 1)
        self.assertEqual(len(self.calls), 4)

    def test_inventory_or_state_drift_during_wait_fails_immediately(self):
        for inventory, states in (
            (names()[1:], self.healthy),
            (names() + names(("studio",)), self.healthy),
            (names() + names(("unexpected",)), self.healthy),
            (names() + [names()[0]], self.healthy),
            (names(), self.healthy.replace("running", "exited", 1)),
            (names(), self.healthy.replace("running", "restarting", 1)),
            (names(), self.healthy.replace("healthy", "unknown", 1)),
            (names(), "malformed"),
        ):
            with self.subTest(inventory=inventory, states=states):
                self.now = 0
                self.calls = []
                replies = iter(["\n".join(names()), self.healthy.replace("healthy", "starting"), "\n".join(inventory), states])
                self.assertEqual(self.run_with(lambda *_: next(replies)), 1)
                self.assertEqual(self.now, 1)
                self.assertLessEqual(len(self.calls), 4)


if __name__ == "__main__":
    unittest.main()
