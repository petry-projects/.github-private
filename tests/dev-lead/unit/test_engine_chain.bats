#!/usr/bin/env bats
# Unit tests for engine.sh — in-Claude model-tier fallback chain.
#
# Verifies that when the first model in a CLAUDE_*_MODEL_CHAIN hits a
# rate-limit, the next model is tried before the call gives up with exit 2
# (which triggers the outer cross-provider fallback).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  # Clear any pre-set chain vars from the runner environment so engine.sh
  # defaults are evaluated fresh for every test.
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  MODEL_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"

  export DEV_LEAD_DRY_RUN="false"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$MODEL_RECORD"
  rm -rf "$STUB_BIN_DIR"
  unset STUB_ENGINE_EXIT_BY_MODEL STUB_ENGINE_RESPONSE_BY_MODEL
  unset STUB_ENGINE_RECORD_MODELS STUB_ENGINE_EXIT STUB_ENGINE_RESPONSE
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── _claude_chain_invoke unit tests ───────────────────────────────────────────

@test "chain: first model succeeds → no fallback attempted" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0

  run _claude_chain_invoke "claude-sonnet-4-6,claude-opus-4-7" \
    "$TEST_PROMPT" 30 --allowed-tools Read

  [ "$status" -eq 0 ]
  # Only one model invocation recorded
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  ! grep -q "claude-opus-4-7" "$MODEL_RECORD"
}

@test "chain: first model rate-limited → falls through to second" {
  _source_engine "claude"
  # sonnet returns a rate-limit message with non-zero exit; opus succeeds.
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-7=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=You've hit your limit · resets 5pm (UTC)|claude-opus-4-7=opus response"

  run _claude_chain_invoke "claude-sonnet-4-6,claude-opus-4-7" \
    "$TEST_PROMPT" 30 --allowed-tools Read

  [ "$status" -eq 0 ]
  # Both models were invoked
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  grep -q "claude-opus-4-7" "$MODEL_RECORD"
  # Final output is the opus response, not the rate-limit text
  [[ "$output" == *"opus response"* ]]
  [[ "$output" != *"hit your limit"* ]]
}

@test "chain: all models rate-limited → returns exit 2" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-7=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=429 too many requests|claude-opus-4-7=429 too many requests"

  run _claude_chain_invoke "claude-sonnet-4-6,claude-opus-4-7" \
    "$TEST_PROMPT" 30 --allowed-tools Read

  [ "$status" -eq 2 ]
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  grep -q "claude-opus-4-7" "$MODEL_RECORD"
}

@test "chain: non-rate-limit failure → propagates immediately without trying next" {
  _source_engine "claude"
  # sonnet fails with a non-rate-limit error; chain must NOT advance
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-7=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=unexpected internal error|claude-opus-4-7=should not run"

  run _claude_chain_invoke "claude-sonnet-4-6,claude-opus-4-7" \
    "$TEST_PROMPT" 30 --allowed-tools Read

  [ "$status" -eq 1 ]
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  ! grep -q "claude-opus-4-7" "$MODEL_RECORD"
}

@test "chain: whitespace and empty entries are tolerated" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-7=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=rate limit exceeded|claude-opus-4-7=ok"

  run _claude_chain_invoke "  claude-sonnet-4-6 , , claude-opus-4-7 " \
    "$TEST_PROMPT" 30 --allowed-tools Read

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MODEL_RECORD")" -eq 2 ]
}

# ── End-to-end: writer uses the chain via CLAUDE_ACTION_MODEL_CHAIN ────────────

@test "writer: sonnet rate-limited → opus-4-8 tried via CLAUDE_ACTION_MODEL_CHAIN" {
  _source_engine "claude"
  # Defaults from set_engine_config: CLAUDE_ACTION_MODEL_CHAIN=sonnet,opus-4-8
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-8=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=too many requests (429)|claude-opus-4-8=opus-4-8 did the work"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
}

@test "writer: sonnet rate-limited and opus-4-8 rate-limited → exit 2 (cross-provider fallback signal)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-8=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=quota exceeded|claude-opus-4-8=quota exceeded"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: custom chain via env override is honored" {
  _source_engine "claude"
  # Override the chain so opus is tried FIRST
  export CLAUDE_ACTION_MODEL_CHAIN="claude-opus-4-7,claude-sonnet-4-6"
  export STUB_ENGINE_EXIT=0

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  head -1 "$MODEL_RECORD" | grep -q "claude-opus-4-7"
}

