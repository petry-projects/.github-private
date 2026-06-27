#!/usr/bin/env bats
# Unit tests for engine.sh — gated LSP-pilot stream-json capture (issue #960,
# story #844, epic #839).
#
# When the pilot recording flag (LSP_PILOT_ENABLED=true) is on AND a capturing
# tier runs (deep/audit/single via run_agentic, or run_duck), the claude call
# must switch from `--output-format json` to `--output-format stream-json
# --verbose` and append the raw transcript to a per-call file under
# LSP_PILOT_STREAM_DIR — while still recording real token usage (parsed from the
# stream's terminal `result` event). When the flag is OFF, behaviour is
# byte-for-byte unchanged: `--output-format json`, no stream capture. The triage
# and action tiers never capture, even with the flag on.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS REVIEW_MCP_CONFIG_DEFAULT_PATH REVIEW_MCP_DEBUG
  unset LSP_PILOT_ENABLED LSP_PILOT_STREAM_DIR

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  chmod +x "$STUB_BIN_DIR/claude"
  export PATH="$STUB_BIN_DIR:$PATH"

  TEST_PROMPT="$(mktemp)"; echo "test prompt content" > "$TEST_PROMPT"
  ARGS_RECORD="$(mktemp)"; export STUB_ENGINE_RECORD_ARGS="$ARGS_RECORD"
  TOKEN_LOG="$(mktemp)"; : > "$TOKEN_LOG"
  STREAM_DIR="$(mktemp -d)"

  export DEV_LEAD_DRY_RUN="false" STUB_ENGINE_EXIT=0
}

teardown() {
  rm -f "$GITHUB_ENV" "$TEST_PROMPT" "$ARGS_RECORD" "$TOKEN_LOG"
  rm -rf "$STUB_BIN_DIR" "$STREAM_DIR"
  unset STUB_ENGINE_RECORD_ARGS STUB_ENGINE_EXIT LSP_PILOT_ENABLED LSP_PILOT_STREAM_DIR
}

_source_engine() {
  export REVIEW_ENGINE="claude"
  source "$ENGINE_SCRIPT"
}

# ── Pilot OFF: byte-for-byte unchanged ───────────────────────────────────────

@test "off-pilot: deep tier + token log → --output-format json, no stream-json, no capture" {
  _source_engine
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_STREAM_DIR="$STREAM_DIR"   # set, but flag is off → ignored
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--output-format json" "$ARGS_RECORD"
  ! grep -q -- "stream-json" "$ARGS_RECORD"
  # No transcript captured when the pilot flag is off.
  [ -z "$(ls -A "$STREAM_DIR")" ]
}

@test "off-pilot: no TOKEN_LOG_FILE → no output-format flag at all (legacy text path)" {
  _source_engine
  unset TOKEN_LOG_FILE
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--output-format" "$ARGS_RECORD"
}

# ── Pilot ON: capturing tiers switch to stream-json + write a transcript ──────

@test "pilot deep: stream-json --verbose threaded, transcript captured, usage still recorded" {
  _source_engine
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_ENABLED=true
  export LSP_PILOT_STREAM_DIR="$STREAM_DIR"
  export STUB_ENGINE_RESPONSE="pilot deep response"
  export STUB_CLAUDE_USAGE="1500 400 0 90"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  [ "$output" = "pilot deep response" ]
  grep -q -- "--output-format stream-json --verbose" "$ARGS_RECORD"
  ! grep -q -- "--output-format json" "$ARGS_RECORD"
  # A per-call transcript file was written under the stream dir.
  [ -n "$(ls -A "$STREAM_DIR")" ]
  # Real usage parsed from the stream's result event lands in the token record.
  run jq -r 'select(.tier=="deep") | .input_tokens' "$TOKEN_LOG"
  [ "$output" = "1500" ]
}

@test "pilot duck: stream-json --verbose threaded and transcript captured" {
  _source_engine
  export DUCK_ENGINE="claude"
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_ENABLED=true
  export LSP_PILOT_STREAM_DIR="$STREAM_DIR"
  run run_duck "$TEST_PROMPT" "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  grep -q -- "--output-format stream-json --verbose" "$ARGS_RECORD"
  [ -n "$(ls -A "$STREAM_DIR")" ]
  # The duck's existing --max-turns flag must survive.
  grep -q -- "--max-turns 25" "$ARGS_RECORD"
}

@test "pilot audit: capturing tier switches to stream-json" {
  _source_engine
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_ENABLED=true
  export LSP_PILOT_STREAM_DIR="$STREAM_DIR"
  run run_agentic "$TEST_PROMPT" "claude-fable-5" "audit"
  [ "$status" -eq 0 ]
  grep -q -- "--output-format stream-json --verbose" "$ARGS_RECORD"
  [ -n "$(ls -A "$STREAM_DIR")" ]
}

@test "pilot single: capturing tier switches to stream-json" {
  _source_engine
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_ENABLED=true
  export LSP_PILOT_STREAM_DIR="$STREAM_DIR"
  run run_agentic "$TEST_PROMPT" "claude-sonnet-4-6" "single"
  [ "$status" -eq 0 ]
  grep -q -- "--output-format stream-json --verbose" "$ARGS_RECORD"
  [ -n "$(ls -A "$STREAM_DIR")" ]
}

# ── Pilot ON but non-capturing tiers stay on the unchanged path ──────────────

@test "pilot triage: never captures (no stream-json, no transcript)" {
  _source_engine
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_ENABLED=true
  export LSP_PILOT_STREAM_DIR="$STREAM_DIR"
  run run_triage "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  ! grep -q -- "stream-json" "$ARGS_RECORD"
  [ -z "$(ls -A "$STREAM_DIR")" ]
}

@test "pilot action: writer/synthesis tier never captures (out of pilot scope)" {
  _source_engine
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_ENABLED=true
  export LSP_PILOT_STREAM_DIR="$STREAM_DIR"
  run run_agentic "$TEST_PROMPT" "claude-sonnet-4-6" "action"
  [ "$status" -eq 0 ]
  ! grep -q -- "stream-json" "$ARGS_RECORD"
  [ -z "$(ls -A "$STREAM_DIR")" ]
}

@test "pilot deep but stream dir unset → stream-json still chosen, no crash" {
  _source_engine
  export TOKEN_LOG_FILE="$TOKEN_LOG"
  export LSP_PILOT_ENABLED=true
  unset LSP_PILOT_STREAM_DIR
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--output-format stream-json --verbose" "$ARGS_RECORD"
}
