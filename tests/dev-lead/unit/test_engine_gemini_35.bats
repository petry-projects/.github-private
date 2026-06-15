#!/usr/bin/env bats
# Unit tests for engine.sh — Gemini 3.5 model tier assignments, chains, and fallback.
#
# Verifies that gemini-3.5-flash is wired into the speed-first tiers and
# gemini-2.5-pro remains the quality-first tier for the gemini engine:
#   triage  → gemini-3.5-flash  (was gemini-2.0-flash)
#   action  → gemini-3.5-flash  (was gemini-2.5-pro)
#   deep    → gemini-2.5-pro    (unchanged)
#   audit   → gemini-2.5-pro    (unchanged)
#   single  → gemini-2.5-pro    (unchanged)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL
  unset GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/gemini"
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
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL
  unset GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset STUB_ENGINE_EXIT_BY_MODEL STUB_ENGINE_RESPONSE_BY_MODEL
  unset STUB_ENGINE_RECORD_MODELS STUB_ENGINE_EXIT STUB_ENGINE_RESPONSE
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# ── Tier default model assignments ───────────────────────────────────────────

@test "gemini-3.5: ENGINE_TRIAGE_MODEL is gemini-3.5-flash by default" {
  _source_engine "gemini"
  [ "$ENGINE_TRIAGE_MODEL" = "gemini-3.5-flash" ]
}

@test "gemini-3.5: ENGINE_ACTION_MODEL is gemini-3.5-flash by default" {
  _source_engine "gemini"
  [ "$ENGINE_ACTION_MODEL" = "gemini-3.5-flash" ]
}

@test "gemini-3.5: ENGINE_DEEP_MODEL is gemini-2.5-pro (quality tier unchanged)" {
  _source_engine "gemini"
  [ "$ENGINE_DEEP_MODEL" = "gemini-2.5-pro" ]
}

@test "gemini-3.5: ENGINE_AUDIT_MODEL is gemini-2.5-pro (quality tier unchanged)" {
  _source_engine "gemini"
  [ "$ENGINE_AUDIT_MODEL" = "gemini-2.5-pro" ]
}

@test "gemini-3.5: ENGINE_SINGLE_MODEL is gemini-2.5-pro (quality tier unchanged)" {
  _source_engine "gemini"
  [ "$ENGINE_SINGLE_MODEL" = "gemini-2.5-pro" ]
}

# ── Fallback chain configuration ──────────────────────────────────────────────

@test "gemini-3.5: GEMINI_FLASH_MODEL_CHAIN starts with gemini-3.5-flash" {
  _source_engine "gemini"
  local first
  first="${GEMINI_FLASH_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "gemini-3.5-flash" ]
}

@test "gemini-3.5: GEMINI_FLASH_MODEL_CHAIN includes gemini-2.5-pro as fallback" {
  _source_engine "gemini"
  [[ "$GEMINI_FLASH_MODEL_CHAIN" == *"gemini-2.5-pro"* ]]
}

@test "gemini-3.5: GEMINI_PRO_MODEL_CHAIN starts with gemini-2.5-pro" {
  _source_engine "gemini"
  local first
  first="${GEMINI_PRO_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "gemini-2.5-pro" ]
}

@test "gemini-3.5: GEMINI_PRO_MODEL_CHAIN includes gemini-2.0-flash as fallback" {
  _source_engine "gemini"
  [[ "$GEMINI_PRO_MODEL_CHAIN" == *"gemini-2.0-flash"* ]]
}

# ── Env var overrides ─────────────────────────────────────────────────────────

@test "gemini-3.5: GEMINI_FLASH_MODEL env var overrides triage model" {
  export GEMINI_FLASH_MODEL="gemini-2.0-flash"
  _source_engine "gemini"
  [ "$ENGINE_TRIAGE_MODEL" = "gemini-2.0-flash" ]
  [ "$ENGINE_ACTION_MODEL" = "gemini-2.0-flash" ]
}

@test "gemini-3.5: GEMINI_PRO_MODEL env var overrides deep model" {
  export GEMINI_PRO_MODEL="gemini-2.0-flash"
  _source_engine "gemini"
  [ "$ENGINE_DEEP_MODEL" = "gemini-2.0-flash" ]
  [ "$ENGINE_AUDIT_MODEL" = "gemini-2.0-flash" ]
}

