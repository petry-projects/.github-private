#!/usr/bin/env bash
set -euo pipefail
# setup-lsp-pilot.sh — opt-in runner setup for the LSP-MCP review pilot.
# Epic #839 (LSP pilot), story #842. Contract: docs/lsp-pilot.md.
#
# Installs the pinned LSP-MCP server binary for the selected candidate plus the
# pinned `bash-language-server` (the pilot's Shell language server), then threads
# the opt-in MCP knobs into the job environment so engine.sh enriches the
# deep/audit (and rubber-duck) review tiers — triage is never touched (see
# scripts/engine.sh `_mcp_review_flags`).
#
# Fail Loud, Never Fake: if a pinned tool cannot be installed, this emits a
# single `::warning::` and SKIPS wiring the knobs (the review continues on the
# model's base capabilities). It never exits non-zero — a missing tool must not
# fail the workflow (AC #2). The committed config (.github/mcp/lsp.json) stays
# inert until REVIEW_MCP_CONFIG references it, so an off-pilot job is byte-for-
# byte unchanged (AC #4).
#
# Usage:
#   setup-lsp-pilot.sh                     install + wire (the CI entry point)
#   setup-lsp-pilot.sh print-allowed-tools print the navigation allowlist, exit
#
# Pins are LOOKED UP from the source of truth and recorded in docs/lsp-pilot.md
# §5 — never guessed (CLAUDE.md / AGENTS.md). Override via the env vars below for
# a candidate bump without editing this script.

# Server name in .github/mcp/lsp.json is "lsp", so its tools are mcp__lsp__*.
# Canonical navigation/read-only allowlist for the pilot (AC #3): kept to 8-12
# tools to bound MCP tool-definition token overhead (~200 tokens/tool/turn).
# These are exactly the finding-verification surface from docs/lsp-pilot.md §2
# (references + diagnostics) and close navigation kin (definition/hover/symbols).
# Deliberately read-only: NO editing/refactoring tools (rename, apply_edit,
# insert_*, safe_delete, replace_symbol, format_*, execute_command) are exposed —
# the pilot verifies findings, it does not mutate code.
LSP_PILOT_ALLOWED_TOOLS="\
mcp__lsp__find_references,\
mcp__lsp__go_to_definition,\
mcp__lsp__go_to_type_definition,\
mcp__lsp__go_to_implementation,\
mcp__lsp__go_to_declaration,\
mcp__lsp__get_diagnostics,\
mcp__lsp__inspect_symbol,\
mcp__lsp__list_symbols,\
mcp__lsp__find_symbol,\
mcp__lsp__explore_symbol"

# Committed, candidate-switchable MCP config (relative to the repo root the
# review job checks out). Point REVIEW_MCP_CONFIG here to enable the pilot.
LSP_PILOT_CONFIG="${LSP_PILOT_CONFIG:-.github/mcp/lsp.json}"

# Selected candidate server (docs/lsp-pilot.md §5). Only the candidate that wins
# the comparison (#844) is carried past Phase 2; the cost cap bounds the pilot to
# <=2 candidate servers. agent-lsp is the wired default.
LSP_CANDIDATE="${LSP_CANDIDATE:-agent-lsp}"

# Pinned versions (locked in #842; recorded in docs/lsp-pilot.md §5).
AGENT_LSP_VERSION="${AGENT_LSP_VERSION:-v0.15.0}"
BASH_LANGUAGE_SERVER_VERSION="${BASH_LANGUAGE_SERVER_VERSION:-5.6.0}"
AGENT_LSP_REPO="${AGENT_LSP_REPO:-blackwell-systems/agent-lsp}"

# Where downloaded binaries land. On the runner this is added to PATH for later
# steps via $GITHUB_PATH.
INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"

# Cold-start SLA budget in milliseconds (docs/lsp-pilot.md §3: <=30s P95). A
# bring-up that blows this budget auto-skips LSP for the run (warn, don't fail).
# Env-overridable for a future SLA retune without editing this script.
LSP_COLD_START_SLA_MS="${LSP_COLD_START_SLA_MS:-30000}"
case "$LSP_COLD_START_SLA_MS" in
  ''|*[!0-9]*)
    echo "::warning::[lsp-pilot] invalid LSP_COLD_START_SLA_MS='${LSP_COLD_START_SLA_MS}', defaulting to 30000" >&2
    LSP_COLD_START_SLA_MS=30000
    ;;
esac

# Token Cost Observatory instrumentation (best-effort). Provides
# emit_lsp_coldstart_record; absent → _emit_coldstart is a no-op so the pilot
# stays self-contained when deployed without scripts/lib.
_LSP_TOKEN_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/token-metrics.sh"
if [ -f "$_LSP_TOKEN_LIB" ]; then
  # shellcheck source=lib/token-metrics.sh
  source "$_LSP_TOKEN_LIB"
