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

# Cold-start SLA (story #846): toolchain bring-up (install / actions/cache restore
# → ready) must complete within this budget; over it the LSP wiring is auto-skipped
# (graceful degradation — never a workflow failure, docs/lsp-pilot.md §3). The
# index cache is what keeps a warm run under budget. Overridable for a tuning bump.
LSP_COLD_START_SLA_MS="${LSP_COLD_START_SLA_MS:-30000}"

# Best-effort: the cold-start metric channel (Token Cost Observatory). The review
# job always has the repo checked out, so this resolves; if absent (odd invocation)
# emit_lsp_coldstart_record falls back to a no-op below so the script stays
# self-contained.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/token-metrics.sh" ]; then
  # shellcheck source=scripts/lib/token-metrics.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib/token-metrics.sh"
fi
if ! declare -f emit_lsp_coldstart_record >/dev/null 2>&1; then
  emit_lsp_coldstart_record() { :; }
fi

warn() { echo "::warning::[lsp-pilot] $*" >&2; }
note() { echo "[lsp-pilot] $*"; }

# _lsp_now_ms — current epoch in milliseconds. Falls back to second resolution on
# platforms where `date +%N` is unsupported (the literal `N` is left intact there).
_lsp_now_ms() {
  local ns
  ns="$(date +%s%N 2>/dev/null || echo '')"
  case "$ns" in
    # %.0f, not %d: epoch ms (~1.75e12) overflows awk's 32-bit %d conversion on
    # common awks (mawk) and would yield a garbage cold-start measurement.
    ''|*[!0-9]*) date +%s 2>/dev/null | awk '{ printf "%.0f", $1 * 1000 }' ;;
    *)           awk "BEGIN { printf \"%.0f\", $ns / 1000000 }" ;;
  esac
}

# _lsp_elapsed_ms <start_ms> <end_ms> — non-negative integer delta. Any non-numeric
# input or a backwards clock yields 0 (a glitch must not look like a slow start).
_lsp_elapsed_ms() {
  local a="${1:-0}" b="${2:-0}" d
  case "$a$b" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  d=$(( b - a ))
  [ "$d" -lt 0 ] && d=0
  echo "$d"
}

# _lsp_sla_exceeded <cold_start_ms> <sla_ms> — true (0) when cold-start is over the
# SLA. Pure, for unit coverage. A non-numeric cold-start (clock glitch) is the safe
# default: NOT exceeded, so a measurement error never spuriously skips LSP.
_lsp_sla_exceeded() {
  local cold="${1:-}" sla="${2:-}"
  case "$cold" in ''|*[!0-9]*) return 1 ;; esac
  # sla may be negative (tests use -1 to force the skip path); strip a leading
  # minus, then require the remainder to be all digits.
  case "${sla#-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cold" -gt "$sla" ]
}

# _lsp_cache_status <flag> — normalize an actions/cache `cache-hit` output to
# hit/miss/unknown (true→hit, false→miss, unset/other→unknown).
_lsp_cache_status() {
  case "${1:-}" in
    true|hit)   echo "hit" ;;
    false|miss) echo "miss" ;;
    *)          echo "unknown" ;;
  esac
}

print_allowed_tools() { printf '%s\n' "$LSP_PILOT_ALLOWED_TOOLS"; }

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

  # Time the toolchain bring-up (install / actions/cache restore → ready). This is
  # the honest, shell-observable cold-start proxy: the language server's first-query
  # indexing happens inside the claude subprocess and isn't visible here, but the
  # bring-up window is exactly what the index cache (story #846) eliminates. The
  # cache outcome is threaded in from the workflow's actions/cache step.
  local cache_status t0 t1 cold_ms
  cache_status="$(_lsp_cache_status "${LSP_INDEX_CACHE_HIT:-}")"
  t0="$(_lsp_now_ms)"
  local server_ok=1 bls_ok=1
  install_candidate || server_ok=0
  install_bash_language_server || bls_ok=0
  t1="$(_lsp_now_ms)"
  cold_ms="$(_lsp_elapsed_ms "$t0" "$t1")"

  if [ "$server_ok" -ne 1 ] || [ "$bls_ok" -ne 1 ]; then
    emit_lsp_coldstart_record "pr-review" "$LSP_CANDIDATE" "$cold_ms" "$cache_status" \
      "true" "$LSP_COLD_START_SLA_MS" "toolchain-unavailable"
    warn "LSP toolchain unavailable (candidate=${LSP_CANDIDATE}) — review continues on base capabilities, LSP enrichment skipped"
    return 0
  fi

  # Cold-start SLA auto-skip (AC #3): an over-budget bring-up degrades the
  # enrichment, not the review — same "warn, don't fail" contract as a missing
  # tool. The review proceeds on base capabilities; the workflow never fails.
  if _lsp_sla_exceeded "$cold_ms" "$LSP_COLD_START_SLA_MS"; then
    emit_lsp_coldstart_record "pr-review" "$LSP_CANDIDATE" "$cold_ms" "$cache_status" \
      "true" "$LSP_COLD_START_SLA_MS" "sla-exceeded"
    warn "LSP cold-start ${cold_ms}ms exceeded SLA ${LSP_COLD_START_SLA_MS}ms (cache=${cache_status}) — skipping LSP wiring; review continues on base capabilities"
    return 0
  fi

  emit_lsp_coldstart_record "pr-review" "$LSP_CANDIDATE" "$cold_ms" "$cache_status" \
    "false" "$LSP_COLD_START_SLA_MS" "ok"
  note "LSP cold-start ${cold_ms}ms within SLA ${LSP_COLD_START_SLA_MS}ms (cache=${cache_status})"

  # Thread the opt-in knobs into the job env for the subsequent review step.
  # engine.sh reads these; with them set it appends --mcp-config/--strict-mcp-config
  # and merges the navigation tools into the deep/duck --allowed-tools (triage
  # untouched).
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "REVIEW_MCP_CONFIG=${LSP_PILOT_CONFIG}"
      echo "REVIEW_MCP_ALLOWED_TOOLS=${LSP_PILOT_ALLOWED_TOOLS}"
    } >> "$GITHUB_ENV"
    note "LSP pilot enabled: REVIEW_MCP_CONFIG=${LSP_PILOT_CONFIG}"
  else
    note "GITHUB_ENV unset — install complete; export REVIEW_MCP_CONFIG=${LSP_PILOT_CONFIG} to enable"
  fi
}

# Run the dispatcher only when executed directly — sourcing (e.g. the unit tests
# for the pure cold-start/SLA helpers) must not trigger install + wiring.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    print-allowed-tools) print_allowed_tools ;;
    ""|setup) main ;;
    *) echo "usage: $(basename "$0") [print-allowed-tools|setup]" >&2; exit 2 ;;
  esac
fi
