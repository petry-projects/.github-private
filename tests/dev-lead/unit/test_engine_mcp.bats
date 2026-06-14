#!/usr/bin/env bats
# Unit tests for engine.sh — opt-in MCP config threading (issue #677).
#
# Verifies that REVIEW_MCP_CONFIG / REVIEW_MCP_ALLOWED_TOOLS thread the MCP
# flags (--mcp-config <file> --strict-mcp-config) and merged --allowed-tools
# into ONLY the claude branch of the agentic (run_agentic) and rubber-duck
# (run_duck) tiers — never the triage tier — and that the default (knob unset)
# behavior is byte-for-byte unchanged.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  ARGS_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_ARGS="$ARGS_RECORD"

  # A readable MCP config file the helper can point at.
  MCP_CONFIG_FILE="$(mktemp)"
  echo '{"mcpServers":{}}' > "$MCP_CONFIG_FILE"
  export MCP_CONFIG_FILE

  export DEV_LEAD_DRY_RUN="false"
  export STUB_ENGINE_EXIT=0
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$ARGS_RECORD" "$MCP_CONFIG_FILE"
  rm -rf "$STUB_BIN_DIR"
  unset STUB_ENGINE_RECORD_ARGS STUB_ENGINE_EXIT
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── Default (knob unset): behavior unchanged ──────────────────────────────────

@test "agentic: no MCP knob → no MCP flags, default allowed-tools unchanged" {
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
  ! grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

@test "agentic: empty REVIEW_MCP_CONFIG → no MCP flags" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG=""
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
}

@test "agentic: REVIEW_MCP_CONFIG pointing to unreadable file → no MCP flags" {
  _source_engine "claude"
  local unreadable_file
  unreadable_file="$(mktemp)"
  chmod 000 "$unreadable_file"
  export REVIEW_MCP_CONFIG="$unreadable_file"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  chmod 600 "$unreadable_file"
  rm -f "$unreadable_file"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

@test "agentic: REVIEW_MCP_CONFIG pointing to a directory → no MCP flags" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$(mktemp -d)"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  rmdir "$REVIEW_MCP_CONFIG"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

# ── Knob set: MCP flags threaded into agentic ────────────────────────────────

@test "agentic: REVIEW_MCP_CONFIG set → MCP flags appended to claude call" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--mcp-config $MCP_CONFIG_FILE" "$ARGS_RECORD"
  grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
}

@test "agentic: REVIEW_MCP_ALLOWED_TOOLS merged into --allowed-tools" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob,mcp__context7__\*" "$ARGS_RECORD"
}

@test "agentic: MCP config set but no allowed-tools knob → base allowed-tools kept" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
  ! grep -q -- "--allowed-tools Bash,Read,Grep,Glob," "$ARGS_RECORD"
}

# ── Knob set: MCP flags threaded into duck ───────────────────────────────────

@test "duck: REVIEW_MCP_CONFIG set → MCP flags appended to claude duck call" {
  _source_engine "claude"
  export DUCK_ENGINE="claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  run run_duck "$TEST_PROMPT" "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  grep -q -- "--mcp-config $MCP_CONFIG_FILE" "$ARGS_RECORD"
  grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob,mcp__context7__\*" "$ARGS_RECORD"
  # The duck tier's existing --max-turns flag must still be present.
  grep -q -- "--max-turns 25" "$ARGS_RECORD"
}

@test "duck: no MCP knob → no MCP flags on claude duck call" {
  _source_engine "claude"
  export DUCK_ENGINE="claude"
  run run_duck "$TEST_PROMPT" "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

# ── Triage tier: never gets MCP flags ────────────────────────────────────────

@test "triage: MCP knob set → triage still uses --disallowed-tools only, no MCP" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  run run_triage "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
  ! grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
  ! grep -q -- "--allowed-tools" "$ARGS_RECORD"
  grep -q -- "--disallowed-tools" "$ARGS_RECORD"
}

# ── Graceful degradation: warn (never fake) on MCP server failure (issue #678) ─
# The claude CLI surfaces an MCP connection/init failure in its captured output
# but still exits 0 and produces a verdict. engine.sh must warn (naming the
# server) and let the review complete — no fatal exit, no fabricated "all clear".

@test "agentic: MCP failure marker + knob set → ::warning:: names server, verdict still emitted" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE=$'MCP server "context7" failed to connect after 3 attempts\n{"decision":"approve","summary":"looks good"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  # AC #2: never a fatal exit on MCP failure.
  [ "$status" -eq 0 ]
  # AC #1: a warning is emitted naming the affected server.
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"mcp"* ]]
  [[ "$output" == *"context7"* ]]
  # AC #1/#2: the review still returns its normal, non-empty verdict.
  [[ "$output" == *'"decision":"approve"'* ]]
}

@test "agentic: MCP failure marker but knob UNSET → no MCP warning (AC #3)" {
  _source_engine "claude"
  unset REVIEW_MCP_CONFIG
  export STUB_ENGINE_RESPONSE=$'MCP server "context7" failed to connect after 3 attempts\n{"decision":"approve","summary":"looks good"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  # No MCP-related warning when MCP was never configured.
  ! [[ "$output" == *"::warning::[mcp]"* ]]
  # Verdict still flows through untouched.
  [[ "$output" == *'"decision":"approve"'* ]]
}

@test "agentic: knob set but no MCP failure in output → no false-positive warning" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE='{"decision":"approve","summary":"clean run, MCP healthy"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"::warning::[mcp]"* ]]
  [[ "$output" == *'"decision":"approve"'* ]]
}

@test "agentic: MCP failure without quoted server name + knob set → generic warning, review continues" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE=$'Failed to connect to MCP server\n{"decision":"comment","summary":"degraded"}'
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::[mcp]"* ]]
  [[ "$output" == *'"decision":"comment"'* ]]
}

@test "duck: MCP failure marker + knob set → ::warning:: emitted, duck verdict continues" {
  _source_engine "claude"
  export DUCK_ENGINE="claude"
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export STUB_ENGINE_RESPONSE=$'MCP server "context7" failed to connect\n{"decision":"approve","summary":"duck ok"}'
  run run_duck "$TEST_PROMPT" "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::[mcp]"* ]]
  [[ "$output" == *"context7"* ]]
  [[ "$output" == *'"decision":"approve"'* ]]
}
