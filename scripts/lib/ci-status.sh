#!/usr/bin/env bash
# ci-status.sh — compute CI gate status from a statusCheckRollup JSON array,
# filtering out first-party agents' own check runs so the reviewing cascade never
# blocks on itself (issue #469) or on another writing agent's orchestration check
# (issue #1427).
#
# Usage: source this file, then call compute_ci_status with the rollup array.

# Directory this library lives in — used to resolve the interaction contracts
# (../../interaction-contracts) relative to the script, independent of CWD.
_CI_STATUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# compute_ci_status <rollup_json>
#
# Inputs:
#   $1 — JSON array (the .statusCheckRollup field from `gh pr view`)
#
# Outputs (stdout): one of "passing", "pending", "failing"
#
# Required-check gating (#1549): after own/agent filtering, if the rollup marks
# any remaining check required (its .isRequired field, which GitHub computes from
# the branch's rulesets AND classic protection), classification gates ONLY on
# those required checks — a red NON-required check (a superseded
# 'dev-lead / dispatch', or 'template-drift' from a repo-template Dependabot bump)
# no longer blocks the review that would approve an otherwise-green PR. When no
# remaining check is flagged required (isRequired absent, or no protection), the
# gate falls back to evaluating every external check (fail-safe, unchanged).
#
# Classification rules (after filtering own checks, over the gated set):
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

