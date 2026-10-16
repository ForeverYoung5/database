---
title: Dependency maintenance
docType: guide
scope: repo
status: active
authoritative: false
owner: database-engine
language: en
whenToUse:
  - when reviewing the Actions-only Dependabot configuration or its activation evidence
whenToUpdate:
  - when monitored ecosystems, cadence, PR limits, target branch or activation boundaries change
checkPaths:
  - .github/dependabot.yml
  - docs/agents/dependency-maintenance.md
lastReviewedAt: 2026-10-16
lastReviewedCommit: a84fcd60be87bec5bea3f54ff2d494a09a51e1a4
lastReviewedNote: "Reviewed the new maintenance guide against the Database #845 candidate and its current base; this is offline source review, not a claim of Main activation or hosted qualification."
related:
  - ../../AGENTS.md
  - ../../.docpact/config.yaml
  - repo-validation.md
  - supabase-branching.md
---

# Dependency maintenance

## Monitoring boundary

`.github/dependabot.yml` monitors GitHub Actions only, targets daily trunk `dev`,
and owns the weekly Shanghai schedule, seven-day cooldown, one-open-PR limit,
and related minor/patch grouping. Major updates stay separately reviewable.
There is no auto-merge. The exact Supabase CLI version remains a manually
qualified workflow input; this monitor does not upgrade CLI, SQL, seed data,
generated schemas, Auth templates or hosted configuration.

Use the existing PR workflow's local-contract and ARM64 jobs. An Actions-only
PR has no deployable input diff, so Preview classification ends before authority;
after its Dev merge the push classifier also skips persistent-Dev mutation.
A deployable diff is never exempted because the author is a dependency bot:
missing Preview authority remains a failure. Do not supply deployment credentials
to Dependabot merely to satisfy a same-repository condition.

The repository default branch is `main`. Landing this configuration on `dev`
is source delivery; activation requires a separately reviewed `dev -> main`
promotion and a successful hosted Actions scan. Until then, monitoring is not
claimed active. GitHub's `target-branch` controls version PRs; security alerts
and security-update settings are independent and must not be inferred from this
configuration. See the [official option reference](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference).

Routine monitoring-config edits review this guide through the focused Docpact
rule. Workflow, script, config and migration edits retain their existing proof
and documentation rules. No ordinary PR receives a new validation job.