# ── End-to-end: agentic respects per-tier chain selection ────────────────────

@test "agentic: deep tier opus-4-8 rate-limited → sonnet tried (CLAUDE_DEEP_MODEL_CHAIN)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-4-8=1|claude-sonnet-4-6=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-4-8=service overload|claude-sonnet-4-6=deep result"

  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"

  [ "$status" -eq 0 ]
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
}

@test "agentic: audit tier fable-5 rate-limited → opus-4-8 tried (CLAUDE_AUDIT_MODEL_CHAIN)" {
  _source_engine "claude"
  # Default CLAUDE_AUDIT_MODEL_CHAIN = fable-5,opus-4-8,opus-4-7 — fable-5 is first
  export STUB_ENGINE_EXIT_BY_MODEL="claude-fable-5=1|claude-opus-4-8=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-fable-5=usage limit reached|claude-opus-4-8=audit ok"

  run run_agentic "$TEST_PROMPT" "claude-fable-5" "audit"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
}

# ── Sonnet 5 candidate wiring (#1098) ─────────────────────────────────────────
# Sonnet 5 is appended as a FALLBACK CANDIDATE after claude-sonnet-4-6 in the
# triage and deep chains (not a replacement, not the fleet default). The action
# tier is deliberately out of scope.

@test "sonnet-5 candidate: triage chain default appends claude-sonnet-5-0 after sonnet-4-6" {
  _source_engine "claude"
  [ "$CLAUDE_TRIAGE_MODEL_CHAIN" = "claude-haiku-4-5-20251001,claude-sonnet-4-6,claude-sonnet-5-0" ]
}

@test "sonnet-5 candidate: deep chain default appends claude-sonnet-5-0 after sonnet-4-6" {
  _source_engine "claude"
  [ "$CLAUDE_DEEP_MODEL_CHAIN" = "claude-opus-4-8,claude-sonnet-4-6,claude-sonnet-5-0" ]
}

@test "sonnet-5 candidate: deep opus-4-8 + sonnet-4-6 both rate-limited → claude-sonnet-5-0 reached" {
  _source_engine "claude"
  # Both existing deep models throttle; the walk must reach the new candidate.
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-4-8=1|claude-sonnet-4-6=1|claude-sonnet-5-0=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-4-8=429 too many requests|claude-sonnet-4-6=429 too many requests|claude-sonnet-5-0=sonnet 5 did the work"

  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  grep -q "claude-sonnet-5-0" "$MODEL_RECORD"
  [[ "$output" == *"sonnet 5 did the work"* ]]
}

@test "sonnet-5 candidate: action chain default is NOT touched (scope guard)" {
  _source_engine "claude"
  # Action tier is out of scope for #1098 — must stay sonnet-4-6 → opus-4-8.
  [ "$CLAUDE_ACTION_MODEL_CHAIN" = "claude-sonnet-4-6,claude-opus-4-8" ]
  [[ "$CLAUDE_ACTION_MODEL_CHAIN" != *"claude-sonnet-5"* ]]
}

# ── Gemini/Copilot unchanged: no chain applied ────────────────────────────────

@test "gemini: in-engine chain uses gemini model (not claude)" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # A gemini model was invoked (stub-gemini now records to MODEL_RECORD)
  grep -q "gemini" "$MODEL_RECORD"
  # No claude model was invoked
  ! grep -q "claude" "$MODEL_RECORD"
}

# ── File-based rate-limit + reset-time helpers ─────────────────────────────

@test "is_rate_limited_files: detects rate-limit text across multiple files" {
  _source_engine "claude"
  local f1 f2
  f1="$(mktemp)"; f2="$(mktemp)"
  echo "all good" > "$f1"
  echo "Error 429: too many requests" > "$f2"
  run is_rate_limited_files "$f1" "$f2"
  rm -f "$f1" "$f2"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited_files: returns 1 when nothing matches" {
  _source_engine "claude"
  local f1
  f1="$(mktemp)"
  echo "completed normally" > "$f1"
  run is_rate_limited_files "$f1"
  rm -f "$f1"
  [ "$status" -ne 0 ]
}

