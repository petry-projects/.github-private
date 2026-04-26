#!/usr/bin/env bash
# Fix PRs that have agent comments but no actual approval reviews.
#
# Problem: agent was posting comments with decision=approved instead of
# actual approval reviews, so auto-merge never triggered.
#
# Solution: find these PRs and post proper approval reviews.
#
# NOTE: Must be run with GH_TOKEN set to the bot account token (petry-review-bot),
# not the PR author account. GitHub blocks self-approvals.

set -euo pipefail

DRY_RUN="${1:-true}"

# Debug: check authentication
echo "GH_TOKEN set: ${GH_TOKEN:+yes}${GH_TOKEN:+-masked}"
CURRENT_USER=$(gh api user --jq '.login' 2>/dev/null || echo "app-token")
echo "Authenticated as: $CURRENT_USER"

echo "=== Finding PRs with agent marker comments but no approval reviews ==="

# Get list of all open PRs authored by @me
PRSL=$(gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --json url,number,repository \
  --limit 100)

PROBLEM_PRS=0
FIXED_PRS=0

echo "$PRSL" | jq -r '.[] | "\(.repository.nameWithOwner) #\(.number) \(.url)"' | while read -r repo num url; do
  # Check if this PR has our marker comment
  MARKER_COUNT=$(gh pr view "$url" --json comments \
    --jq '[.comments[] | select(.body | contains("pr-review-agent v1"))] | length' 2>/dev/null || echo 0)

  if [ "$MARKER_COUNT" -eq 0 ]; then
    continue
  fi

  # Check if it has an actual approval review
  APPROVAL_COUNT=$(gh pr view "$url" --json reviews \
    --jq '[.reviews[] | select(.state == "APPROVED")] | length' 2>/dev/null || echo 0)

  if [ "$APPROVAL_COUNT" -gt 0 ]; then
    # Already has approval, skip
    continue
  fi

  # Check if auto-merge is enabled
  AUTOMERGE_ENABLED=$(gh pr view "$url" --json autoMerge \
    --jq '.autoMerge != null' 2>/dev/null || echo false)

  echo "Problem PR found: $repo #$num"
  echo "  - Has marker comment: yes"
  echo "  - Has approval review: no"
  echo "  - Auto-merge enabled: $AUTOMERGE_ENABLED"

  if [ "$DRY_RUN" = "true" ]; then
    echo "  [DRY RUN] Would post approval review and enable auto-merge"
  else
    echo "  Posting approval review..."
    gh pr review "$url" --approve --body "Automated approval after review posting fix" || {
      echo "  ERROR: failed to post approval review"
      continue
    }

    if [ "$AUTOMERGE_ENABLED" = "false" ]; then
      echo "  Enabling auto-merge..."
      gh pr merge "$url" --auto --squash || {
        echo "  ERROR: failed to enable auto-merge"
      }
    fi

    FIXED_PRS=$((FIXED_PRS + 1))
    echo "  ✓ Fixed"
  fi

  PROBLEM_PRS=$((PROBLEM_PRS + 1))
done

echo ""
echo "Summary:"
echo "  Found $PROBLEM_PRS problem PRs"
if [ "$DRY_RUN" = "true" ]; then
  echo "  (dry-run: no changes made)"
else
  echo "  Fixed $FIXED_PRS PRs"
fi
