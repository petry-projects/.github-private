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
  grep -q 'if \[ -z "$pr_url" \]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
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

@test "Advisory gate: bot logins not duplicated — jq uses ADVISORY_BOTS keys" {
  # The jq filter must not hard-code individual bot logins; it uses inside(\$bots)
  grep -q 'inside(\$bots)' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  # And the ADVISORY_BOTS array is the single source of truth
  grep -q 'ADVISORY_BOTS\[@\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: get_advisory_bot_states handles gh failures" {
  grep -q 'gh pr view.*2>&1' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'log_warn "gh pr view failed' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: waits for all ADVISORY_BOTS before approving" {
  grep -q 'num_submitted.*total_advisory_bots' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'total_advisory_bots=\${#ADVISORY_BOTS' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
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
  # The gate runs in a true subshell ( ) — not a brace group { } — for isolation
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
  grep -B6 "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh" | grep -q "^($"
}

# ────────────────────────────────────────────────────────────────────
# CODE QUALITY TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: documentation mentions non-blocking design" {
  grep -q "non-blocking\|instant check\|re-trigger" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: script is minimal (non-blocking means fewer lines)" {
  local lines
  lines=$(wc -l < "$SCRIPT_DIR/lib/advisory-review-gate.sh")
  [ "$lines" -lt 220 ]
}

# ────────────────────────────────────────────────────────────────────
# RUNTIME BEHAVIOR TESTS
# ────────────────────────────────────────────────────────────────────

_make_mock_gh_dir() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"createdAt"* ]]; then
  # Return a timestamp 30 minutes ago (well past the 20-minute timeout)
  date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '2000-01-01T00:00:00Z\n'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

_make_mock_gh_dir_recent() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"createdAt"* ]]; then
  # Return current time (PR is brand new, well within the 20-minute window)
  date -u '+%Y-%m-%dT%H:%M:%SZ'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

@test "Gate runtime: returns 1 when no bots have submitted" {
  local tmpdir
  tmpdir=$(_make_mock_gh_dir '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 when all 4 bots have submitted" {
  local all_bots_json
  all_bots_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"},{"author":{"login":"copilot-pull-request-reviewer"},"state":"COMMENTED","submittedAt":"2026-06-07T10:03:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2026-06-07T10:13:00Z"},{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T10:17:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir "$all_bots_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: returns 1 when only 1 bot submitted and PR is recent" {
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 after timeout even with partial bot submissions" {
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: returns 1 when gh command fails" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "Error: authentication required" >&2
exit 1
MOCK_EOF
  chmod +x "$tmpdir/gh"
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: format_bot_status renders known states" {
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "
    source '$gate_script' 2>/dev/null || true
    format_bot_status 'gemini-code-assist' 'APPROVED'
  "
  [[ "$output" == *"APPROVED"* ]]
  run bash -c "
    source '$gate_script' 2>/dev/null || true
    format_bot_status 'sonarqubecloud' 'CHANGES_REQUESTED'
  "
  [[ "$output" == *"CHANGES_REQUESTED"* ]]
}
