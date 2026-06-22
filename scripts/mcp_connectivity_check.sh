#!/usr/bin/env bash
# mcp_connectivity_check.sh — durable MCP/Context7 connectivity preflight (#903).
#
# The PR-review pipeline only surfaces MCP health as a fail-loud
# `::warning::[mcp]` on a *real* review (engine.sh:_emit_mcp_failure_warning) —
# a healthy run logs nothing and a silent outage is invisible until a review
# happens to run. This script is the affirmative, durable monitor: invoked by
# the daily health check, it drives the configured MCP server(s) through the
# SAME flags engine.sh threads into its claude tiers
# (`--mcp-config <f> --strict-mcp-config --debug mcp`) and asserts the handshake
# (`MCP server "…": Successfully connected`).
#
# Behavior contract (mirrors the engine's opt-in MCP gating):
#   * MCP NOT configured (no readable config) → no-op, ::notice:: skip, exit 0.
#     Non-MCP repos see no behavior change.
#   * MCP configured AND reachable  → ::notice::[mcp] per handshake, exit 0.
#   * MCP configured but UNREACHABLE → ::error::[mcp], exit 1 (fails the health
#     check). Fail Loud, Never Fake.
#
# Config resolution mirrors engine.sh: an explicit REVIEW_MCP_CONFIG wins; an
# explicit empty value disables; otherwise the conventional committed path
# (REVIEW_MCP_CONFIG_DEFAULT_PATH, default .github/review-mcp.json) is used when
# it exists.
#
# Env vars consumed:
#   REVIEW_MCP_CONFIG              — explicit config path (honored as-is; empty disables)
#   REVIEW_MCP_CONFIG_DEFAULT_PATH — conventional fallback (default .github/review-mcp.json)
#   REVIEW_MCP_ALLOWED_TOOLS       — explicit allowed-tools glob(s); else derived
#                                    from the config's server names (mcp__<name>__*)
#   MCP_PROBE_MODEL               — claude model for the probe (default claude-sonnet-4-6)
#   MCP_PROBE_TIMEOUT_SEC         — hard timeout for the probe (default 120)
#   CLAUDE_CODE_OAUTH_TOKEN       — passed through to the claude CLI

set -euo pipefail

# ---------------------------------------------------------------------------
# Pure helpers (no network / no CLI — unit-tested in
# tests/test_mcp_connectivity_check.bats)
# ---------------------------------------------------------------------------

# _mcp_resolve_config
# Echoes the config path engine.sh would use, or nothing when MCP is off.
# Precedence: explicit REVIEW_MCP_CONFIG (empty string ⇒ disabled) > conventional
# committed path when present. Only echoes a path that is a readable file.
_mcp_resolve_config() {
  local default_path="${REVIEW_MCP_CONFIG_DEFAULT_PATH:-.github/review-mcp.json}"
  local cfg
  if [ -n "${REVIEW_MCP_CONFIG+x}" ]; then
    # Explicit value set (possibly empty). Empty ⇒ MCP disabled.
    cfg="${REVIEW_MCP_CONFIG}"
  elif [ -f "$default_path" ]; then
    cfg="$default_path"
  else
    cfg=""
  fi
  [ -n "$cfg" ] && [ -f "$cfg" ] && [ -r "$cfg" ] || return 0
  printf '%s' "$cfg"
}

# _mcp_allowed_tools <config_file>
# Echoes the comma-separated allowed-tools glob for the probe. Honors an explicit
# REVIEW_MCP_ALLOWED_TOOLS; otherwise derives one glob per configured server
# (mcp__<name>__*) from the config JSON. Falls back to mcp__* if no server names
# can be read (e.g. jq unavailable or odd shape) so the probe still permits MCP.
_mcp_allowed_tools() {
  local cfg="$1"
  if [ -n "${REVIEW_MCP_ALLOWED_TOOLS:-}" ]; then
    printf '%s' "$REVIEW_MCP_ALLOWED_TOOLS"
    return 0
  fi
  local derived=""
  if command -v jq >/dev/null 2>&1; then
    derived="$(jq -r '(.mcpServers // {}) | keys[] | "mcp__\(.)__*"' "$cfg" 2>/dev/null \
      | paste -sd, - || true)"
  fi
  printf '%s' "${derived:-mcp__*}"
}