fi

warn() { echo "::warning::[lsp-pilot] $*" >&2; }
note() { echo "[lsp-pilot] $*"; }

# _lsp_now_ms — wall-clock milliseconds. Uses GNU `date +%s%N` (nanoseconds)
# where available; falls back to whole-second resolution (×1000) on platforms
# (e.g. BSD/macOS) where %N is a literal.
_lsp_now_ms() {
  local ns
  ns="$(date +%s%N 2>/dev/null || echo "")"
  case "$ns" in
    ''|*[!0-9]*) printf '%s' "$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))" ;;
    *)           printf '%s' "$(( ns / 1000000 ))" ;;
  esac
}

# _lsp_sla_exceeded <elapsed_ms> <sla_ms>
# Returns 0 (true) when the measured cold-start blew the SLA budget. Pure integer
# comparison so the AC #3 auto-skip decision is unit-testable in isolation.
# Non-numeric input returns 1 (not exceeded) — a measurement glitch must not
# trip the auto-skip on its own.
_lsp_sla_exceeded() {
  local elapsed="${1:-}" sla="${2:-}"
  case "$elapsed" in ''|*[!0-9]*) return 1 ;; esac
  case "$sla" in ''|*[!0-9]*) return 1 ;; esac
  [ "$elapsed" -gt "$sla" ]
}

# _lsp_cache_status — normalize the actions/cache outcome the workflow threads in
# via LSP_INDEX_CACHE_HIT ('true'|'false'|unset) into hit|miss|unknown for the
# cold-start record (AC #2).
_lsp_cache_status() {
  case "${LSP_INDEX_CACHE_HIT:-}" in
    true|True|TRUE)    printf 'hit' ;;
    false|False|FALSE) printf 'miss' ;;
    *)                 printf 'unknown' ;;
  esac
}

# _emit_coldstart <cold_start_ms> <cache_status> <skipped>
# Best-effort emit of the cold-start record to the Token Cost Observatory JSONL.
# No-op when the token lib / TOKEN_LOG_FILE is unavailable — instrumentation must
# never fail the workflow.
_emit_coldstart() {
  declare -f emit_lsp_coldstart_record >/dev/null 2>&1 || return 0
  emit_lsp_coldstart_record "$1" "$2" "$3" "$LSP_COLD_START_SLA_MS" \
    "lsp-pilot:${LSP_CANDIDATE}" || true
}

print_allowed_tools() { printf '%s\n' "$LSP_PILOT_ALLOWED_TOOLS"; }

# _lsp_probe_server_ms — start the MCP server, send a JSON-RPC 2.0 initialize
# request, and return the wall-clock milliseconds to first response. Returns
# $(( LSP_COLD_START_SLA_MS + 1 )) on timeout or launch failure so the SLA gate
# fires on an unresponsive server. Requires `timeout`; falls back to the same
# sentinel when it is absent so the gate still fires rather than silently passing.
#
# Uses named pipes + Content-Length framing instead of grep so the probe works
# even when the server sends a valid JSON-RPC response without a trailing newline
# (LSP frames by byte count, not line endings; grep -m1 blocks until \n arrives).
_lsp_probe_server_ms() {
  command -v timeout >/dev/null 2>&1 || { echo $(( LSP_COLD_START_SLA_MS + 1 )); return 0; }
  local timeout_s=$(( (LSP_COLD_START_SLA_MS + 999) / 1000 + 1 ))
  [ "$timeout_s" -lt 1 ] && timeout_s=1

  local req='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sla-probe","version":"0"}}}'
  local req_len=${#req}

  local t0; t0="$(_lsp_now_ms)"

  # Named pipes let us read the response byte-by-byte (Content-Length framing)
  # and kill the server as soon as the response is detected, without waiting for
  # the server to exit on its own or for timeout to fire.
  local tmpdir; tmpdir="$(mktemp -d)"
  local in_fifo="$tmpdir/in" out_fifo="$tmpdir/out"
  if ! mkfifo "$in_fifo" "$out_fifo" 2>/dev/null; then
    rm -rf "$tmpdir"
    echo $(( LSP_COLD_START_SLA_MS + 1 ))
    return 0
  fi

  # Writer feeds the JSON-RPC request; background so FIFO open() doesn't
  # deadlock before the server opens the read end.
  printf 'Content-Length: %d\r\n\r\n%s' "$req_len" "$req" > "$in_fifo" &
  local writer_pid=$!

  # Server reads from in_fifo, writes response to out_fifo.
  timeout "$timeout_s" agent-lsp "bash:bash-language-server,start" 2>/dev/null \
    < "$in_fifo" > "$out_fifo" &
  local server_pid=$!

  # Parse Content-Length header, then read exactly that many bytes (no newline
  # dependency). read -N reads a fixed character count regardless of line endings.
  local found=0 line content_length body
  content_length=0
  {
    while IFS= read -r line; do
      line="${line%$'\r'}"
      [ -z "$line" ] && break
      case "$line" in
        Content-Length:*|content-length:*)
          content_length="${line#*: }"
          content_length="${content_length//[[:space:]]/}"
          ;;
      esac
    done
    if [ "$content_length" -gt 0 ] 2>/dev/null; then
      read -r -N "$content_length" body 2>/dev/null || true
      case "$body" in *'"jsonrpc"'*) found=1 ;; esac
    fi
  } < "$out_fifo"

  kill "$server_pid" "$writer_pid" 2>/dev/null || true
  wait "$server_pid" "$writer_pid" 2>/dev/null || true
  rm -rf "$tmpdir"

  if [ "$found" -eq 1 ]; then
    echo $(( $(_lsp_now_ms) - t0 ))
  else
    echo $(( LSP_COLD_START_SLA_MS + 1 ))
  fi
}

