#!/usr/bin/env bats
# Unit tests for engine.sh — new Claude model tier assignments and chains.
#
# Verifies that Fable 5 (claude-fable-5) and Opus 4.8 (claude-opus-4-8) are
# wired into the correct tiers and fallback chains for the claude engine:
#   triage  → haiku-4-5    (unchanged)
#   action  → sonnet-4-6   (unchanged)
#   deep    → opus-4-8     (was sonnet-4-6)
#   audit   → fable-5      (was opus-4-7)
#   single  → fable-5      (was opus-4-7)

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
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# ── Tier default model assignments ───────────────────────────────────────────

@test "new-models: ENGINE_AUDIT_MODEL is claude-fable-5 for claude engine" {
  _source_engine "claude"
  [ "$ENGINE_AUDIT_MODEL" = "claude-fable-5" ]
}

@test "new-models: ENGINE_SINGLE_MODEL is claude-fable-5 for claude engine" {
  _source_engine "claude"
  [ "$ENGINE_SINGLE_MODEL" = "claude-fable-5" ]
}

@test "new-models: ENGINE_DEEP_MODEL is claude-opus-4-8 for claude engine" {
  _source_engine "claude"
  [ "$ENGINE_DEEP_MODEL" = "claude-opus-4-8" ]
}

@test "new-models: ENGINE_ACTION_MODEL still claude-sonnet-4-6 (unchanged)" {
  _source_engine "claude"
  [ "$ENGINE_ACTION_MODEL" = "claude-sonnet-4-6" ]
}

@test "new-models: ENGINE_TRIAGE_MODEL still claude-haiku-4-5-20251001 (unchanged)" {
  _source_engine "claude"
  [ "$ENGINE_TRIAGE_MODEL" = "claude-haiku-4-5-20251001" ]
}

# ── Fallback chain configuration ──────────────────────────────────────────────

@test "new-models: CLAUDE_AUDIT_MODEL_CHAIN starts with claude-fable-5" {
  _source_engine "claude"
  local first
  first="${CLAUDE_AUDIT_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "claude-fable-5" ]
}

@test "new-models: CLAUDE_AUDIT_MODEL_CHAIN includes claude-opus-4-8 as second element" {
  _source_engine "claude"
  local second
  second="${CLAUDE_AUDIT_MODEL_CHAIN#*,}"
  second="${second%%,*}"
  second="${second// /}"
  [ "$second" = "claude-opus-4-8" ]
}

@test "new-models: CLAUDE_AUDIT_MODEL_CHAIN includes claude-opus-4-7 as final fallback" {
  _source_engine "claude"
  [[ "$CLAUDE_AUDIT_MODEL_CHAIN" == *"claude-opus-4-7"* ]]
}

@test "new-models: CLAUDE_SINGLE_MODEL_CHAIN starts with claude-fable-5" {
  _source_engine "claude"
  local first
  first="${CLAUDE_SINGLE_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "claude-fable-5" ]
}

@test "new-models: CLAUDE_SINGLE_MODEL_CHAIN includes claude-opus-4-8 as second element" {
  _source_engine "claude"
  local second
  second="${CLAUDE_SINGLE_MODEL_CHAIN#*,}"
  second="${second%%,*}"
  second="${second// /}"
  [ "$second" = "claude-opus-4-8" ]
}

@test "new-models: CLAUDE_DEEP_MODEL_CHAIN starts with claude-opus-4-8" {
  _source_engine "claude"
  local first
  first="${CLAUDE_DEEP_MODEL_CHAIN%%,*}"
  first="${first// /}"
  [ "$first" = "claude-opus-4-8" ]
}

@test "new-models: CLAUDE_ACTION_MODEL_CHAIN second element is claude-opus-4-8 (not opus-4-7)" {
  _source_engine "claude"
  local second
  second="${CLAUDE_ACTION_MODEL_CHAIN#*,}"
  second="${second%%,*}"
  second="${second// /}"
  [ "$second" = "claude-opus-4-8" ]
  [[ "$second" != *"opus-4-7"* ]]
}

# ── Intent dispatch returns new tier defaults ─────────────────────────────────

@test "new-models: model_for_intent(fix-issue) returns claude-opus-4-8" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-issue")"
  [ "$result" = "claude-opus-4-8" ]
}

@test "new-models: model_for_intent(human) returns claude-opus-4-8" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "human")"
  [ "$result" = "claude-opus-4-8" ]
}

@test "new-models: model_for_intent(fix-reviews) still returns claude-sonnet-4-6" {
  _source_engine "claude"
  local result
  result="$(model_for_intent "fix-reviews")"
  [ "$result" = "claude-sonnet-4-6" ]
}

# ── Chain fallback behaviour with new models ──────────────────────────────────

@test "new-models: audit fable-5 rate-limited → opus-4-8 tried" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-fable-5=1|claude-opus-4-8=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-fable-5=hit your limit|claude-opus-4-8=audit ok"

  run run_agentic "$TEST_PROMPT" "claude-fable-5" "audit"

  [ "$status" -eq 0 ]
  grep -q "claude-fable-5" "$MODEL_RECORD"
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  [[ "$output" == *"audit ok"* ]]
  [[ "$output" != *"hit your limit"* ]]
}

@test "new-models: audit chain fully exhausted → exit 2" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-fable-5=1|claude-opus-4-8=1|claude-opus-4-7=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-fable-5=429 too many|claude-opus-4-8=429 too many|claude-opus-4-7=429 too many"

  run run_agentic "$TEST_PROMPT" "claude-fable-5" "audit"

  [ "$status" -eq 2 ]
}

@test "new-models: deep opus-4-8 rate-limited → sonnet-4-6 tried" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-4-8=1|claude-sonnet-4-6=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-4-8=quota exceeded|claude-sonnet-4-6=deep result ok"

  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
}

@test "new-models: action chain sonnet rate-limited → opus-4-8 tried (not opus-4-7)" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-sonnet-4-6=1|claude-opus-4-8=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-sonnet-4-6=too many requests|claude-opus-4-8=action done"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  ! grep -q "claude-opus-4-7" "$MODEL_RECORD"
}

@test "new-models: passing tier default opus-4-8 expands to full deep chain on rate-limit" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT_BY_MODEL="claude-opus-4-8=1|claude-sonnet-4-6=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="claude-opus-4-8=429 too many|claude-sonnet-4-6=ok"

  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"

  [ "$status" -eq 0 ]
  grep -q "claude-opus-4-8" "$MODEL_RECORD"
  grep -q "claude-sonnet-4-6" "$MODEL_RECORD"
}

# ── Non-claude engines unaffected ─────────────────────────────────────────────

@test "new-models: gemini engine unchanged — no claude model in any tier" {
  _source_engine "gemini"
  [[ "$ENGINE_AUDIT_MODEL" != *"claude"* ]]
  [[ "$ENGINE_DEEP_MODEL" != *"claude"* ]]
  [[ "$ENGINE_SINGLE_MODEL" != *"claude"* ]]
}

@test "new-models: copilot engine unchanged — all tiers still o4-mini" {
  _source_engine "copilot"
  [ "$ENGINE_AUDIT_MODEL" = "o4-mini" ]
  [ "$ENGINE_SINGLE_MODEL" = "o4-mini" ]
  [ "$ENGINE_DEEP_MODEL" = "o4-mini" ]
}
