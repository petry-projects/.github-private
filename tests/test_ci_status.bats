#!/usr/bin/env bats
# Unit tests for compute_ci_status in scripts/lib/ci-status.sh
# (issue #469: own check runs must never cause ci-pending/ci-failing classification)
#
# Run with: bats tests/test_ci_status.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/ci-status.sh"
}

# ---------------------------------------------------------------------------
# Helpers to build statusCheckRollup items
# ---------------------------------------------------------------------------

# check_run <name> <status> [conclusion]
# Models a GitHub Actions CheckRun in the statusCheckRollup array.
check_run() {
  local name="$1" status="$2" conclusion="${3:-null}"
  if [ "$conclusion" = "null" ]; then
    jq -n --arg name "$name" --arg status "$status" \
      '{name: $name, status: $status, conclusion: null}'
  else
    jq -n --arg name "$name" --arg status "$status" --arg conclusion "$conclusion" \
      '{name: $name, status: $status, conclusion: $conclusion}'
  fi
}

# check_run_wf <name> <workflowName> <status> [conclusion]
# Models a CheckRun that also carries a workflowName (as the real rollup does).
check_run_wf() {
  local name="$1" wf="$2" status="$3" conclusion="${4:-null}"
  if [ "$conclusion" = "null" ]; then
    jq -n --arg name "$name" --arg wf "$wf" --arg status "$status" \
      '{name: $name, workflowName: $wf, status: $status, conclusion: null}'
  else
    jq -n --arg name "$name" --arg wf "$wf" --arg status "$status" --arg conclusion "$conclusion" \
      '{name: $name, workflowName: $wf, status: $status, conclusion: $conclusion}'
  fi
}

# status_ctx <context> <state>
# Models a commit StatusContext in the statusCheckRollup array.
status_ctx() {
  jq -n --arg context "$1" --arg state "$2" \
    '{context: $context, state: $state}'
}

# rollup <item-json>...
# Wraps items into a JSON array.
rollup() {
  printf '%s\n' "$@" | jq -s '.'
}

# ---------------------------------------------------------------------------
# Baseline: empty / all-passing rollups
# ---------------------------------------------------------------------------

@test "empty rollup returns passing" {
  run compute_ci_status '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "passing" ]
}