# probe_candidate — dispatch to the selected candidate's startup probe and
# return wall-clock ms to first JSON-RPC response.
probe_candidate() {
  case "$LSP_CANDIDATE" in
    agent-lsp) _lsp_probe_server_ms ;;
    *) echo $(( LSP_COLD_START_SLA_MS + 1 )) ;;
  esac
}

# install_bash_language_server — npm-global install of the pinned server.
# Returns 0 when the pinned binary is available (cache hit or fresh install).
install_bash_language_server() {
  if command -v bash-language-server >/dev/null 2>&1; then
    note "bash-language-server present: $(bash-language-server --version 2>/dev/null | head -1 || true)"
    return 0
  fi
  note "installing bash-language-server@${BASH_LANGUAGE_SERVER_VERSION}"
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm unavailable — cannot install bash-language-server"
    return 1
  fi
  if npm install -g --prefix "$(dirname "$INSTALL_BIN")" "bash-language-server@${BASH_LANGUAGE_SERVER_VERSION}" >/dev/null 2>&1; then
    command -v bash-language-server >/dev/null 2>&1 && return 0
  fi
  warn "bash-language-server@${BASH_LANGUAGE_SERVER_VERSION} install failed"
  return 1
}

# install_agent_lsp — download the pinned release tarball, verify its sha256
# against the release checksums.txt, and extract the binary onto PATH.
install_agent_lsp() {
  if command -v agent-lsp >/dev/null 2>&1; then
    note "agent-lsp present: $(agent-lsp --version 2>/dev/null | head -1 || true)"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh unavailable — cannot download ${AGENT_LSP_REPO}@${AGENT_LSP_VERSION}"
    return 1
  fi

  local arch asset workdir
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "unsupported arch '$(uname -m)' for agent-lsp"; return 1 ;;
  esac
  asset="agent-lsp_linux_${arch}.tar.gz"

  workdir="$(mktemp -d)"
  note "downloading ${AGENT_LSP_REPO}@${AGENT_LSP_VERSION} (${asset})"
  if ! gh release download "$AGENT_LSP_VERSION" \
        --repo "$AGENT_LSP_REPO" \
        --pattern "$asset" \
        --pattern "checksums.txt" \
        --dir "$workdir" >/dev/null 2>&1; then
    warn "release download failed for ${AGENT_LSP_REPO}@${AGENT_LSP_VERSION}"
    rm -rf "$workdir"
    return 1
  fi

  # Checksum verification (pins the artifact, not just the tag).
  if [ -f "$workdir/checksums.txt" ] && command -v sha256sum >/dev/null 2>&1; then
    if ! ( cd "$workdir" && grep -E "[ *]${asset}\$" checksums.txt | sha256sum -c - >/dev/null 2>&1 ); then
      warn "checksum verification failed for ${asset} — refusing to install"
      rm -rf "$workdir"
      return 1
    fi
    note "checksum verified for ${asset}"
  else
    warn "checksums.txt or sha256sum missing — cannot verify ${asset}, refusing to install"
    rm -rf "$workdir"
    return 1
  fi

  mkdir -p "$INSTALL_BIN"
  if ! tar -xzf "$workdir/$asset" -C "$workdir" agent-lsp 2>/dev/null; then
    # Some archives nest the binary; fall back to extracting all then locating it.
    tar -xzf "$workdir/$asset" -C "$workdir" >/dev/null 2>&1 || true
  fi
  local bin
  bin="$(find "$workdir" -type f -name agent-lsp -perm -u+x 2>/dev/null | head -1)"
  if [ -z "$bin" ]; then
    bin="$(find "$workdir" -type f -name agent-lsp 2>/dev/null | head -1)"
  fi
  if [ -z "$bin" ]; then
    warn "agent-lsp binary not found in ${asset}"
    rm -rf "$workdir"
    return 1
  fi
  install -m 0755 "$bin" "$INSTALL_BIN/agent-lsp"
  rm -rf "$workdir"
  command -v agent-lsp >/dev/null 2>&1 || export PATH="$INSTALL_BIN:$PATH"
  [ -x "$INSTALL_BIN/agent-lsp" ] && return 0
  warn "agent-lsp install did not produce an executable"
  return 1
}

