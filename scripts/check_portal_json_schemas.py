#!/usr/bin/env python3
"""Strictly compile each public schema with its sibling $refs registered.

AJV CLI's -s glob compiles files in filename order; it does not preload sibling
schemas. Register all other files with -r, excluding the current root to avoid
duplicate $id registration. No schemas or validation options are rewritten.
"""
from pathlib import Path
import subprocess


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    schemas = sorted((root / "contracts/portal").glob("*.schema.json"))
    if not schemas:
        raise RuntimeError("Portal schemas are missing")
    for schema in schemas:
        command = [
            "npx", "--yes", "--package", "ajv-cli@5.0.0", "--package", "ajv-formats@3.0.1",
            "ajv", "compile", "--spec=draft2020", "--strict=true", "-c", "ajv-formats",
        ]
        for reference in schemas:
            if reference != schema:
                command.extend(["-r", str(reference.relative_to(root))])
        command.extend(["-s", str(schema.relative_to(root))])
        subprocess.run(command, cwd=root, check=True)
    print(f"Strict Draft 2020-12 compilation passed for {len(schemas)} Portal schemas.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
