#!/usr/bin/env bash
# Database #846: populated canonical-base calculation export upgrade.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "${1:-}" == "--help" ]]; then
  echo "CI-only: requires the matching GitHub-hosted workspace, local Docker and CALCULATION_EXPORT_UPGRADE_ALLOW_RESET=isolated."
  exit 0
fi
if [[ "${CALCULATION_EXPORT_UPGRADE_ALLOW_RESET:-}" != "isolated" ]]; then
  echo "Refusing local reset without CALCULATION_EXPORT_UPGRADE_ALLOW_RESET=isolated." >&2
  exit 2
fi
if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" || "${GITHUB_WORKSPACE:-}" != "$repo_root" ]]; then
  echo "Refusing reset outside the matching GitHub-hosted ephemeral workspace." >&2
  exit 2
fi
if [[ -n "${DOCKER_HOST:-}" || -n "${DOCKER_CONTEXT:-}" ]]; then
  echo "Refusing overridden Docker target." >&2
  exit 2
fi
docker_endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
if [[ "$docker_endpoint" != unix://* ]]; then
  echo "Refusing non-local Docker context." >&2
  exit 2
fi

fixture="$(mktemp "$repo_root/supabase/tests/upgrade/calculation-export-upgrade-XXXXXX.sql")"
trap 'rm -f "$fixture"' EXIT
python3 scripts/render_calculation_export_upgrade.py "$fixture"
supabase db reset --local --version 20261014081710 --no-seed
supabase test db "$fixture"
supabase migration up --local