# install_candidate — dispatch to the selected candidate's installer.
install_candidate() {
  case "$LSP_CANDIDATE" in
    agent-lsp) install_agent_lsp ;;
    *)
      warn "candidate '$LSP_CANDIDATE' is not wired in this pilot phase — skipping (see docs/lsp-pilot.md §5)"
      return 1
      ;;
  esac
}

main() {
  if [ ! -f "$LSP_PILOT_CONFIG" ]; then
    warn "MCP config '$LSP_PILOT_CONFIG' not found — skipping LSP pilot setup"
    return 0
  fi

  mkdir -p "$INSTALL_BIN"
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$INSTALL_BIN" >> "$GITHUB_PATH"
  fi
  export PATH="$INSTALL_BIN:$PATH"

  # ── Cold-start budget (AC #2/#3) ───────────────────────────────────────────
  # Two-phase bring-up measurement:
  #   1. Install phase — binary availability (fast on cache hit, slow on miss).
  #   2. Probe phase  — actual MCP server startup including index load; this is
  #      what can be slow even when binaries are cached (cold or stale index).
  # Summing both phases gives total bring-up time; the SLA gate fires if either
  # phase is expensive. "warn, don't fail" degradation contract is preserved.
  local install_start_ms install_end_ms install_ms probe_ms cold_start_ms cache_status
  install_start_ms="$(_lsp_now_ms)"

  local server_ok=1 bls_ok=1
  install_candidate || server_ok=0
  install_bash_language_server || bls_ok=0

  install_end_ms="$(_lsp_now_ms)"
  install_ms=$(( install_end_ms - install_start_ms ))
  [ "$install_ms" -lt 0 ] && install_ms=0
  cache_status="$(_lsp_cache_status)"

  if [ "$server_ok" -ne 1 ] || [ "$bls_ok" -ne 1 ]; then
    _emit_coldstart "$install_ms" "$cache_status" "true"
    warn "LSP toolchain unavailable (candidate=${LSP_CANDIDATE}) — review continues on base capabilities, LSP enrichment skipped"
    return 0
  fi

  # Probe actual server startup (index load). Binary presence (above) is fast
  # for a cache hit; the expensive first index build happens here. Total is
  # install + probe so the SLA gate captures full bring-up time.
  probe_ms="$(probe_candidate)"
  cold_start_ms=$(( install_ms + probe_ms ))
  [ "$cold_start_ms" -lt 0 ] && cold_start_ms=0

  # ── SLA gate (AC #3) ───────────────────────────────────────────────────────
  if _lsp_sla_exceeded "$cold_start_ms" "$LSP_COLD_START_SLA_MS"; then
    _emit_coldstart "$cold_start_ms" "$cache_status" "true"
    warn "LSP cold-start ${cold_start_ms}ms exceeded the ${LSP_COLD_START_SLA_MS}ms P95 SLA — auto-skipping LSP for this run; review continues on base capabilities"
    return 0
  fi

  _emit_coldstart "$cold_start_ms" "$cache_status" "false"

  # Thread the opt-in knobs into the job env for the subsequent review step.
  # engine.sh reads these; with them set it appends --mcp-config/--strict-mcp-config
  # and merges the navigation tools into the deep/duck --allowed-tools (triage
  # untouched).
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "REVIEW_MCP_CONFIG=${LSP_PILOT_CONFIG}"
      echo "REVIEW_MCP_ALLOWED_TOOLS=${LSP_PILOT_ALLOWED_TOOLS}"
    } >> "$GITHUB_ENV"
    note "LSP pilot enabled: REVIEW_MCP_CONFIG=${LSP_PILOT_CONFIG} (cold-start ${cold_start_ms}ms, cache ${cache_status})"
  else
    note "GITHUB_ENV unset — install complete; export REVIEW_MCP_CONFIG=${LSP_PILOT_CONFIG} to enable"
  fi
}

# Only dispatch when executed (not when sourced for unit tests). Sourcing exposes
# the helpers above without running the installer.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    print-allowed-tools) print_allowed_tools ;;
    ""|setup) main ;;
    *) echo "usage: $(basename "$0") [print-allowed-tools|setup]" >&2; exit 2 ;;
  esac
fi
