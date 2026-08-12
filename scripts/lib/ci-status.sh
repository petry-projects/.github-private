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
#   passing — empty rollup, or every item is SUCCESS/SKIPPED/NEUTRAL/CANCELLED
#             conclusion or SUCCESS state
#   pending — any item is IN_PROGRESS/QUEUED/WAITING/PENDING/EXPECTED or
#             COMPLETED with null/empty conclusion
#   failing — anything else (FAILURE, ACTION_REQUIRED, TIMED_OUT, etc.)
#
# CANCELLED is treated as non-blocking, not failing (issue #608). dev-lead's
# orchestration jobs (dev-lead / dispatch, dev-lead / ci-relay) are routinely
# cancelled by dev-lead's own concurrency when a run is superseded, leaving
# terminal CANCELLED check-runs on the PR. A cancelled check is not a failed
# check, so it must not block the review gate. It is non-blocking rather than
# pending because a superseded check never completes — classifying it pending
# would leave the PR perpetually un-reviewable.
#
# Own-check filter — excludes entries belonging to the PR Review cascade.
#   `gh pr view --json statusCheckRollup` exposes the check/job *name* but not
#   the workflow name (gh/cli#9091), so the PR Review Agent's single job appears
#   with its bare job name in the rollup: "review".
#   This is matched explicitly to prevent the cascade from blocking on its own
#   pending check run. Compound "workflow / job" forms are also matched for
#   reusable-workflow callers where that format does appear.
#   Dev-Lead bare checks ("dispatch", "ci-relay") are NOT filtered because
#   Dev-Lead can commit back to the PR branch; filtering them could cause a review
#   to race an in-progress branch-mutating run.
#   Matched:
#   • Bare job name: "review"
#   • Nested job form "review / review" — produced once the cascade is invoked
#     via the trigger stub (pr-review-trigger.yml → reusable pr-review.yml@
#     pr-review/stable), where the rollup name becomes "callerJob / reusableJob"
#     rather than the bare job name (#497 self-host). Matched exactly (not by a
#     "/ review" suffix) so a genuine external "Build / review" is NOT filtered.
#   • "PR Review Agent / *"
#   • "PR Review Reusable / *"
#   • "PR Review — Mention Trigger / *"

# Shared jq `def is_own_check` — the PR Review cascade's own check runs, excluded
# by both compute_ci_status and classify_rollup_eventability so neither blocks nor
# misclassifies the cascade on its own output. Kept in one place to prevent drift.
_CI_STATUS_JQ_IS_OWN_CHECK='
    def is_own_check:
      (.name // .context // "") as $n |
      (.workflowName // "") as $wf |
      # Primary, robust signal: any check produced by a PR Review cascade
      # workflow (PR Review Agent, the Trigger stub, PR Review Reusable, the
      # Mention Trigger), regardless of the job-name format the rollup reports
      # (#536: a consumer old check "pr-review / review" had workflowName
      # "PR Review Agent"). Falls back to name patterns when the rollup does
      # not expose workflowName.
      ($wf | test("^PR Review")) or
      ($n == "review") or
      ($n == "review / review") or
      ($n | test("^PR Review (Agent|Reusable) /")) or
      ($n | test("^PR Review — Mention Trigger /"));'

compute_ci_status() {
  local rollup_json="${1:-[]}"
  jq -r "
    def is_pending:
      .status == \"IN_PROGRESS\" or .status == \"QUEUED\" or .status == \"WAITING\" or
      .state  == \"PENDING\"     or .state  == \"EXPECTED\" or
      (.status == \"COMPLETED\" and (.conclusion == null or .conclusion == \"\"));
    def is_success:
      .conclusion == \"SUCCESS\" or .conclusion == \"SKIPPED\" or .conclusion == \"NEUTRAL\" or
      .state == \"SUCCESS\";
    # CANCELLED checks are non-blocking, not failing (issue #608): superseded
    # dev-lead orchestration jobs leave terminal CANCELLED check-runs that are
    # not a real merge-readiness signal.
    def is_cancelled:
      .conclusion == \"CANCELLED\";
    $_CI_STATUS_JQ_IS_OWN_CHECK
    if (. == null or (type != \"array\")) then \"passing\"
    else
      (map(select(is_own_check | not))) as \$ext |
      if (\$ext | length) == 0 then \"passing\"
      elif ([\$ext[] | select(is_pending)] | length) > 0 then \"pending\"
      elif all(\$ext[]; is_success or is_cancelled) then \"passing\"
      else \"failing\"
      end
    end
  " <<< "$rollup_json" 2>/dev/null || echo "passing"
}

# classify_rollup_eventability <rollup_json>
#
# Split a PR's non-own checks by whether their completion emits a `workflow_run`
# this repo can key on (#1408). The pr-review-sweep's workflow_run fast path
# re-reviews a PR the instant an eventable GitHub Actions check finishes; the
# scheduled (cron) sweep exists for the genuinely UN-eventable residue —
# GitHub-App / cross-repo checks (SonarCloud is the named example) that post a
# StatusContext or an app CheckRun carrying no workflowName, so no workflow_run
# ever fires for them and only the timer re-reviews them.
#
# A rollup entry is EVENTABLE iff it carries a non-empty workflowName (a GitHub
# Actions check run in this repo). Everything else — StatusContexts and
# App/cross-repo CheckRuns with no workflowName — is un-eventable.
#
# Outputs (stdout) one of:
#   "none"            — no external (non-own) checks at all
#   "eventable-only"  — ≥1 external check, and every external check is eventable
#                       (the fast path fully covers this PR)
#   "has-uneventable" — ≥1 external check has no workflowName (un-eventable residue
#                       that only the scheduled sweep can re-review)
classify_rollup_eventability() {
  local rollup_json="${1:-[]}"
  jq -r "
    $_CI_STATUS_JQ_IS_OWN_CHECK
    def is_uneventable: (.workflowName // \"\") == \"\";
    if (. == null or (type != \"array\")) then \"none\"
    else
      (map(select(is_own_check | not))) as \$ext |
      if (\$ext | length) == 0 then \"none\"
      elif ([\$ext[] | select(is_uneventable)] | length) > 0 then \"has-uneventable\"
      else \"eventable-only\"
      end
    end
  " <<< "$rollup_json" 2>/dev/null || echo "none"
}
