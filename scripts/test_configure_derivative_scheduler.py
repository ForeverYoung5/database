#!/usr/bin/env python3
"""Offline fault-injection tests for the one-attempt scheduler transport."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import configure_derivative_scheduler as runner


PROJECT = "abcdefghijklmnopqrst"


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.state = {
            "transaction_isolation": "repeatable read", "transaction_read_only": "on",
            "expected_project_url_sha256": runner.digest(f"https://{PROJECT}.supabase.co".encode()),
            "expected_migration_version": runner.MIGRATION,
            "expected_coordinator_sha256": "a" * 64, "expected_selector_sha256": "b" * 64,
            "coordinator_arguments": "p_limit integer DEFAULT 5", "scheduler_column": True,
            "jobs": [{"jobid": 11, "jobname": "process-dataset-derivative-rebuilds",
                      "schedule": "* * * * *", "command": runner.OLD_COMMAND,
                      "active": False, "nodename": "localhost", "nodeport": 5432,
                      "database": "postgres", "username": "postgres"}],
        }
        self.mutations = 0
        self.fault = None
        self.mock = patch.object(runner.subprocess, "run", side_effect=self.transport)
        self.mock.start()

    def tearDown(self):
        self.mock.stop()
        self.temporary.cleanup()

    def transport(self, command, **kwargs):
        self.assertEqual(command[command.index("--project-ref") + 1], PROJECT)
        sql_path = Path(command[command.index("--file") + 1])
        if sql_path.name == "apply.sql":
            self.assertTrue((sql_path.parent / "attempt.json").is_file())
            self.assertTrue((sql_path.parent / "plan.json").is_file())
            self.mutations += 1
            if self.fault == "serialization":
                return subprocess.CompletedProcess(command, 1, b"", b"SQLSTATE 40001")
            self.state["jobs"][0]["command"] = runner.NEW_COMMAND
            if self.fault == "lost_response":
                raise subprocess.TimeoutExpired(command, 75)
            return subprocess.CompletedProcess(command, 0, b'{"rows":[]}', b"")
        return subprocess.CompletedProcess(command, 0,
            json.dumps({"rows": [{"evidence": copy.deepcopy(self.state)}]}).encode(), b"")

    def plan(self):
        result = runner.make_plan(argparse.Namespace(
            supabase_cli="fake-supabase", project_ref=PROJECT, out_dir=self.directory / "plan",
            operation="enable25", expected_coordinator_sha256="a" * 64,
            expected_selector_sha256="b" * 64, expected_migration_version=runner.MIGRATION,
        ))
        return argparse.Namespace(supabase_cli="fake-supabase", project_ref=PROJECT,
            plan=Path(result["plan"]), approve_sha256=result["approve_sha256"])

    def test_success_preserves_paused_job_and_archives_receipt(self):
        args = self.plan()
        expected = {**self.state["jobs"][0], "command": runner.NEW_COMMAND}
        result = runner.apply_plan(args)
        self.assertEqual(result["status"], "applied_and_verified")
        self.assertEqual(self.state["jobs"][0], expected)
        self.assertEqual(self.mutations, 1)
        self.assertEqual((args.plan.parent / "attempt.json").stat().st_mode & 0o777, 0o600)
        self.assertTrue((args.plan.parent / "result.json").is_file())

    def test_replay_is_refused_without_second_dispatch(self):
        args = self.plan()
        runner.apply_plan(args)
        with self.assertRaises(FileExistsError):
            runner.apply_plan(args)
        self.assertEqual(self.mutations, 1)

    def test_copied_plan_cannot_bypass_attempt_history(self):
        args = self.plan()
        runner.apply_plan(args)
        copied = self.directory / "copied"
        copied.mkdir()
        destination = copied / "plan.json"
        destination.write_bytes(args.plan.read_bytes())
        args.plan = destination
        with self.assertRaisesRegex(ValueError, "bound evidence directory"):
            runner.apply_plan(args)
        self.assertEqual(self.mutations, 1)

    def test_plan_symlink_cannot_bypass_canonical_attempt_history(self):
        args = self.plan()
        runner.apply_plan(args)
        self.state["jobs"][0]["command"] = runner.OLD_COMMAND
        alias = self.directory / "alias"
        alias.mkdir()
        (alias / "plan.json").symlink_to(args.plan)
        args.plan = alias / "plan.json"
        with self.assertRaises(FileExistsError):
            runner.apply_plan(args)
        self.assertEqual(self.mutations, 1)
        self.assertFalse((alias / "attempt.json").exists())

    def test_dispatch_uses_approved_template_bytes_despite_midflight_edit(self):
        args = self.plan()
        approved = runner.TEMPLATE.read_bytes()
        alternate = self.directory / "editable-template.sql"
        alternate.write_bytes(approved)
        original_transport = self.transport

        def editing_transport(command, **kwargs):
            sql_path = Path(command[command.index("--file") + 1])
            if sql_path.name == "preapply.sql":
                alternate.write_bytes(approved + b"\nselect 'unapproved';\n")
            if sql_path.name == "apply.sql":
                self.assertNotIn("unapproved", sql_path.read_text())
            return original_transport(command, **kwargs)

        with patch.object(runner, "TEMPLATE", alternate):
            with patch.object(runner.subprocess, "run", side_effect=editing_transport):
                result = runner.apply_plan(args)
        self.assertEqual(result["status"], "applied_and_verified")
        self.assertEqual(self.mutations, 1)

    def test_commit_with_lost_response_reconciles_without_replay(self):
        args = self.plan()
        self.fault = "lost_response"
        with self.assertRaisesRegex(ValueError, "reconcile read-only"):
            runner.apply_plan(args)
        with self.assertRaises(FileExistsError):
            runner.apply_plan(args)
        args.out_dir = self.directory / "reconcile"
        result = runner.verify_plan(args)
        self.assertEqual(result["status"], "desired")
        self.assertIn("does not prove who committed", result["note"])
        self.assertEqual(self.mutations, 1)

    def test_serialization_failure_is_not_retried(self):
        args = self.plan()
        self.fault = "serialization"
        with self.assertRaisesRegex(ValueError, "did not confirm success"):
            runner.apply_plan(args)
        self.assertEqual(self.state["jobs"][0]["command"], runner.OLD_COMMAND)
        self.assertEqual(self.mutations, 1)
        with self.assertRaises(FileExistsError):
            runner.apply_plan(args)

    def test_stale_admin_configuration_is_not_overwritten(self):
        args = self.plan()
        self.state["jobs"][0]["active"] = True
        with self.assertRaisesRegex(ValueError, "Exact before job changed"):
            runner.apply_plan(args)
        self.assertEqual(self.mutations, 0)
        self.assertTrue(self.state["jobs"][0]["active"])

    def test_source_drift_stops_before_mutation(self):
        args = self.plan()
        self.state["expected_coordinator_sha256"] = "c" * 64
        with self.assertRaisesRegex(ValueError, "Source binding changed"):
            runner.apply_plan(args)
        self.assertEqual(self.mutations, 0)

    def test_project_substitution_and_plan_tamper_refused(self):
        args = self.plan()
        args.project_ref = "zyxwvutsrqponmlkjihg"
        with self.assertRaisesRegex(ValueError, "Project or reviewed"):
            runner.apply_plan(args)
        args.project_ref = PROJECT
        envelope = json.loads(args.plan.read_text())
        envelope["plan"]["expected_job"]["active"] = True
        args.plan.write_text(json.dumps(envelope))
        with self.assertRaisesRegex(ValueError, "Approval digest"):
            runner.apply_plan(args)
        self.assertEqual(self.mutations, 0)

    def test_changed_sql_template_refused(self):
        args = self.plan()
        other = self.directory / "changed.sql"
        other.write_text(runner.TEMPLATE.read_text() + "\n-- changed\n")
        with patch.object(runner, "TEMPLATE", other):
            with self.assertRaisesRegex(ValueError, "Project or reviewed"):
                runner.apply_plan(args)
        self.assertEqual(self.mutations, 0)

    def test_bad_isolation_probe_cannot_create_a_plan(self):
        self.state["transaction_isolation"] = "read committed"
        with self.assertRaisesRegex(ValueError, "Transport did not preserve"):
            self.plan()
        self.assertFalse((self.directory / "plan" / "plan.json").exists())
        self.assertEqual(self.mutations, 0)

    def test_unexpected_job_text_and_source_hash_refused(self):
        self.state["jobs"][0]["command"] = "select 1;"
        with self.assertRaisesRegex(ValueError, "reviewed source"):
            self.plan()
        self.assertEqual(self.mutations, 0)


if __name__ == "__main__":
    unittest.main()
