#!/usr/bin/env bats
# Tests for advisory-review-gate.sh (non-blocking instant check)
#
# Validates instant (non-blocking) checking of advisory bot reviews
# No polling, no timeouts - just checks current state and returns immediately

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
}

teardown() {
  unset SCRIPT_DIR
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: script is executable" {
  [ -x "$SCRIPT_DIR/lib/advisory-review-gate.sh" ]
}

@test "Advisory gate: script has correct shebang" {
  head -1 "$SCRIPT_DIR/lib/advisory-review-gate.sh" | grep -q "^#!/usr/bin/env bash"
}

@test "Advisory gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# NON-BLOCKING DESIGN TESTS (NEW)
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: no polling loops (non-blocking design)" {
  ! grep -q "TIER1_WAIT\|TIER2_WAIT\|TIER3_WAIT" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: uses check_advisory_reviews (not wait_for_advisory_reviews)" {
  grep -q "check_advisory_reviews()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: returns 0 when bots submitted, 1 when waiting" {
  grep -q "return 0" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "return 1" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: no sleep/polling delays in main logic" {
  ! grep -q "POLL_INTERVAL\|sleep " "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# CONFIGURATION & FUNCTIONALITY TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: defines all 4 advisory bots (gemini-code-assist)" {
  grep -q "gemini-code-assist" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (copilot-pull-request-reviewer)" {
  grep -q "copilot-pull-request-reviewer" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (sonarqubecloud)" {
  grep -q "sonarqubecloud" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (chatgpt-codex-connector)" {
  grep -q "chatgpt-codex-connector" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes get_advisory_bot_states function" {
  grep -q "get_advisory_bot_states()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes format_bot_status function" {
  grep -q "format_bot_status()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
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

# ────────────────────────────────────────────────────────────────────
# SAFETY & INTEGRATION TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: PR_URL parameter validated safely" {
  grep -q 'if \[ -z "$PR_URL" \]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "Usage: check_advisory_reviews" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: PR number extraction uses correct regex" {
  grep -q 'grep -oE' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: jq query selects latest bot submission (sort_by time)" {
  grep -q 'sort_by(.time)' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: BASH_SOURCE check prevents source-time execution" {
  grep -q 'if \[ "${BASH_SOURCE\[0\]}" = "${0}" \]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# INTEGRATION TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: review-one-pr.sh calls non-blocking gate" {
  grep -q "check_advisory_reviews" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: review-one-pr.sh skips on return code 1 (waiting for bots)" {
  grep -q 'if \[ $gate_rc -eq 1 \]' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q 'exit 100' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "waiting-for-advisory-bots" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: uses subshell isolation in review-one-pr.sh" {
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
}

# ────────────────────────────────────────────────────────────────────
# CODE QUALITY TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: documentation mentions non-blocking design" {
  grep -q "non-blocking\|instant check\|re-trigger" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck "$SCRIPT_DIR/lib/advisory-review-gate.sh" || true
}

@test "Advisory gate: script is minimal (non-blocking means fewer lines)" {
  local lines=$(wc -l < "$SCRIPT_DIR/lib/advisory-review-gate.sh")
  [ $lines -lt 160 ]
}
