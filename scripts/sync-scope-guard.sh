#!/usr/bin/env bash
set -euo pipefail
# sync-scope-guard.sh — required CI check enforcing sync-PR scope (#1700 AC1).
#
# Fails a GENERATED sync PR whose diff touches any path outside the set it
# declared in its body (the #1523 failure: a PR claiming three workflow stubs
# also rewrote package.json/prompts/**/evals/**/scripts/**). Human PRs — those
# without the sync automation marker — always pass (AC#4). The scope decision is
# pure/deterministic and lives in scripts/lib/sync-scope-check.sh.
#
# Env vars consumed:
#   GH_TOKEN   — repo read on REPO (PR view + files list)
#   REPO       — target repo (default: petry-projects/.github-private)
#   PR_NUMBER  — the PR to check (required)
#   SYNC_SCOPE_LABEL — automation marker label (default: standards-sync)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/sync-scope-check.sh
source "${SCRIPT_DIR}/lib/sync-scope-check.sh"

REPO="${REPO:-petry-projects/.github-private}"
PR_NUMBER="${PR_NUMBER:-}"

if [ -z "$PR_NUMBER" ]; then
  echo "::error::sync-scope-guard: PR_NUMBER is not set."
  exit 2
fi

echo "=== Sync-PR Scope Guard — PR #${PR_NUMBER} in ${REPO} ==="

# Labels (newline-separated) + body in a single call.
labels=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json labels \
  --jq '.labels[].name' 2>/dev/null || true)
body=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body \
  --jq '.body' 2>/dev/null || true)

if ! is_generated_sync_pr "$labels" "$body"; then
  echo "Not a generated sync PR (no '${SYNC_SCOPE_LABEL}' label or declared-paths marker) — scope check does not apply."
  exit 0
fi

declared=$(sync_extract_declared_paths <<< "$body")
if [ -z "$declared" ]; then
  # Identified as a sync PR (label) but it declared no path set — e.g. a legacy
  # PR opened before the generator emitted the manifest. Cannot enforce a scope
  # that was never declared; surface it loudly rather than false-failing.
  echo "::warning::sync-scope-guard: PR #${PR_NUMBER} is a sync PR but declares no path manifest — cannot enforce scope. Regenerate it so the manifest is present."
  exit 0
fi

echo "Declared sync paths:"
printf '  %s\n' "$declared"

# Full changed-file list via the REST files endpoint (paginated) so an oversized
# diff never trips the 300-file / HTTP 406 cap on `gh pr diff` (see AGENTS.md).
changed=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/files" --paginate \
  --jq '.[].filename' 2>/dev/null || true)

violations=$(sync_scope_violations "$declared" "$changed")

if [ -n "$violations" ]; then
  echo ""
  echo "::error::Sync PR #${PR_NUMBER} touches paths outside its declared sync scope:"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "::error::  out of scope: ${p}"
  done <<< "$violations"
  echo ""
  echo "A generated sync PR may only touch what it declares. Either add the path to"
  echo "the declared-paths manifest in the PR body, or drop it from the diff. If this"
  echo "PR has drifted, close it — the next standards-sync run regenerates a clean one."
  exit 1
fi

echo "All changed paths are within the declared sync scope."
exit 0
