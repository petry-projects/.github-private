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

# ---------------------------------------------------------------------------
# Regression: single-review.md must instruct the model to write to $OUTPUT_FILE
# (not to stdout).  When TOKEN_LOG_FILE is set, engine.sh adds --output-format
# json, which causes the model's Bash tool echoes to NOT appear in the `result`
# field — only text the model emits as its final message does.  If the prompt
# says "output to stdout", the model's Bash echo goes to tool output (not
# result), result stays "", and extract_verdict_json never sees the review JSON.
# Fix: the prompt must use `jq > "$OUTPUT_FILE"` like cascade-action.md does.
# ---------------------------------------------------------------------------

@test "single-review prompt: instructs model to write to OUTPUT_FILE (not stdout)" {
  local prompt_file
  prompt_file="$(dirname "$BATS_TEST_FILENAME")/../prompts/single-review.md"

  # The Output section must reference OUTPUT_FILE so the model writes there.
  run grep -c 'OUTPUT_FILE' "$prompt_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "single-review prompt: does NOT instruct model to output to stdout" {
  local prompt_file
  prompt_file="$(dirname "$BATS_TEST_FILENAME")/../prompts/single-review.md"

  # The old (broken) instruction said "Output ONLY valid JSON to stdout".
  # After the fix, this phrase must be absent.
  run grep -c 'Output ONLY valid JSON to stdout' "$prompt_file"
  [ "$output" -eq 0 ]
}

@test "single-review prompt: instructs model NOT to print JSON to stdout" {
  local prompt_file
  prompt_file="$(dirname "$BATS_TEST_FILENAME")/../prompts/single-review.md"

  # The fixed prompt must include the same guard present in cascade-action.md.
  run grep -c 'Do NOT print' "$prompt_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# extract_verdict_json: Style 1 (model wrote to dest/OUTPUT_FILE directly)
# must be preferred over Style 2 (raw contains claude API wrapper).
# This is the correct post-fix path: model writes via jq to $OUTPUT_FILE.
# ---------------------------------------------------------------------------

@test "extract_verdict_json: dest has review JSON → decision extracted (Style 1)" {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh" >/dev/null 2>&1 || true

  local raw dest
  raw="$(mktemp)"
  dest="$(mktemp)"

  # raw = claude API wrapper (what _claude_chain_invoke emits when result="")
  printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":false,"result":"","stop_reason":"end_turn"}' \
    > "$raw"

  # dest = review JSON written by the model via jq > "$OUTPUT_FILE"
  printf '%s\n' \
    '{"pr":"https://github.com/org/repo/pull/1","sha":"abc","risk":"LOW","decision":"approve","mode":"triage-approved","summary":"ok","body":"..."}' \
    > "$dest"

  extract_verdict_json "$raw" "$dest"
  local decision
  decision="$(jq -r '.decision // ""' "$dest")"
  [ "$decision" = "approve" ]

  rm -f "$raw" "$dest"
}

# ---------------------------------------------------------------------------
# Regression: engine.sh must NOT tee Copilot stdout into OUTPUT_FILE.
# The model writes verdict JSON directly via the Bash tool; teeing stdout
# (which includes assistant text and tool transcripts) would corrupt it.
# ---------------------------------------------------------------------------

@test "engine.sh: run_agentic copilot branch does not tee stdout to OUTPUT_FILE" {
  local engine_file
  engine_file="$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh"

  # The run_agentic copilot branch must not contain `tee.*OUTPUT_FILE`.
  # We extract only the copilot) block of run_agentic and check it is clean.
  run grep -En '^[[:space:]]*[^[:space:]#].*(tee.*OUTPUT_FILE|OUTPUT_FILE.*tee)' "$engine_file"
  [ "$output" = "" ]
}

@test "extract_verdict_json: raw=claude-API-wrapper, dest missing → decision empty (bug scenario)" {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh" >/dev/null 2>&1 || true

  local raw dest
  raw="$(mktemp)"
  dest="$(mktemp)"
  rm -f "$dest"  # simulate model never writing to OUTPUT_FILE

  # raw = claude API wrapper with empty result (the pre-fix failure mode)
  printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":false,"result":"","stop_reason":"end_turn"}' \
    > "$raw"

  extract_verdict_json "$raw" "$dest"
  local decision
  decision="$(jq -r '.decision // ""' "$dest" 2>/dev/null || true)"
  # The bug: decision is empty because the claude API wrapper has no decision field
  [ "$decision" = "" ]

  rm -f "$raw" "$dest"
}