@test "single passing external check returns passing" {
  local r
  r=$(rollup "$(check_run "Lint" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "single skipped external check returns passing" {
  local r
  r=$(rollup "$(check_run "Path-filtered" "COMPLETED" "SKIPPED")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "single neutral external check returns passing" {
  local r
  r=$(rollup "$(check_run "Informational" "COMPLETED" "NEUTRAL")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# External pending / failing without own checks
# ---------------------------------------------------------------------------

@test "single external IN_PROGRESS check returns pending" {
  local r
  r=$(rollup "$(check_run "Build" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "single external QUEUED check returns pending" {
  local r
  r=$(rollup "$(check_run "Test" "QUEUED")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "single external failing check returns failing" {
  local r
  r=$(rollup "$(check_run "Test" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# PR Review Agent bare job name IS filtered (actual rollup shape)
# `gh pr view --json statusCheckRollup` exposes the job name only (not the
# workflow name, per gh/cli#9091), so the PR Review Agent's own job appears as
# a bare name: "review". This is filtered to prevent the cascade from blocking
# on its own pending check run.
# Dev-Lead bare job names ("dispatch", "ci-relay") are NOT filtered because
# Dev-Lead can commit back to the PR branch.
# ---------------------------------------------------------------------------

@test "bare PR Review Agent check 'review' (IN_PROGRESS) is filtered → passing" {
  local r
  r=$(rollup "$(check_run "review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "bare Dev-Lead check 'dispatch' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "dispatch" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare Dev-Lead check 'ci-relay' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "ci-relay" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare check named 'pr-review-mention' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "pr-review-mention" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare check named 'mention-ack' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "mention-ack" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Known PR Review workflow checks ARE filtered — workflow / job-name form
# ---------------------------------------------------------------------------

@test "'PR Review Agent / review' (IN_PROGRESS) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review Agent / review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "'PR Review Reusable / review' (IN_PROGRESS) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review Reusable / review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "'PR Review — Mention Trigger / pr-review-mention' (IN_PROGRESS) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review — Mention Trigger / pr-review-mention" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# #497 self-host: invoked via the trigger stub, the cascade's own check appears
# as the nested "review / review" — must still be filtered so a stale/failed own
# check never blocks the agent from re-reviewing.
@test "nested 'review / review' (FAILURE) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "review / review" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "nested 'review / review' FAILURE alongside an external pass → passing" {
  local r
  r=$(rollup "$(check_run "review / review" "COMPLETED" "FAILURE")" "$(check_run "SonarCloud" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "a genuinely external failing check still → failing (regression guard)" {
  local r
  r=$(rollup "$(check_run "review / review" "COMPLETED" "FAILURE")" "$(check_run "SonarCloud" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# #536 consumer fan-out: a consumer's OLD pr-review check appears as
# "pr-review / review" with workflowName "PR Review Agent" — filtered by
# workflowName so a stale failed own-check doesn't block re-review.
@test "consumer 'pr-review / review' (workflowName PR Review Agent, FAILURE) is filtered → passing" {
  local r
  r=$(rollup "$(check_run_wf "pr-review / review" "PR Review Agent" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "workflowName filter does NOT swallow an external failing check" {
  local r
  r=$(rollup "$(check_run_wf "pr-review / review" "PR Review Agent" "COMPLETED" "FAILURE")" "$(check_run_wf "Backend CI" "Backend CI" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# Dev-lead and generic workflow/job-suffix checks are NOT filtered
# Dev-lead can commit back to the PR branch, so it must remain a real CI gate.
# A generic 'workflow / review' suffix (e.g., 'Build / review') must also block
# so external required checks are never silently bypassed.
# ---------------------------------------------------------------------------

@test "'dev-lead / dispatch' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "dev-lead / dispatch" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "'dev-lead / ci-relay' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "dev-lead / ci-relay" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "'Build / review' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "Build / review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Failure classification: PR Review checks (bare and compound) are filtered
# ---------------------------------------------------------------------------

@test "bare PR Review Agent check 'review' (COMPLETED/FAILURE) is filtered → passing" {
  local r
  r=$(rollup "$(check_run "review" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "'PR Review Agent / review' (COMPLETED/FAILURE) is filtered out → passing" {
  local r
  r=$(rollup "$(check_run "PR Review Agent / review" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Mix: PR Review workflow pending + external passing → passing (filtered)
# ---------------------------------------------------------------------------

@test "mix: 'PR Review Agent / review' pending + external passing → passing" {
  local r
  r=$(rollup \
    "$(check_run "PR Review Agent / review" "IN_PROGRESS")" \
    "$(check_run "CI / build" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Mix: bare PR Review Agent checks filtered; external result determines status
# ---------------------------------------------------------------------------

@test "mix: bare 'review' filtered + external passing → passing" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Lint" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

@test "mix: bare 'dispatch' NOT filtered + external passing → pending" {
  local r
  r=$(rollup \
    "$(check_run "dispatch" "IN_PROGRESS")" \
    "$(check_run "Build" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Mix: bare PR Review Agent check filtered + external pending → pending
# ---------------------------------------------------------------------------

@test "mix: bare 'review' filtered + external pending → pending" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Build" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Mix: bare PR Review Agent check filtered + external failing → failing
# ---------------------------------------------------------------------------

@test "mix: bare 'review' filtered + external failing → failing" {
  # 'review' is filtered out; only 'Test' (COMPLETED/FAILURE) remains in $ext.
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Test" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

# ---------------------------------------------------------------------------
# Rollup with only PR Review workflow checks → passing (all filtered)
# ---------------------------------------------------------------------------

@test "rollup with only PR Review workflow/job form checks returns passing" {
  local r
  r=$(rollup \
    "$(check_run "PR Review Agent / review" "IN_PROGRESS")" \
    "$(check_run "PR Review — Mention Trigger / pr-review-mention" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# Rollup with only PR Review Agent bare job names → passing (all filtered)
# ---------------------------------------------------------------------------

@test "rollup: 'review' filtered, Dev-Lead 'dispatch' + 'ci-relay' NOT filtered → pending" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "dispatch" "IN_PROGRESS")" \
    "$(check_run "ci-relay" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# StatusContext checks are unaffected by the own-check filter
# ---------------------------------------------------------------------------

@test "status context with PENDING state still causes pending classification" {
  local r
  r=$(rollup "$(status_ctx "sonarcloud" "PENDING")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "status context with FAILURE state still causes failing classification" {
  local r
  r=$(rollup "$(status_ctx "sonarcloud" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
}

@test "status context named 'external-ci' (non-own-check) with PENDING state still causes pending" {
  # StatusContext entries that do not match any own-check prefix must still block
  # as pending — verifies the filter doesn't accidentally swallow external statuses.
  local r
  r=$(rollup "$(status_ctx "external-ci" "PENDING")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Malformed / edge input
# ---------------------------------------------------------------------------

@test "malformed JSON input returns passing (safe default)" {
  run compute_ci_status "not-json"
  [ "$status" -eq 0 ]
  [ "$output" = "passing" ]
}

@test "null JSON input returns passing (safe default)" {
  run compute_ci_status "null"
  [ "$output" = "passing" ]
}
