#!/usr/bin/env bats
# Unit tests for the LSP-MCP pilot wiring (epic #839, story #842).
#
# This pilot reuses the MCP plumbing that already shipped (#677/#678/#679 — see
# tests/dev-lead/unit/test_engine_mcp.bats). These tests cover only what #842
# adds on top of it:
#   AC #1 — a committed, candidate-switchable MCP config (.github/mcp/lsp.json)
#           that engine.sh threads into deep/duck only (triage untouched).
#   AC #2 — runner setup (scripts/setup-lsp-pilot.sh) installs the pinned tools
#           and degrades gracefully (warning + skip) when a tool is absent.
#   AC #3 — only a small (8-12) read-only navigation tool set is exposed.
#   AC #4 — with the LSP config NOT referenced by REVIEW_MCP_CONFIG, the review
#           is byte-for-byte unchanged (no LSP MCP flags threaded).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
LSP_CONFIG="$SCRIPT_DIR/.github/mcp/lsp.json"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup-lsp-pilot.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS REVIEW_MCP_CONFIG_DEFAULT_PATH

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

  export DEV_LEAD_DRY_RUN="false"
  export STUB_ENGINE_EXIT=0
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$ARGS_RECORD"
  rm -rf "$STUB_BIN_DIR"
  unset STUB_ENGINE_RECORD_ARGS STUB_ENGINE_EXIT
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS REVIEW_MCP_CONFIG_DEFAULT_PATH
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── AC #1: the committed config is a valid, correctly-shaped LSP MCP config ────

@test "config: .github/mcp/lsp.json exists and is valid JSON" {
  [ -f "$LSP_CONFIG" ]
  run jq empty "$LSP_CONFIG"
  [ "$status" -eq 0 ]
}

@test "config: declares an 'lsp' stdio server launched via the agent-lsp binary" {
  run jq -e '.mcpServers.lsp.type == "stdio"' "$LSP_CONFIG"
  [ "$status" -eq 0 ]
  run jq -r '.mcpServers.lsp.command' "$LSP_CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "agent-lsp" ]
}

@test "config: drives bash-language-server (the pilot's Shell language server)" {
  run jq -e '[.mcpServers.lsp.args[]] | any(test("bash-language-server"))' "$LSP_CONFIG"
  [ "$status" -eq 0 ]
}

@test "config: carries no auth headers/secret (stdio binary, no smuggled token)" {
  run jq -e '.mcpServers.lsp | has("headers") | not' "$LSP_CONFIG"
  [ "$status" -eq 0 ]
}

# ── AC #3: only a small (8-12) read-only navigation tool set is exposed ───────

@test "allowed-tools: setup script prints the canonical navigation allowlist" {
  run bash "$SETUP_SCRIPT" print-allowed-tools
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Every entry must be an lsp MCP tool.
  run bash -c "bash '$SETUP_SCRIPT' print-allowed-tools | tr ',' '\n' | grep -vc '^mcp__lsp__'"
  [ "$output" = "0" ]
}

@test "allowed-tools: navigation set is 8-12 tools (token-overhead bound)" {
  local count
  count="$(bash "$SETUP_SCRIPT" print-allowed-tools | tr ',' '\n' | grep -c .)"
  [ "$count" -ge 8 ]
  [ "$count" -le 12 ]
}

@test "allowed-tools: navigation set is read-only — no editing/refactor tools" {
  # Finding-verification is read-only (references/diagnostics/hover/symbols).
  # No mutating tools (rename/apply_edit/insert/delete/format/execute_command).
  run bash -c "bash '$SETUP_SCRIPT' print-allowed-tools | grep -Eic 'rename|apply_edit|insert_|safe_delete|replace_symbol|format_|execute_command'"
  [ "$output" = "0" ]
}

@test "allowed-tools: includes the in-scope find-references and diagnostics tools" {
  run bash "$SETUP_SCRIPT" print-allowed-tools
  [[ "$output" == *"mcp__lsp__find_references"* ]]
  [[ "$output" == *"mcp__lsp__get_diagnostics"* ]]
}

# ── AC #1: engine threads the lsp config into deep/duck, never triage ─────────