@test "gemini-3.5: GEMINI_FLASH_MODEL_CHAIN env var override honored" {
  export GEMINI_FLASH_MODEL_CHAIN="gemini-2.0-flash,gemini-2.5-pro"
  _source_engine "gemini"
  local first
  first="${GEMINI_FLASH_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "gemini-2.0-flash" ]
}

# ── Intent dispatch returns correct tier models ───────────────────────────────

@test "gemini-3.5: model_for_intent(human-pr) returns gemini-3.5-flash (triage)" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "human-pr")"
  [ "$result" = "gemini-3.5-flash" ]
}

@test "gemini-3.5: model_for_intent(fix-reviews) returns gemini-3.5-flash (action)" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "fix-reviews")"
  [ "$result" = "gemini-3.5-flash" ]
}

@test "gemini-3.5: model_for_intent(fix-issue) returns gemini-2.5-pro (deep)" {
  _source_engine "gemini"
  local result
  result="$(model_for_intent "fix-issue")"
  [ "$result" = "gemini-2.5-pro" ]
}

# ── ENGINE_LABEL reflects new models ─────────────────────────────────────────

@test "gemini-3.5: ENGINE_LABEL contains gemini-3.5-flash" {
  _source_engine "gemini"
  [[ "$ENGINE_LABEL" == *"gemini-3.5-flash"* ]]
}

# ── Copilot engine duck uses gemini-3.5-flash ────────────────────────────────

@test "gemini-3.5: copilot engine duck model is gemini-3.5-flash" {
  _source_engine "copilot"
  [ "$DUCK_ENGINE" = "gemini" ]
  [ "$DUCK_MODEL" = "gemini-3.5-flash" ]
}

# ── _gemini_chain_invoke unit tests ───────────────────────────────────────────

@test "gemini-3.5 chain: first model succeeds → no fallback attempted" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  ! grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini-3.5 chain: first model rate-limited → falls through to second" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=pro response"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
  [[ "$output" == *"pro response"* ]]
  [[ "$output" != *"too many requests"* ]]
}

@test "gemini-3.5 chain: all models rate-limited → returns exit 2" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded|gemini-2.5-pro=quota exceeded"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 2 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini-3.5 chain: non-rate-limit failure propagates immediately without trying next" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=unexpected internal error|gemini-2.5-pro=should not run"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 1 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  ! grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini-3.5 chain: empty chain → config error (rc=1)" {
  _source_engine "gemini"
  run _gemini_chain_invoke "  ,  ,  " "$TEST_PROMPT" 30 --approval-mode auto_edit
  [ "$status" -eq 1 ]
}

@test "gemini-3.5 chain: throttled warning phrase does NOT match is_rate_limited" {
  _source_engine "gemini"
  run is_rate_limited \
    "::warning::[gemini] model gemini-3.5-flash throttled (rc=1) — trying next in chain"
  [ "$status" -ne 0 ]
}

# ── End-to-end: run_writer uses flash chain on rate-limit ────────────────────

@test "gemini-3.5 writer: gemini-3.5-flash rate-limited → gemini-2.5-pro tried via GEMINI_FLASH_MODEL_CHAIN" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=too many requests (429)|gemini-2.5-pro=pro result"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini-3.5 writer: custom GEMINI_FLASH_MODEL_CHAIN env override is honored" {
  _source_engine "gemini"
  export GEMINI_FLASH_MODEL_CHAIN="gemini-2.0-flash,gemini-3.5-flash"
  export STUB_ENGINE_EXIT=0

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  head -1 "$MODEL_RECORD" | grep -q "gemini-2.0-flash"
}

@test "gemini-3.5 writer: both models rate-limited → exit 2 (cross-provider fallback signal)" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded|gemini-2.5-pro=quota exceeded"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

# ── Non-gemini engines unaffected ────────────────────────────────────────────

@test "gemini-3.5: claude engine unchanged — no gemini model in any tier" {
  _source_engine "claude"
  [[ "$ENGINE_TRIAGE_MODEL" != *"gemini"* ]]
  [[ "$ENGINE_DEEP_MODEL" != *"gemini"* ]]
  [[ "$ENGINE_AUDIT_MODEL" != *"gemini"* ]]
}

@test "gemini-3.5: copilot engine unchanged — all tiers still o4-mini" {
  _source_engine "copilot"
  [ "$ENGINE_AUDIT_MODEL" = "o4-mini" ]
  [ "$ENGINE_TRIAGE_MODEL" = "o4-mini" ]
  [ "$ENGINE_DEEP_MODEL" = "o4-mini" ]
}
