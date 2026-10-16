#!/usr/bin/env python3
"""Render a rollback-only populated upgrade fixture from the exact migration SQL."""
import hashlib
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = "f7c0b829dcf41b7b80b903f91fe13773ac2119df"
BASE_VERSION = "20261014081710"
paths = set(subprocess.check_output(["git", "ls-tree", "-r", "--name-only", BASE, "--", "supabase/migrations"], cwd=ROOT, text=True).splitlines())
prefix = {str(path.relative_to(ROOT)) for path in (ROOT / "supabase/migrations").glob("*.sql") if path.name.split("_", 1)[0] <= BASE_VERSION}
changed = subprocess.check_output(["git", "diff", "--name-only", BASE, "--", "supabase/migrations"], cwd=ROOT, text=True).splitlines()
if paths != prefix or any(path in paths for path in changed):
    raise SystemExit("Migration prefix does not reproduce the canonical base")
source = (ROOT / "supabase/tests/20261016_calculation_exports.sql").read_text()
marker = "grant execute on function pg_temp.semantic_downloads() to authenticated;"
if source.count(marker) != 1:
    raise SystemExit("Expected one upgrade insertion boundary")
relations = ["worker_jobs", "lca_results", "lcia_result_packages", "lca_network_snapshots"]
capture = "".join(f"create temp table before_{table} as select to_jsonb(t) as body from private.{table} t;\n" for table in relations)
checks = "".join(f"select is((select jsonb_agg(to_jsonb(t) order by id) from private.{table} t),(select jsonb_agg(body order by body->>'id') from before_{table}),'upgrade preserves populated {table}');\n" for table in relations)
sql = "\n".join((ROOT / "supabase/migrations" / name).read_text() for name in ["20261016023144_all_unit_terminal_guard.sql", "20261016023731_calculation_export_jobs.sql", "20261016035632_terminal_cache_replay_compatibility.sql"])
Path(sys.argv[1]).write_text(source.replace(marker, capture + sql + "\n" + checks + marker))
print(f"Canonical base {BASE}; migration SHA-256 {hashlib.sha256(sql.encode()).hexdigest()}; populated history checked before new admission")