@test "engine: lsp config referenced → deep tier threads its MCP flags" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$LSP_CONFIG"
  export REVIEW_MCP_ALLOWED_TOOLS="$(bash "$SETUP_SCRIPT" print-allowed-tools)"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  grep -q -- "--mcp-config $LSP_CONFIG" "$ARGS_RECORD"
  grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
  grep -q -- "mcp__lsp__find_references" "$ARGS_RECORD"
}

@test "engine: lsp config referenced → triage tier still gets NO MCP flags" {
  _source_engine "claude"
  export REVIEW_MCP_CONFIG="$LSP_CONFIG"
  export REVIEW_MCP_ALLOWED_TOOLS="$(bash "$SETUP_SCRIPT" print-allowed-tools)"
  run run_triage "$TEST_PROMPT"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
  ! grep -q -- "--strict-mcp-config" "$ARGS_RECORD"
  ! grep -q -- "--allowed-tools" "$ARGS_RECORD"
  grep -q -- "--disallowed-tools" "$ARGS_RECORD"
}

# ── AC #4: committing lsp.json is inert until explicitly referenced ───────────

@test "inert: the conventional auto-default path is NOT the lsp config" {
  # engine.sh auto-defaults REVIEW_MCP_CONFIG only to .github/review-mcp.json,
  # never to the LSP config — so merely committing lsp.json activates nothing.
  _source_engine "claude"
  [ "$REVIEW_MCP_CONFIG_DEFAULT_PATH" != "$LSP_CONFIG" ]
  [ "$REVIEW_MCP_CONFIG_DEFAULT_PATH" = ".github/review-mcp.json" ]
}

@test "inert: lsp config present but unreferenced → no LSP MCP flags threaded" {
  # Point the conventional default away from any committed config and leave
  # REVIEW_MCP_CONFIG unset: the deep call must be byte-for-byte the legacy shape.
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$(mktemp -u)"
  _source_engine "claude"
  run run_agentic "$TEST_PROMPT" "claude-opus-4-8" "deep"
  [ "$status" -eq 0 ]
  ! grep -q -- "--mcp-config" "$ARGS_RECORD"
  ! grep -q -- "mcp__lsp__" "$ARGS_RECORD"
  grep -q -- "--allowed-tools Bash,Read,Grep,Glob" "$ARGS_RECORD"
}

# ── AC #2: runner setup installs pinned tools, degrades gracefully ────────────

_make_setup_env() {
  # Hermetic sandbox: an isolated bin dir on PATH + a fresh GITHUB_ENV file.
  SANDBOX_BIN="$(mktemp -d)"
  export GITHUB_ENV="$(mktemp)"
  export PATH="$SANDBOX_BIN:$PATH"
}

@test "setup: tools present → threads REVIEW_MCP_CONFIG + navigation knob into GITHUB_ENV" {
  _make_setup_env
  # Simulate the pinned tools already being installed (cache hit) so no network.
  printf '#!/usr/bin/env bash\necho agent-lsp 0.15.0\n' > "$SANDBOX_BIN/agent-lsp"
  printf '#!/usr/bin/env bash\necho 5.6.0\n' > "$SANDBOX_BIN/bash-language-server"
  chmod +x "$SANDBOX_BIN/agent-lsp" "$SANDBOX_BIN/bash-language-server"
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "^REVIEW_MCP_CONFIG=.github/mcp/lsp.json$" "$GITHUB_ENV"
  grep -q "^REVIEW_MCP_ALLOWED_TOOLS=mcp__lsp__" "$GITHUB_ENV"
  rm -rf "$SANDBOX_BIN"
}

@test "setup: a tool cannot be installed → ::warning:: + no knobs + exit 0 (graceful)" {
  _make_setup_env
  # No agent-lsp / bash-language-server on PATH; stub their installers to fail so
  # nothing can be installed and no real network is touched.
  for cmd in npm gh curl uv; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX_BIN/$cmd"
    chmod +x "$SANDBOX_BIN/$cmd"
  done
  run bash "$SETUP_SCRIPT"
  # AC #2: never fails the workflow.
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  # AC #2/#4: nothing wired when degraded → review stays on base capabilities.
  ! grep -q "^REVIEW_MCP_CONFIG=" "$GITHUB_ENV"
  ! grep -q "^REVIEW_MCP_ALLOWED_TOOLS=" "$GITHUB_ENV"
  rm -rf "$SANDBOX_BIN"
}
