#!/usr/bin/env bats
# Integration test: CLI format errors must route to per-PR failure (exit 1),
# NOT to session abort / engine fallback (exit 2).
#
# This tests the error-routing logic that review-one-pr.sh applies at the
# triage and single-review tiers (both check stdout + stderr).  The deep-review
# tier intentionally inspects stdout only and is covered by the unit tests in
# test_rate_limit.bats via the is_rate_limited / is_cli_error functions.
#
# Run with: bats tests/test_cli_error_routing.bats

setup() {
  export REVIEW_ENGINE="claude"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh" >/dev/null 2>&1 || true
}

# Helper: emulates the error-routing block used at all three call sites in
# review-one-pr.sh.  Returns the exit code that review-one-pr.sh would use.
#
# Note: the deep-review tier intentionally checks only stdout (not stderr) to
# prevent PR diff content in log files from causing false positives.  This
# helper checks both channels, which is accurate for the triage and
# single-review tiers.  The deep-review tier's stdout-only behaviour is tested
# separately via the is_rate_limited / is_cli_error unit tests.
route_error() {
  local rc="$1"      # exit code from the CLI / model invocation
  local stdout="$2"  # captured stdout
  local stderr="$3"  # captured stderr

  if [ "$rc" -ne 0 ]; then
    if is_cli_error "$stdout" || is_cli_error "$stderr"; then
      echo "per-pr-failure"
      return 1   # maps to exit 1
    fi
    if is_rate_limited "$stdout" || is_rate_limited "$stderr"; then
      echo "engine-fallback"
      return 2   # maps to exit 2
    fi
  fi
  echo "pass-through"
  return 0
}

# ---------------------------------------------------------------------------
# Scenario: Copilot CLI exits with "Invalid command format" (the triggering
# incident described in issue #148 / run #715).
# ---------------------------------------------------------------------------

@test "integration: Copilot 'Invalid command format' routes to per-PR failure (exit 1)" {
  local stderr
  stderr="$(printf 'error: Invalid command format.\nDid you mean: copilot -i "suggest -p ..."')"

  run route_error 1 "" "$stderr"

  [ "$status" -eq 1 ]
  [ "$output" = "per-pr-failure" ]
}

# ---------------------------------------------------------------------------
# Scenario: rate-limit hit — must still route to engine fallback (exit 2).
# ---------------------------------------------------------------------------

@test "integration: 'rate limit exceeded' routes to engine fallback (exit 2)" {
  run route_error 1 "rate limit exceeded" ""

  [ "$status" -eq 2 ]
  [ "$output" = "engine-fallback" ]
}

@test "integration: 'overloaded_error' routes to engine fallback (exit 2)" {
  run route_error 1 "overloaded_error" ""

  [ "$status" -eq 2 ]
  [ "$output" = "engine-fallback" ]
}

@test "integration: '529' routes to engine fallback (exit 2)" {
  run route_error 1 "HTTP status 529" ""

  [ "$status" -eq 2 ]
  [ "$output" = "engine-fallback" ]
}

@test "integration: 'quota exceeded' routes to engine fallback (exit 2)" {
  run route_error 1 "" "quota exceeded"

  [ "$status" -eq 2 ]
  [ "$output" = "engine-fallback" ]
}

# ---------------------------------------------------------------------------
# Scenario: successful invocation (rc=0) — routing must be a no-op even if
# the reviewed PR happens to mention rate-limit keywords in its diff/output.
# (Regression guard for the single-review false-positive bug fixed in #148.)
# ---------------------------------------------------------------------------

@test "integration: rc=0 with 'rate limit' in stdout does NOT trigger exit 2" {
  # A PR review that discusses rate-limit handling in code should not abort the session.
  run route_error 0 "This PR adds rate limit handling to the API client." ""

  [ "$status" -eq 0 ]
  [ "$output" = "pass-through" ]
}

@test "integration: rc=0 with 'unknown flag' in stdout does NOT trigger exit 1" {
  # A PR review that mentions CLI flags should not be misclassified as a CLI error.
  run route_error 0 "The unknown flag --debug was passed to the CLI." ""

  [ "$status" -eq 0 ]
  [ "$output" = "pass-through" ]
}

# ---------------------------------------------------------------------------
# Scenario: unknown error (neither CLI nor rate-limit) — must pass through
# so review-one-pr.sh can apply its own fallback logic.
# ---------------------------------------------------------------------------

@test "integration: generic error (rc=1, no pattern match) passes through" {
  run route_error 1 "some unexpected error occurred" "stack trace here"

  [ "$status" -eq 0 ]
  [ "$output" = "pass-through" ]
}
