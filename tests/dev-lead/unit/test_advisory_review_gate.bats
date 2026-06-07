#!/usr/bin/env bats
# Tests for advisory-review-gate.sh
#
# Tests the wait logic for advisory bot reviews (Gemini, Copilot, SonarCloud, Codex)

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
}

teardown() {
  unset SCRIPT_DIR
}

@test "Advisory gate: script is executable" {
  [ -x "$SCRIPT_DIR/lib/advisory-review-gate.sh" ]
}

@test "Advisory gate: script has correct shebang" {
  head -1 "$SCRIPT_DIR/lib/advisory-review-gate.sh" | grep -q "^#!/usr/bin/env bash"
}

@test "Advisory gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines ADVISORY_BOTS array with 4 bots" {
  grep -q "gemini-code-assist" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "copilot-pull-request-reviewer" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "sonarqubecloud" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "chatgpt-codex-connector" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines TIER1_WAIT timeout (900 seconds)" {
  grep -q "TIER1_WAIT=900" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines TIER2_WAIT timeout (1200 seconds)" {
  grep -q "TIER2_WAIT=1200" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines TIER3_WAIT timeout (3600 seconds)" {
  grep -q "TIER3_WAIT=3600" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines POLL_INTERVAL (configurable)" {
  grep -q "POLL_INTERVAL" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes get_advisory_bot_states function" {
  grep -q "get_advisory_bot_states()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes all_bots_submitted early-exit check" {
  grep -q "all_bots_submitted()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes format_bot_status function" {
  grep -q "format_bot_status()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes wait_for_advisory_reviews function" {
  grep -q "wait_for_advisory_reviews()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: Tier 1 has early exit on successful submissions" {
  grep -q "early exit from Tier 1" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: Tier 2 has early exit on successful submissions" {
  grep -q "early exit from Tier 2" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: Tier 3 has hard timeout warning" {
  grep -q "Hard timeout reached at" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "return 2" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: handles color output (RED, YELLOW, GREEN)" {
  grep -q "RED=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "YELLOW=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "GREEN=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes logging functions (log_info, log_warn, log_success)" {
  grep -q "log_info()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "log_warn()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "log_success()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: exit codes properly documented (0, 2)" {
  grep -q "return 0" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "return 2" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: uses subshell isolation in review-one-pr.sh" {
  grep -q "{" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "wait_for_advisory_reviews" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: PR_URL parameter validated safely" {
  grep -q 'if \[ -z "$PR_URL" \]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "Usage: wait_for_advisory_reviews" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: PR number extraction uses correct regex" {
  grep -q 'grep -oE' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q '\[0-9\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: jq query selects latest bot submission (.[−1])" {
  grep -q '\.\[-1\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: BASH_SOURCE check prevents source-time execution" {
  grep -q 'if \[ "${BASH_SOURCE\[0\]}" = "${0}" \]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: Tier 3 poll interval is configurable" {
  grep -q 'TIER3_POLL_INTERVAL' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck "$SCRIPT_DIR/lib/advisory-review-gate.sh" || true
}
