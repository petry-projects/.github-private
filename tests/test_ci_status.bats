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
# Bare job-name checks — treated as external (NOT filtered by is_own_check)
# A target repo may have CI jobs with these names; filtering them would hide
# real CI failures. Only workflow-prefixed PR Review checks are filtered.
# ---------------------------------------------------------------------------

@test "bare check named 'review' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "review" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare check named 'dispatch' (IN_PROGRESS) is NOT filtered → pending" {
  local r
  r=$(rollup "$(check_run "dispatch" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "bare check named 'ci-relay' (IN_PROGRESS) is NOT filtered → pending" {
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
# Failure classification: PR Review workflow checks filtered; bare names not
# ---------------------------------------------------------------------------

@test "bare check named 'review' (COMPLETED/FAILURE) is NOT filtered → failing" {
  local r
  r=$(rollup "$(check_run "review" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "failing" ]
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
# Mix: bare-name pending + external passing → pending (bare names not filtered)
# ---------------------------------------------------------------------------

@test "mix: bare 'review' pending + external passing → pending" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Lint" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

@test "mix: bare 'dispatch' pending + external passing → pending" {
  local r
  r=$(rollup \
    "$(check_run "dispatch" "IN_PROGRESS")" \
    "$(check_run "Build" "COMPLETED" "SUCCESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Mix: own pending + external pending → pending (external still blocks)
# ---------------------------------------------------------------------------

@test "mix: bare 'review' pending + external pending → pending" {
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Build" "IN_PROGRESS")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
}

# ---------------------------------------------------------------------------
# Mix: own pending + external failing → failing (external still fails)
# ---------------------------------------------------------------------------

@test "mix: bare 'review' pending + external failing → pending (pending fires first)" {
  # Both 'review' and 'Test' are in $ext. The pending branch fires first
  # (before the failure check), so the result is "pending" — once all checks
  # finish, a subsequent call will return "failing".
  local r
  r=$(rollup \
    "$(check_run "review" "IN_PROGRESS")" \
    "$(check_run "Test" "COMPLETED" "FAILURE")")
  run compute_ci_status "$r"
  [ "$output" = "pending" ]
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
# Rollup with only bare own-check names → pending (not filtered)
# ---------------------------------------------------------------------------

@test "rollup with only bare own-check names returns pending (not filtered)" {
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
