#!/usr/bin/env bash
# Validates that dev-lead workflow files use per-issue / per-PR concurrency lanes
# (dev-lead-issue-<n>, dev-lead-pr-<n>) plus a per-SHA ci-relay lane, rather than a
# single repo-wide 'dev-lead' group.
#
# History: #278 collapsed everything into one per-repo 'dev-lead' group so at most
# one dispatch ran at a time — needed only because the agent checked out PR branches
# IN PLACE, so concurrent runs corrupted each other's working tree. That serialization
# then starved issue pickups: PR follow-up traffic (reviews/comments/ci-relay) held the
# single slot and queued issue-labeled runs were superseded and cancelled before they
# could open a PR (petry-projects/.github#402).
#
# #449 (#448) removed the root hazard by checking out each PR branch in an isolated
# git worktree, so different issues/PRs can now run in parallel safely. #450 restored
# per-issue / per-PR lanes. This test guards that design against regression.
set -euo pipefail

FAIL=0

check_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file"; then
    echo "FAIL [$label]: '$pattern' found in $file (should have been removed)"
    FAIL=$((FAIL + 1))
  else
    echo "PASS [$label]: '$pattern' absent"
  fi
}

check_present() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file"; then
    echo "PASS [$label]: '$pattern' present"
  else
    echo "FAIL [$label]: '$pattern' not found in $file"
    FAIL=$((FAIL + 1))
  fi
}

check_order() {
  local file="$1" first="$2" second="$3" label="$4"
  local line_first line_second
  line_first=$(grep -nF "$first"  "$file" | head -1 | cut -d: -f1)
  line_second=$(grep -nF "$second" "$file" | head -1 | cut -d: -f1)
  if [ -z "$line_first" ] || [ -z "$line_second" ]; then
    echo "FAIL [$label]: could not find both patterns in $file"
    FAIL=$((FAIL + 1))
  elif [ "$line_first" -lt "$line_second" ]; then
    echo "PASS [$label]: correct ordering in $file"
  else
    echo "FAIL [$label]: '$first' must appear before '$second' in $file (first-match-wins routing)"
    FAIL=$((FAIL + 1))
  fi
}

# Both the inline workflow and the reusable (source of truth for all consumer
# stubs) must carry the per-lane routing.
for WORKFLOW in \
  ".github/workflows/dev-lead.yml" \
  ".github/workflows/dev-lead-reusable.yml"; do
  echo "── $WORKFLOW ──"
  if [ ! -f "$WORKFLOW" ]; then
    echo "FAIL: $WORKFLOW does not exist. Please run this script from the repository root."
    FAIL=$((FAIL + 1))
    continue
  fi

  # Per-issue and per-PR lanes must be present so a labeled-issue pickup is never
  # cancelled by unrelated PR follow-up traffic.
  # Match format('dev-lead-…') to target the concurrency expression, not comments.
  check_present "$WORKFLOW" "format('dev-lead-pr-"    "per-PR lane"
  check_present "$WORKFLOW" "format('dev-lead-issue-" "per-issue lane"

  # ci-relay keeps its own ephemeral per-SHA slot so it fires immediately.
  check_present "$WORKFLOW" "format('dev-lead-ci-relay-" "ci-relay per-SHA lane"

  # Assert the actual predicate-to-lane bindings, not just token presence.
  # issue_comment on a PR has issue.pull_request set; that predicate must route
  # to the PR lane so PR follow-up traffic shares the PR slot with other PR events.
  check_present "$WORKFLOW" \
    "github.event.issue.pull_request && format('dev-lead-pr-" \
    "issue_comment-on-PR predicate routes to PR lane"
  # repository_dispatch (ci-failure relay) carries client_payload.pr_number.
  check_present "$WORKFLOW" \
    "github.event.client_payload.pr_number && format('dev-lead-pr-" \
    "repository_dispatch routes to PR lane via client_payload.pr_number"
  # client_payload.pr_number predicate must appear BEFORE the final run-id fallback.
  # If reordered, the fallback is always truthy and every repository_dispatch
  # (ci-failure relay) gets a unique run lane instead of sharing the PR lane.
  check_order "$WORKFLOW" \
    "github.event.client_payload.pr_number && format('dev-lead-pr-" \
    "format('dev-lead-run-{0}', github.run_id)" \
    "repository_dispatch predicate before run-id fallback"
  # issue.pull_request must appear BEFORE issue.number in the || chain.
  # If reordered, an issue_comment on a PR would fall through to the issue lane
  # and share a slot with issue pickups, allowing cancellation.
  check_order "$WORKFLOW" \
    "github.event.issue.pull_request && format('dev-lead-pr-" \
    "github.event.issue.number && format('dev-lead-issue-" \
    "issue_comment-on-PR predicate before generic issue predicate"

  # Must NOT collapse back into a single repo-wide group (the #278 regression).
  # Guard all common bare-value spellings so a regression can't slip through
  # on quote-style changes.
  check_absent "$WORKFLOW" "group: dev-lead"    "no bare unquoted group: dev-lead"
  check_absent "$WORKFLOW" "group: 'dev-lead'"  "no bare single-quoted group: dev-lead"
  check_absent "$WORKFLOW" 'group: "dev-lead"'  "no bare double-quoted group: dev-lead"
  # Also reject a repo-wide fallback hidden inside the ${{ ... }} expression.
  # The group: >- form puts the value on the next lines starting with ||, so
  # "group: dev-lead" patterns above would miss a regression like || 'dev-lead'.
  check_absent "$WORKFLOW" "|| 'dev-lead'"      "no repo-wide || 'dev-lead' fallback in expression"
  check_absent "$WORKFLOW" '|| "dev-lead"'      'no repo-wide || "dev-lead" fallback in expression'

  # cancel-in-progress must be false so a queued same-lane run waits for the active
  # run to finish instead of cancelling it (in-flight pickups always complete).
  check_present "$WORKFLOW" "cancel-in-progress: false" "cancel-in-progress is false"
done

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All concurrency config checks passed."
else
  echo "$FAIL check(s) failed."
  exit 1
fi
