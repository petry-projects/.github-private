#!/usr/bin/env bash
# ci-status.sh — compute CI gate status from a statusCheckRollup JSON array,
# filtering out the PR Review Agent's own check runs so the cascade never
# blocks on itself (issue #469).
#
# Usage: source this file, then call compute_ci_status with the rollup array.

# compute_ci_status <rollup_json>
#
# Inputs:
#   $1 — JSON array (the .statusCheckRollup field from `gh pr view`)
#
# Outputs (stdout): one of "passing", "pending", "failing"
#
# Classification rules (after filtering own checks):
#   passing — empty rollup, or every item is SUCCESS/SKIPPED/NEUTRAL/SUCCESS state
#   pending — any item is IN_PROGRESS/QUEUED/WAITING/PENDING/EXPECTED or
#             COMPLETED with null/empty conclusion
#   failing — anything else (FAILURE, ACTION_REQUIRED, TIMED_OUT, etc.)
#
# Own-check filter — excludes entries whose name matches a known PR Review
#   workflow prefix only. Bare job names (review, dispatch, ci-relay, etc.)
#   are intentionally NOT matched: a target repo may have CI jobs with those
#   same names, and filtering them would let a failing or pending real CI gate
#   be silently ignored. Dev-lead checks (dev-lead / dispatch, dev-lead /
#   ci-relay) are also excluded from filtering because dev-lead can commit
#   back to the PR branch; filtering it could cause a review to race an
#   in-progress branch-mutating run.
#   Matched prefixes (applied to .name for CheckRuns and .context for
#   StatusContexts):
#   • "PR Review Agent / *"
#   • "PR Review Reusable / *"
#   • "PR Review — Mention Trigger / *"
compute_ci_status() {
  local rollup_json="${1:-[]}"
  jq -r '
    def is_pending:
      .status == "IN_PROGRESS" or .status == "QUEUED" or .status == "WAITING" or
      .state  == "PENDING"     or .state  == "EXPECTED" or
      (.status == "COMPLETED" and (.conclusion == null or .conclusion == ""));
    def is_success:
      .conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL" or
      .state == "SUCCESS";
    def is_own_check:
      (.name // .context // "") as $n |
      ($n | test("^PR Review (Agent|Reusable) /")) or
      ($n | test("^PR Review — Mention Trigger /"));
    if (. == null or (type != "array")) then "passing"
    else
      (map(select(is_own_check | not))) as $ext |
      if ($ext | length) == 0 then "passing"
      elif ([$ext[] | select(is_pending)] | length) > 0 then "pending"
      elif ([$ext[] | select(is_success)] | length) == ($ext | length) then "passing"
      else "failing"
      end
    end
  ' <<< "$rollup_json" 2>/dev/null || echo "passing"
}
