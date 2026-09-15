#!/usr/bin/env python3
"""Read one dotted path out of a JSON document given as the first argument.

Companion helper for the Result publication concurrency harness. It exists as a file rather
than an inline `python3 -c` so the harness contains no fragile nested quoting, and so the
readback assertions can address nested receipt fields directly.

Usage: json_path_value.py '<json text>' data.receipt.receiptId
"""

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: json_path_value.py <json> <dotted.path>", file=sys.stderr)
        return 2
    try:
        value = json.loads(argv[1])
    except json.JSONDecodeError as error:
        print(f"invalid json: {error}", file=sys.stderr)
        return 2
    for part in argv[2].split("."):
        if not isinstance(value, dict) or part not in value:
            # Absent path: print nothing and exit non-zero, so a harness comparison fails loudly
            # instead of silently matching two empty strings.
            print("", end="")
            return 1
        value = value[part]

    if value is None:
        # A PRESENT but NULL field is not a usable value. Printing the literal string "null"
        # with a success status would let a "must be present" check pass on a null, so this
        # exits non-zero and prints nothing. `false` and `0` are real typed values and DO
        # succeed, which is the distinction callers rely on.
        print("", end="")
        return 1
    if value is True or value is False:
        print("true" if value else "false")
    else:
        print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
