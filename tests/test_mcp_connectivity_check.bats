#!/usr/bin/env bats
# Tests for scripts/mcp_connectivity_check.sh — the durable MCP connectivity
# preflight (#903, part of #676).
#
# Verdict logic (_mcp_assert_connected) and config/tool resolution are pure and
# tested directly. The end-to-end main() path is exercised with a stubbed
# `claude` on PATH so no real CLI / network is needed.
#
# Run locally: bats tests/test_mcp_connectivity_check.bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/scripts/mcp_connectivity_check.sh"

setup() {
  # shellcheck source=scripts/mcp_connectivity_check.sh
  source "$CHECK_SCRIPT"

  unset REVIEW_MCP_CONFIG REVIEW_MCP_CONFIG_DEFAULT_PATH REVIEW_MCP_ALLOWED_TOOLS

  TMP="$(mktemp -d)"
  export TMP

  # A readable Context7-shaped MCP config.
  MCP_CONFIG="$TMP/review-mcp.json"
  cat > "$MCP_CONFIG" <<'JSON'
{"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp"}}}
JSON

  # Stub `claude` on PATH; behavior controlled by STUB_CLAUDE_OUT / STUB_CLAUDE_RC.
  STUB_BIN="$TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_CLAUDE_OUT:-}"
exit "${STUB_CLAUDE_RC:-0}"
STUB
  chmod +x "$STUB_BIN/claude"
  export PATH="$STUB_BIN:$PATH"
}

teardown() {
  rm -rf "$TMP"
  unset REVIEW_MCP_CONFIG REVIEW_MCP_CONFIG_DEFAULT_PATH REVIEW_MCP_ALLOWED_TOOLS
  unset STUB_CLAUDE_OUT STUB_CLAUDE_RC
}

# ── _mcp_resolve_config ──────────────────────────────────────────────────────

@test "resolve: explicit REVIEW_MCP_CONFIG to readable file is used" {
  export REVIEW_MCP_CONFIG="$MCP_CONFIG"
  run _mcp_resolve_config
  [ "$status" -eq 0 ]
  [ "$output" = "$MCP_CONFIG" ]
}

@test "resolve: explicit empty REVIEW_MCP_CONFIG disables (no path)" {
  export REVIEW_MCP_CONFIG=""
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$MCP_CONFIG"  # present but must be ignored
  run _mcp_resolve_config
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve: no env + conventional path present → conventional path used" {
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$MCP_CONFIG"
  run _mcp_resolve_config
  [ "$status" -eq 0 ]
  [ "$output" = "$MCP_CONFIG" ]
}

@test "resolve: no env + conventional path absent → empty (MCP off)" {
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$TMP/does-not-exist.json"
  run _mcp_resolve_config
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve: explicit path to a missing file → fail loud (status 1 + ::error::)" {
  export REVIEW_MCP_CONFIG="$TMP/nope.json"
  run _mcp_resolve_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
}

@test "resolve: conventional path present but unreadable → fail loud (status 1)" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is not enforced for root — readability gate is a no-op"
  local cfg="$TMP/unreadable.json"
  echo '{"mcpServers":{}}' > "$cfg"
  chmod 000 "$cfg"
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$cfg"
  run _mcp_resolve_config
  chmod 644 "$cfg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
}

@test "main: explicit config missing → fail loud, exit 1 (no silent skip)" {
  export REVIEW_MCP_CONFIG="$TMP/nope.json"
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
}

# ── _mcp_allowed_tools ───────────────────────────────────────────────────────

@test "tools: derived from server names as mcp__<name>__*" {
  run _mcp_allowed_tools "$MCP_CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "mcp__context7__*" ]
}

@test "tools: multiple servers join comma-separated" {
  local cfg="$TMP/multi.json"
  echo '{"mcpServers":{"context7":{},"lsp":{}}}' > "$cfg"
  run _mcp_allowed_tools "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "mcp__context7__*,mcp__lsp__*" ]
}

@test "tools: explicit REVIEW_MCP_ALLOWED_TOOLS wins over derivation" {
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  local cfg="$TMP/multi.json"
  echo '{"mcpServers":{"a":{},"b":{}}}' > "$cfg"
  run _mcp_allowed_tools "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "mcp__context7__*" ]
}

@test "tools: no servers in config → mcp__* fallback" {
  local cfg="$TMP/empty.json"
  echo '{"mcpServers":{}}' > "$cfg"
  run _mcp_allowed_tools "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "mcp__*" ]
}

# ── _mcp_assert_connected ────────────────────────────────────────────────────

@test "assert: healthy handshake → ::notice::, exit 0" {
  local out="$TMP/o"
  printf 'MCP server "context7": Successfully connected (transport: http) in 333ms\nOK\n' > "$out"
  run _mcp_assert_connected "$out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::[mcp]"* ]]
  [[ "$output" == *"context7"* ]]
  [[ "$output" == *"Successfully connected"* ]]
}

@test "assert: failure marker → ::error:: naming server, exit 1" {
  local out="$TMP/o"
  printf 'MCP server "context7" failed to connect after 3 attempts\n' > "$out"
  run _mcp_assert_connected "$out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
  [[ "$output" == *"context7"* ]]
}

@test "assert: no handshake at all → ::error::, exit 1" {
  local out="$TMP/o"
  printf 'some unrelated CLI output with no mcp handshake\n' > "$out"
  run _mcp_assert_connected "$out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
  [[ "$output" == *"no MCP handshake"* ]]
}

@test "assert: handshake present but a later failure line → ::error:: (fail loud)" {
  local out="$TMP/o"
  printf 'MCP server "a": Successfully connected\nMCP server "b" failed to connect\n' > "$out"
  run _mcp_assert_connected "$out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
}

# ── main (stubbed claude) ────────────────────────────────────────────────────

@test "main: MCP unconfigured → skip notice, exit 0 (no claude call)" {
  export REVIEW_MCP_CONFIG_DEFAULT_PATH="$TMP/does-not-exist.json"
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::[mcp]"* ]]
  [[ "$output" == *"connectivity assertion skipped"* ]]
}

@test "main: configured + healthy handshake → exit 0" {
  export REVIEW_MCP_CONFIG="$MCP_CONFIG"
  export STUB_CLAUDE_OUT='MCP server "context7": Successfully connected (transport: http) in 333ms'
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::[mcp]"* ]]
  [[ "$output" == *"MCP connectivity OK"* ]]
}

@test "main: configured but unreachable → exit 1" {
  export REVIEW_MCP_CONFIG="$MCP_CONFIG"
  export STUB_CLAUDE_OUT='MCP server "context7" failed to connect after 3 attempts'
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
}

@test "main: configured, claude exits non-zero but handshake present → exit 0" {
  export REVIEW_MCP_CONFIG="$MCP_CONFIG"
  export STUB_CLAUDE_OUT='MCP server "context7": Successfully connected (transport: http) in 90ms'
  export STUB_CLAUDE_RC=1
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::[mcp]"* ]]   # non-zero rc surfaced
  [[ "$output" == *"MCP connectivity OK"* ]]
}

@test "main: configured, claude exits non-zero with no handshake → exit 1" {
  export REVIEW_MCP_CONFIG="$MCP_CONFIG"
  export STUB_CLAUDE_OUT='error: unknown flag'
  export STUB_CLAUDE_RC=2
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::[mcp]"* ]]
}
