#!/usr/bin/env bats
# Unit tests for scripts/pr_review_health.sh
#
# Covers the Claude invocation error-handling paths:
#   - Rate limit from Claude → exit 0 + ::warning:: (workflow must not fail)
#   - Non-rate-limit Claude error → exit 1 + ::error::
#   - No failed runs in window → exit 0 (Claude never invoked)
#
# Run with: bats tests/test_pr_review_health.bats

SCRIPT="$(dirname "$BATS_TEST_FILENAME")/../scripts/pr_review_health.sh"

setup() {
  STUB_DIR="$(mktemp -d)"
  TEST_WORK_DIR="$(mktemp -d)"
  export PATH="$STUB_DIR:$PATH"
  export GITHUB_ENV="$TEST_WORK_DIR/github.env"
  touch "$GITHUB_ENV"
  # Minimal required env vars
  export LOOKBACK_DAYS=1
  export CLAUDE_CODE_OAUTH_TOKEN=test-token-stub
}

teardown() {
  rm -rf "$STUB_DIR" "$TEST_WORK_DIR"
  rm -f pr_review_health_report.md
  rm -rf health_run_logs
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# make_gh_stub: stubs gh to return controlled responses per call context.
# Returns one failed run for the per_page=100 listing so Claude is invoked.
make_gh_stub_one_failure() {
  cat > "$STUB_DIR/gh" << 'STUBEOF'
#!/usr/bin/env bash
args="$*"
# Token access check (per_page=1) — succeed silently
if printf '%s' "$args" | grep -qE 'per_page=1([^0-9]|$)'; then
  exit 0
fi
# Run listing (per_page=100) — return one failed run
if printf '%s' "$args" | grep -q 'per_page=100'; then
  printf '[{"id":99999,"status":"completed","conclusion":"failure","created_at":"2026-06-09T10:00:00Z","html_url":"https://github.com/petry-projects/.github-private/actions/runs/99999","run_number":99}]\n'
  exit 0
fi
# Workflow source fetch (contents endpoint) — base64 "test"
if printf '%s' "$args" | grep -q 'contents'; then
  printf 'dGVzdA==\n'
  exit 0
fi
# gh run view (log download for failed runs)
if printf '%s' "$args" | grep -q 'run view'; then
  printf 'step1\t2026-06-09T10:00:00Z some log line\n'
  exit 0
fi
exit 0
STUBEOF
  chmod +x "$STUB_DIR/gh"
}

# make_claude_stub: writes a claude stub that prints a message and exits.
make_claude_stub() {
  local message="$1"
  local exit_code="${2:-1}"
  cat > "$STUB_DIR/claude" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "$message"
exit "$exit_code"
STUBEOF
  chmod +x "$STUB_DIR/claude"
}

# make_gh_stub_no_failures: returns only successful runs so Claude is skipped.
make_gh_stub_no_failures() {
  cat > "$STUB_DIR/gh" << 'STUBEOF'
#!/usr/bin/env bash
args="$*"
if printf '%s' "$args" | grep -qE 'per_page=1([^0-9]|$)'; then
  exit 0
fi
if printf '%s' "$args" | grep -q 'per_page=100'; then
  printf '[{"id":99998,"status":"completed","conclusion":"success","created_at":"2026-06-09T06:00:00Z","html_url":"https://github.com/petry-projects/.github-private/actions/runs/99998","run_number":98}]\n'
  exit 0
fi
exit 0
STUBEOF
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# Rate limit → exit 0, warning annotation
# ---------------------------------------------------------------------------

@test "Claude rate limit exits 0 and emits ::warning:: annotation" {
  make_gh_stub_one_failure

  # Simulate the exact rate-limit message seen in the failing run (2026-06-09)
  make_claude_stub "You've hit your limit · resets 4pm (UTC)"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "Claude rate limit: HAS_FAILURES is overridden to false in GITHUB_ENV" {
  make_gh_stub_one_failure
  make_claude_stub "You've hit your limit · resets 4pm (UTC)"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # HAS_FAILURES=false must appear after HAS_FAILURES=true so the last value wins
  true_line="$(grep -n '^HAS_FAILURES=true$' "$GITHUB_ENV" | tail -1 | cut -d: -f1)"
  false_line="$(grep -n '^HAS_FAILURES=false$' "$GITHUB_ENV" | tail -1 | cut -d: -f1)"
  [[ -n "$true_line" ]]
  [[ -n "$false_line" ]]
  (( false_line > true_line ))
}

@test "Claude 'usage limit' message also triggers rate-limit handling (exit 0)" {
  make_gh_stub_one_failure
  make_claude_stub "usage limit reached for your account"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# Non-rate-limit Claude error → exit 1, error annotation
# ---------------------------------------------------------------------------

@test "non-rate-limit Claude failure exits 1 and emits ::error:: annotation" {
  make_gh_stub_one_failure
  make_claude_stub "fatal: segmentation fault in model inference"

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# No failures → exit 0, Claude never invoked
# ---------------------------------------------------------------------------

@test "no failed runs in window exits 0 without invoking Claude" {
  make_gh_stub_no_failures

  # Claude stub that fails loudly if invoked — verifies Claude is not called
  make_claude_stub "UNEXPECTED: claude was invoked when no failures present"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED"* ]]
}
