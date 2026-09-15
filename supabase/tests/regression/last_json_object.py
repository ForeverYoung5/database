#!/usr/bin/env python3
"""Print the last line of a psql output file that parses as a complete JSON object.

Companion helper for the Result publication concurrency harness. psql emits notices and other
lines around a query result; the harness needs the actual response envelope. Keeping this in a
file avoids fragile inline quoting and, unlike a shell `grep | tail`, it fails loudly rather
than silently returning an unrelated line.

Usage: last_json_object.py <psql-output-file>
"""

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: last_json_object.py <file>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        print(f"cannot read {argv[1]}: {error}", file=sys.stderr)
        return 2
    for line in reversed(lines):
        candidate = line.strip()
        if not candidate.startswith("{"):
            continue
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            print(candidate)
            return 0
    # No envelope found. Print nothing and fail, so the caller's comparisons fail loudly
    # instead of matching two empty strings.
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
