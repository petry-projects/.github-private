#!/usr/bin/env bats
# Tests for scripts/pr_review_canary.sh — the pr-review-trigger dry-run canary
# (#1052, Part D). It fires a `dry_run=true` dispatch of pr-review-trigger.yml and
# FAILS LOUD when the run ends in `startup_failure` (the #1034 breakage), turning
# today's silent post-merge failure into a gating signal.
#
# All assertions here are PURE (no network): they exercise the classification,
# failure-gate, and report helpers. Run:
#   bats tests/pr_review_canary.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME"/.. && pwd)"
  # shellcheck source=scripts/pr_review_canary.sh
  source "$REPO_ROOT/scripts/pr_review_canary.sh"
}

# ---------------------------------------------------------------------------
# classify_canary_run
# ---------------------------------------------------------------------------

@test "classify: startup_failure is the #1034 fingerprint → STARTUP_FAILURE" {
  run classify_canary_run "startup_failure"
  [ "$output" = "STARTUP_FAILURE" ]
}

@test "classify: a successful dry-run is OK" {
  run classify_canary_run "success"
  [ "$output" = "OK" ]
}

@test "classify: an empty conclusion (no completed run) is NO_RUN" {
  run classify_canary_run ""
  [ "$output" = "NO_RUN" ]
}

@test "classify: any other conclusion is FAILED" {
  run classify_canary_run "failure"
  [ "$output" = "FAILED" ]
  run classify_canary_run "timed_out"
  [ "$output" = "FAILED" ]
}

# ---------------------------------------------------------------------------
# canary_is_failure — gates on anything other than OK
# ---------------------------------------------------------------------------

@test "is_failure: OK does not alert" {
  run canary_is_failure "OK"
  [ "$status" -ne 0 ]
}

@test "is_failure: STARTUP_FAILURE alerts (gates the job)" {
  run canary_is_failure "STARTUP_FAILURE"
  [ "$status" -eq 0 ]
}

@test "is_failure: NO_RUN alerts" {
  run canary_is_failure "NO_RUN"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# canary_report — names the failure mode and the fix path
# ---------------------------------------------------------------------------

@test "report: STARTUP_FAILURE names startup_failure and the #1034 breakage" {
  run canary_report "STARTUP_FAILURE" "petry-projects/.github-private" "https://example/run/1" "2026-07-03"
  [ "$status" -eq 0 ]
  [[ "$output" == *"startup_failure"* ]]
  [[ "$output" == *"#1034"* ]]
  [[ "$output" == *"🔴"* ]]
}

@test "report: OK is a clean pass with the run link" {
  run canary_report "OK" "petry-projects/.github-private" "https://example/run/2" "2026-07-03"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅"* ]]
  [[ "$output" == *"https://example/run/2"* ]]
  [[ "$output" == *"dry-run"* ]]
}
