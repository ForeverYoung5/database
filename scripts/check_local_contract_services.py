#!/usr/bin/env python3
"""Read-only container proof for the pinned local-contract CI service set."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tomllib

REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_ID = "database-engine"
# Supabase CLI 2.116.0 service catalog. Exclusion keys differ from container
# suffixes: mailpit -> inbucket and logflare -> analytics.
REQUIRED = ("db", "auth", "storage", "kong", "rest", "pg_meta", "realtime", "edge_runtime")
EXCLUDED = ("studio", "inbucket", "analytics", "vector")
REQUIRED_NAMES = tuple(f"supabase_{suffix}_{PROJECT_ID}" for suffix in REQUIRED)
EXCLUDED_NAMES = frozenset(f"supabase_{suffix}_{PROJECT_ID}" for suffix in EXCLUDED)


def verify_names(output: str) -> None:
    names = output.splitlines()
    if len(names) != len(set(names)):
        raise ValueError("Local container inventory contains duplicate names.")
    if EXCLUDED_NAMES.intersection(names):
        raise ValueError("An excluded auxiliary container is present.")
    if not set(REQUIRED_NAMES).issubset(names):
        raise ValueError("A required local database/core container is missing.")
    project_names = {
        name for name in names
        if name.startswith("supabase_") and name.endswith(f"_{PROJECT_ID}")
    }
    if project_names != set(REQUIRED_NAMES):
        raise ValueError("An unexpected local-contract project container is present.")


def verify_states(output: str) -> None:
    observed = set()
    for line in output.splitlines():
        parts = line.split("|")
        if len(parts) != 3:
            raise ValueError("Local container state evidence is malformed.")
        name, state, health = parts
        name = name.removeprefix("/")
        if name not in REQUIRED_NAMES or name in observed:
            raise ValueError("Local container state identity is incomplete or ambiguous.")
        observed.add(name)
        if state != "running" or health not in {"healthy", "none"}:
            raise ValueError("A required local database/core container is not ready.")
    if observed != set(REQUIRED_NAMES):
        raise ValueError("Local container state evidence is incomplete.")


def docker(*arguments: str) -> str:
    # Read only selected scalar fields, never container env, logs or credentials.
    return subprocess.run(
        ["docker", "container", *arguments],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    ).stdout


def main() -> int:
    try:
        with (REPO_ROOT / "supabase/config.toml").open("rb") as config:
            if tomllib.load(config).get("project_id") != PROJECT_ID:
                raise ValueError("Local-contract project identity requires review.")
        verify_names(docker("ls", "--all", "--format", "{{.Names}}"))
        verify_states(
            docker(
                "inspect",
                "--format",
                "{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}",
                *REQUIRED_NAMES,
            )
        )
    except (OSError, subprocess.SubprocessError, ValueError):
        # Docker can include arbitrary host details in failures. The job keeps
        # the original Supabase failure output; this additional proof stays fixed.
        print("FAIL: local-contract container inventory or readiness could not be verified.")
        return 1
    print("PASS: all 8 required local services are running; 4 auxiliary containers are absent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