# Shared jq `def is_agent_check` — a check run belonging to any *first-party
# agentic role's* own workflow, excluded from the CI gate so a writing agent's own
# orchestration check (e.g. dev-lead's "dev-lead / dispatch") cannot defer the
# reviewing agent (#1427, AC #1/#2). This GENERALISES the #469 self-filter above:
# rather than hard-coding each agent, the role slugs are derived from the declared
# interaction contracts (interaction-contracts/*.yml, #1404) — the single registry
# that already names each role and its workflows — and passed in via `$agent_roles`.
#
# A role's check runs surface in the rollup as the nested "<role> / <job>" form
# (caller-job / reusable-job), e.g. "dev-lead / dispatch", "dev-lead / ci-relay".
# We match that exact shape (name == role, or name starts with "<role> / ") so a
# genuine external check that merely shares a job name (bare "dispatch", or
# "Build / review") is never swallowed — the same conservative matching the
# self-filter uses for "review" vs "Build / review".
_CI_STATUS_JQ_IS_AGENT_CHECK='
    def is_agent_check:
      (.name // .context // "") as $n |
      ($agent_roles | any(. as $r | ($r | length) > 0 and
        ($n == $r or ($n | startswith($r + " / ")))));'

# _ci_status_agent_roles_json — JSON array of first-party agent role slugs whose
# own check runs must be excluded from the CI gate (#1427). Derived from the
# declared interaction contracts so the exclusion can never drift from a second
# hand-maintained list. Each contract file declares `role: <slug>`.
#
# Overridable for tests / callers via CI_STATUS_AGENT_ROLES_JSON (a JSON array) or
# CI_STATUS_CONTRACTS_DIR (the contracts directory). Always emits valid JSON — on
# any error it degrades to "[]" (no agent filtering), which is safe: it only
# reverts to the pre-#1427 behavior of counting those checks.
_ci_status_agent_roles_json() {
  if [ -n "${CI_STATUS_AGENT_ROLES_JSON:-}" ]; then
    printf '%s' "$CI_STATUS_AGENT_ROLES_JSON"
    return 0
  fi
  local dir="${CI_STATUS_CONTRACTS_DIR:-$_CI_STATUS_LIB_DIR/../../interaction-contracts}"
  local roles_json="[]"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    local files
    files=("$dir"/*.yml)
    if [ -e "${files[0]}" ]; then
      roles_json=$(
        grep -hE '^role:[[:space:]]' "${files[@]}" 2>/dev/null \
          | sed -E 's/^role:[[:space:]]*//; s/[[:space:]]+$//' \
          | jq -R 'select(length > 0)' 2>/dev/null \
          | jq -s 'unique' 2>/dev/null
      ) || roles_json="[]"
      [ -n "$roles_json" ] || roles_json="[]"
    fi
  fi
  printf '%s' "$roles_json"
}

compute_ci_status() {
  local rollup_json="${1:-[]}"
  local agent_roles
  agent_roles="$(_ci_status_agent_roles_json)"
  jq -r --argjson agent_roles "$agent_roles" "
    # A check carrying a non-empty conclusion is terminal, whatever its status
    # says (#1427, AC #3): GitHub can report a zombie check as IN_PROGRESS while
    # already carrying a terminal conclusion (observed on PR #1426:
    # status IN_PROGRESS + conclusion SUCCESS). A conclusion is by definition
    # terminal, so it wins over a stale running status.
    def is_terminal:
      (.conclusion != null and .conclusion != \"\");
    def is_pending:
      (is_terminal | not) and (
        .status == \"IN_PROGRESS\" or .status == \"QUEUED\" or .status == \"WAITING\" or
        .status == \"COMPLETED\"  or
        .state  == \"PENDING\"     or .state  == \"EXPECTED\"
      );
    def is_success:
      .conclusion == \"SUCCESS\" or .conclusion == \"SKIPPED\" or .conclusion == \"NEUTRAL\" or
      .state == \"SUCCESS\";
    # CANCELLED checks are non-blocking, not failing (issue #608): superseded
    # dev-lead orchestration jobs leave terminal CANCELLED check-runs that are
    # not a real merge-readiness signal.
    def is_cancelled:
      .conclusion == \"CANCELLED\";
    # A rollup entry is required iff GitHub marks it required for THIS PR — the
    # .isRequired field on the statusCheckRollup entry, which reflects the target
    # branch's rulesets AND classic branch protection combined (#1549). Gating on
    # it means a red NON-required check (a superseded 'dev-lead / dispatch', or
    # 'template-drift' from a repo-template Dependabot bump) no longer blocks the
    # review that would post the approval — the circular skip in #1549.
    def is_required:
      (.isRequired == true);
    # Classify a list of checks: pending dominates, then all-green/cancelled,
    # else failing. An empty set is passing (nothing left to gate on).
    def classify(\$set):
      if (\$set | length) == 0 then \"passing\"
      elif ([\$set[] | select(is_pending)] | length) > 0 then \"pending\"
      elif all(\$set[]; is_success or is_cancelled) then \"passing\"
      else \"failing\"
      end;
    $_CI_STATUS_JQ_IS_OWN_CHECK
    $_CI_STATUS_JQ_IS_AGENT_CHECK
    if (. == null or (type != \"array\")) then \"passing\"
    else
      (map(select((is_own_check or is_agent_check) | not))) as \$ext |
      # Gate on required checks only when the rollup marks at least one external
      # check required; otherwise (isRequired absent — older gh, no protection, or
      # required checks not yet reported) fall back to evaluating every external
      # check. Fail-safe and backward-compatible: a genuine failure is never
      # silently passed just because nothing was flagged required.
      ([ \$ext[] | select(is_required) ]) as \$req |
      (if (\$req | length) > 0 then \$req else \$ext end) as \$gate |
      classify(\$gate)
    end
  " <<< "$rollup_json" 2>/dev/null || echo "passing"
}

# ci_pending_age_exceeded <rollup_json> <max_age_sec> [now_epoch]
#
# Bounded-deferral guard (issue #1427, AC #3/#4). Given the same external checks
# compute_ci_status would classify as pending (own + agent checks already
# excluded), returns "true" iff there is at least one such pending check AND every
# one of them has been pending longer than <max_age_sec> — i.e. the pending state
# is genuinely STUCK, not merely slow. A pending check with no usable timestamp
# counts as NOT-exceeded, so an unknown age can never trip the timeout (fail-safe).
#
# Callers use this only to bound the review DECISION, never the merge gate: a
# genuinely-pending *required* check still blocks the merge at the ruleset
# regardless of this timeout, so proceeding here can never merge a not-yet-green
# PR (AC #4).
ci_pending_age_exceeded() {
  local rollup_json="${1:-[]}" max_age="${2:-1800}" now_epoch="${3:-}"
  local agent_roles now_arg
  agent_roles="$(_ci_status_agent_roles_json)"
  case "$max_age" in ''|*[!0-9]*) max_age=1800 ;; esac
  if [[ -n "$now_epoch" && "$now_epoch" =~ ^[0-9]+$ ]]; then
    now_arg="$now_epoch"
  else
    now_arg="null"
  fi
  jq -r --argjson agent_roles "$agent_roles" --argjson max "$max_age" --argjson nowarg "$now_arg" "
    def is_terminal:
      (.conclusion != null and .conclusion != \"\");
    def is_pending:
      (is_terminal | not) and (
        .status == \"IN_PROGRESS\" or .status == \"QUEUED\" or .status == \"WAITING\" or
        .status == \"COMPLETED\"  or
        .state  == \"PENDING\"     or .state  == \"EXPECTED\"
      );
    $_CI_STATUS_JQ_IS_OWN_CHECK
    $_CI_STATUS_JQ_IS_AGENT_CHECK
    (if \$nowarg == null then now else \$nowarg end) as \$now |
    if (. == null or (type != \"array\")) then \"false\"
    else
      [ .[] | select((is_own_check or is_agent_check) | not) | select(is_pending) ] as \$pend |
      if (\$pend | length) == 0 then \"false\"
      elif all(\$pend[];
             ((.startedAt // .createdAt // .started_at // \"\") as \$ts |
              if (\$ts | type) != \"string\" or \$ts == \"\" then false
              else (\$now - (\$ts | fromdateiso8601? // \$now)) > \$max
              end))
        then \"true\" else \"false\"
      end
    end
  " <<< "$rollup_json" 2>/dev/null || echo "false"
}

# Workflow names from pr-review-sweep.yml's workflow_run.workflows: — the
# complete set the fast path can key on. Any check whose workflowName is absent
# from this list (or that has no workflowName at all) is un-eventable and falls
# to the scheduled cron backstop. Must stay in sync with pr-review-sweep.yml;
# test_ci_status.bats validates drift automatically.
_CI_STATUS_EVENTABLE_WORKFLOWS='["CI","Tests","Holdout Guard","SonarCloud Analysis","Lint"]'

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
# A rollup entry is EVENTABLE iff it carries a workflowName that matches one of
# the pr-review-sweep workflow_run trigger workflows (_CI_STATUS_EVENTABLE_WORKFLOWS).
# Checks with an absent/empty workflowName — StatusContexts and App/cross-repo
# CheckRuns — are un-eventable. Checks from workflows not in the trigger list are
# also treated as un-eventable: the sweep cannot receive a workflow_run for them
# and so only the scheduled backstop covers those PRs.
#
# Outputs (stdout) one of:
#   "none"            — no external (non-own) checks at all
#   "eventable-only"  — ≥1 external check, and every external check is eventable
#                       (the fast path fully covers this PR)
#   "has-uneventable" — ≥1 external check is un-eventable (missing a workflowName
#                       or workflowName outside the sweep's allowlist); only the
#                       scheduled sweep can re-review these PRs
classify_rollup_eventability() {
  local rollup_json="${1:-[]}"
  local agent_roles
  agent_roles="$(_ci_status_agent_roles_json)"
  jq -r --argjson agent_roles "$agent_roles" "
    $_CI_STATUS_JQ_IS_OWN_CHECK
    $_CI_STATUS_JQ_IS_AGENT_CHECK
    def is_uneventable:
      (.workflowName // \"\") as \$wf |
      \$wf == \"\" or
      ($_CI_STATUS_EVENTABLE_WORKFLOWS | index(\$wf)) == null;
    if (. == null or (type != \"array\")) then \"none\"
    else
      (map(select((is_own_check or is_agent_check) | not))) as \$ext |
      if (\$ext | length) == 0 then \"none\"
      elif ([\$ext[] | select(is_uneventable)] | length) > 0 then \"has-uneventable\"
      else \"eventable-only\"
      end
    end
  " <<< "$rollup_json" 2>/dev/null || echo "none"
}