# _mcp_failure_regex
# Connection/init-failure regex kept in lockstep with engine.sh:_mcp_failure_pattern.
# A degraded MCP server surfaces one of these in the CLI output even though the
# CLI itself exits 0.
_mcp_failure_regex() {
  local _pat
  _pat='mcp server [^[:space:]]*[[:space:]]*("[^"]*"[[:space:]]*)?(failed|error)'
  _pat="$_pat"'|failed to (connect|initialize|reconnect|start)[^.]*mcp'
  _pat="$_pat"'|mcp[^.]*(connection|initializ)[^.]*(fail|error)'
  _pat="$_pat"'|could not (connect to|start) mcp server'
  printf '%s' "($_pat)"
}

# _mcp_assert_connected <output_file>
# Verdict over captured probe output (combined stdout+stderr). Emits ::notice::
# per successful handshake and returns 0; emits ::error:: and returns 1 when a
# failure marker is present OR no handshake line is found at all.
_mcp_assert_connected() {
  local out="$1"
  [ -f "$out" ] || { echo "::error::[mcp] connectivity probe produced no output" >&2; return 1; }

  if grep -qiE "$(_mcp_failure_regex)" "$out"; then
    local servers
    servers="$(grep -hoiE 'mcp server "[^"]+"' "$out" 2>/dev/null \
      | sed -E 's/.*"([^"]+)".*/\1/' | sort -u | paste -sd, - || true)"
    if [ -n "$servers" ]; then
      echo "::error::[mcp] server(s) unreachable: ${servers} — MCP is configured (review-mcp.json) but failed to connect" >&2
    else
      echo "::error::[mcp] an MCP server is configured but failed to connect" >&2
    fi
    return 1
  fi

  local handshakes
  handshakes="$(grep -hoiE 'mcp server "[^"]+": successfully connected.*' "$out" 2>/dev/null | sort -u || true)"
  if [ -z "$handshakes" ]; then
    echo "::error::[mcp] no MCP handshake observed — server is configured but did not report 'Successfully connected'" >&2
    return 1
  fi
  while IFS= read -r _ln; do
    [ -n "$_ln" ] && printf '::notice::[mcp] %s\n' "$_ln" >&2
  done <<< "$handshakes"
  return 0
}

# ---------------------------------------------------------------------------
# main — resolves config, runs the claude probe, asserts the handshake.
# ---------------------------------------------------------------------------
main() {
  local cfg
  cfg="$(_mcp_resolve_config)"
  if [ -z "$cfg" ]; then
    echo "::notice::[mcp] no MCP config present — connectivity assertion skipped (no behavior change for non-MCP repos)"
    return 0
  fi

  local allowed_tools probe_model timeout_sec
  allowed_tools="$(_mcp_allowed_tools "$cfg")"
  probe_model="${MCP_PROBE_MODEL:-claude-sonnet-4-6}"
  timeout_sec="${MCP_PROBE_TIMEOUT_SEC:-120}"

  echo "=== MCP connectivity preflight ==="
  echo "  Config:        $cfg"
  echo "  Allowed tools: $allowed_tools"
  echo "  Probe model:   $probe_model"
  echo ""

  local out rc=0
  out="$(mktemp)"
  # Same flags engine.sh threads into its MCP claude tiers, plus --debug mcp so
  # the handshake lands in the captured output. Combine stdout+stderr; the
  # handshake is written to stderr by `--debug mcp`. A non-zero/timeout exit is
  # captured and folded into the assertion (a hung connect ⇒ unreachable).
  timeout "$timeout_sec" claude --print \
    --model "$probe_model" \
    --no-session-persistence \
    --max-turns 1 \
    --mcp-config "$cfg" \
    --strict-mcp-config \
    --debug mcp \
    --allowedTools "$allowed_tools" \
    -p "MCP connectivity preflight. Reply with the single word: OK." \
    > "$out" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "::warning::[mcp] probe CLI exited non-zero (rc=$rc) — evaluating captured output for a handshake" >&2
  fi

  # Surface the captured probe output to the Actions log for diagnosis.
  echo "--- probe output ---"
  cat "$out"
  echo "--- end probe output ---"

  if _mcp_assert_connected "$out"; then
    echo "MCP connectivity OK."
    rm -f "$out"
    return 0
  fi
  rm -f "$out"
  return 1
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
