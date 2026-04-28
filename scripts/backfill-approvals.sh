#!/usr/bin/env bash
# Backfill real approvals for PRs that have agent approval comments but no actual approvals.
#
# Usage: backfill-approvals.sh [dry_run]
#   dry_run = "true" for dry-run (default: false)

set -euo pipefail

# Default to dry-run (true) unless explicitly set to false
DRY_RUN="${1:-true}"

# Verify GitHub auth is available
if ! gh auth status &>/dev/null; then
  echo "ERROR: Not authenticated with GitHub. Run 'gh auth login' first."
  exit 1
fi

echo "=== Backfilling approvals for reviewed PRs ==="
echo "Dry run: $DRY_RUN"
echo ""

approved=0
failed=0
skipped=0

# Build list of all repos
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "Checking $repo..."

  # Get all open PRs with approval marker comments in this repo
  while IFS='|' read -r pr_url pr_num; do
    # Check if PR has agent approval marker
    marker=$(gh pr view "$pr_url" --json comments --jq '.comments[] | select(.body | contains("pr-review-agent") and contains("decision=approved")) | .body' 2>/dev/null | head -1 || true)
    [ -z "$marker" ] && continue

    # Check if PR review decision is already satisfied (not REVIEW_REQUIRED)
    review_decision=$(gh pr view "$pr_url" --json reviewDecision --jq '.reviewDecision' 2>/dev/null || echo "UNKNOWN")
    if [ "$review_decision" != "REVIEW_REQUIRED" ]; then
      echo "  ✓ PR #$pr_num - review already satisfied ($review_decision)"
      skipped=$((skipped + 1))
      continue
    fi

    # Get the approval comment
    comment=$(gh pr view "$pr_url" --json comments --jq '.comments[] | select(.body | contains("pr-review-agent") and contains("decision=approved")) | .body' 2>/dev/null | tail -1 || true)
    [ -z "$comment" ] && continue

    echo "  → PR #$pr_num - posting real approval..."
    if [ "$DRY_RUN" = "true" ]; then
      echo "    [DRY RUN] Would post approval"
      approved=$((approved + 1))
    else
      if gh pr review "$pr_url" --approve --body "$comment" 2>&1; then
        echo "    ✓ Posted real approval"
        approved=$((approved + 1))
      else
        rc=$?
        echo "    ✗ Failed to post approval (exit code $rc)"
        failed=$((failed + 1))
      fi
    fi
  done < <(gh pr list --repo "$repo" --state open --json url,number,comments --limit 100 2>/dev/null | jq -r '.[] | select(.comments | length > 0) | {url, number} | "\(.url)|\(.number)"')
done < <(
  {
    gh repo list don-petry --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true
    gh repo list petry-projects --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true
  } | sort -u
)

echo ""
echo "=== Summary ==="
echo "Already have real approvals: $skipped"
echo "Approvals posted: $approved"
echo "Failures: $failed"