@test "is_rate_limited_files: tolerates empty/missing paths" {
  _source_engine "claude"
  # No files → no match → exit 1
  run is_rate_limited_files "" "/nonexistent/path/xyz"
  [ "$status" -ne 0 ]
}

@test "parse_reset_time_files: writes ISO timestamp from rate-limit message in file" {
  _source_engine "claude"
  local f
  f="$(mktemp)"
  echo "You've hit your limit · resets 11:20pm (UTC)" > "$f"
  rm -f /tmp/dev-lead-rate-limit-reset
  parse_reset_time_files "$f"
  rm -f "$f"
  [ -f /tmp/dev-lead-rate-limit-reset ]
  # Result should look like an ISO-8601 UTC timestamp ending in Z
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' /tmp/dev-lead-rate-limit-reset
}

@test "parse_reset_time_files: writes empty when no reset time present" {
  _source_engine "claude"
  local f
  f="$(mktemp)"
  echo "ordinary failure with no reset hint" > "$f"
  parse_reset_time_files "$f"
  rm -f "$f"
  [ -f /tmp/dev-lead-rate-limit-reset ]
  [ ! -s /tmp/dev-lead-rate-limit-reset ]
}

# ── Codex review findings: warning phrasing + config errors + model pin ─────

@test "chain: throttled warning phrase does NOT match is_rate_limited" {
  # The warning must not contain any token that _rate_limit_pattern matches —
  # otherwise downstream callers that scan our stderr (e.g. review-one-pr.sh
  # triage) would misclassify a successful chain fallback as a rate-limit.
  _source_engine "claude"
  run is_rate_limited \
    "::warning::[claude] model claude-sonnet-4-6 throttled (rc=1) — trying next in chain"
  [ "$status" -ne 0 ]
}

@test "chain: writer non-RL failure after RL attempt propagates correctly (not remapped to 2)" {
  # Model A (sonnet) rate-limited → warning emitted → 2>&1 merges into _tmp.
  # Model B (opus-4-8) fails with a non-rate-limit error. run_writer must return
  # opus-4-8's exit code, not 2, even though _tmp contains the throttled warning.
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-8=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=rate limit exceeded|claude-opus-4-8=segfault in agent runtime"

  run run_writer "$TEST_PROMPT"

  # opus-4-8's non-RL failure → exit 1 (NOT 2). If the throttled-warning text
  # matched is_rate_limited, this would incorrectly return 2.
  [ "$status" -eq 1 ]
}

@test "chain: empty/whitespace-only chain → config error (rc=1), not rate-limited (rc=2)" {
  _source_engine "claude"
  run _claude_chain_invoke "  ,  ,  " "$TEST_PROMPT" 30 --allowed-tools Read
  [ "$status" -eq 1 ]
  [[ "$output" == *"no valid model entries"* ]] || [[ "$stderr" == *"no valid model entries"* ]]
}

@test "agentic: explicit model arg differing from tier default is honored (no chain expansion)" {
  _source_engine "claude"
  # Caller pins haiku for deep tier (overriding default opus-4-8 → sonnet chain).
  # Chain expansion would record opus-4-8+sonnet; pinning must record ONLY haiku.
  export STUB_ENGINE_EXIT=0

  run run_agentic "$TEST_PROMPT" "claude-haiku-4-5-20251001" "deep"

  [ "$status" -eq 0 ]
  # Only one invocation, and it's the pinned model — not opus-4-8 or sonnet.
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "claude-haiku-4-5-20251001" "$MODEL_RECORD"
  ! grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  ! grep -q "claude-opus-4-8" "$MODEL_RECORD"
}

@test "writer: explicit model arg differing from action default is honored (no chain expansion)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0

  run run_writer "$TEST_PROMPT" "claude-haiku-4-5-20251001"

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "claude-haiku-4-5-20251001" "$MODEL_RECORD"
  ! grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
  ! grep -q "claude-opus-4-8" "$MODEL_RECORD"
}

@test "agentic: passing tier default model still expands to full chain on rate-limit" {
  # Regression guard for the pin-check above: when caller passes the tier
  # default (opus-4-8), chain expansion still works (opus-4-8 → sonnet fallback).
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-4-8=1|claude-sonnet-4-6=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-4-8=429 too many|claude-sonnet-4-6=ok"

  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
}
