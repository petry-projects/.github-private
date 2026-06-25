#!/usr/bin/env bats
# Unit tests for the LSP cold-start SLA + index-cache wiring (epic #839, story #846).
#
# Builds on story #842's setup wiring — covers only what #846 adds on top:
#   AC #1 — pr-review.yml caches the LSP toolchain/index (SHA-pinned actions/cache)
#           and threads its cache-hit into the setup step.
#   AC #2 — emit_lsp_coldstart_record writes a discriminated lsp_cold_start JSONL
#           record (cold_start_ms, cache, skipped, sla_ms) to the Token Cost
#           Observatory; cache status is normalized to hit/miss/unknown.
#   AC #3 — an over-budget cold-start auto-skips LSP wiring via the "warn, don't
#           fail" contract (no knobs, exit 0); a missing tool degrades the same way.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup-lsp-pilot.sh"
WORKFLOW="$SCRIPT_DIR/.github/workflows/pr-review.yml"

# Source the script in a clean subshell so its `set -euo pipefail` never leaks into
# the bats test shell, and the source-guard keeps main() from running.
_call() { run bash -c 'source "$1"; shift; "$@"' bash "$SETUP_SCRIPT" "$@"; }

# ── AC #3: pure SLA decision helper ───────────────────────────────────────────

@test "_lsp_sla_exceeded: over budget → exceeded (0)" {
  _call _lsp_sla_exceeded 31000 30000
  [ "$status" -eq 0 ]
}

@test "_lsp_sla_exceeded: at budget → not exceeded (1)" {
  _call _lsp_sla_exceeded 30000 30000
  [ "$status" -eq 1 ]
}

@test "_lsp_sla_exceeded: under budget → not exceeded (1)" {
  _call _lsp_sla_exceeded 12000 30000
  [ "$status" -eq 1 ]
}

@test "_lsp_sla_exceeded: non-numeric cold-start → safe default, not exceeded (1)" {
  _call _lsp_sla_exceeded "oops" 30000
  [ "$status" -eq 1 ]
}

@test "_lsp_sla_exceeded: negative SLA (test seam) is exceeded by any cold-start (0)" {
  _call _lsp_sla_exceeded 0 -1
  [ "$status" -eq 0 ]
}

@test "_lsp_sla_exceeded: non-numeric SLA → safe default, not exceeded (1)" {
  _call _lsp_sla_exceeded 5 abc
  [ "$status" -eq 1 ]
}

# ── AC #2: cache-status normalization + elapsed ───────────────────────────────

@test "_lsp_cache_status: true→hit, false→miss, unset→unknown" {
  _call _lsp_cache_status true;  [ "$output" = "hit" ]
  _call _lsp_cache_status false; [ "$output" = "miss" ]
  _call _lsp_cache_status "";    [ "$output" = "unknown" ]
}

@test "_lsp_elapsed_ms: forward delta, and a backwards clock clamps to 0" {
  _call _lsp_elapsed_ms 1000 1500; [ "$output" = "500" ]
  _call _lsp_elapsed_ms 1500 1000; [ "$output" = "0" ]
}

# ── AC #2: the cold-start metric record ───────────────────────────────────────

@test "emit_lsp_coldstart_record: writes a well-formed lsp_cold_start record" {
  local log; log="$(mktemp)"
  run bash -c 'source "$1"; TOKEN_LOG_FILE="$2" emit_lsp_coldstart_record pr-review agent-lsp 1234 hit false 30000 ok' \
    bash "$SETUP_SCRIPT" "$log"
  [ "$status" -eq 0 ]
  run jq -e '.kind=="lsp_cold_start" and .cold_start_ms==1234 and .cache=="hit" and .skipped==false and .sla_ms==30000 and .reason=="ok"' "$log"
  [ "$status" -eq 0 ]
  rm -f "$log"
}

@test "emit_lsp_coldstart_record: no-op when TOKEN_LOG_FILE unset" {
  run bash -c 'source "$1"; unset TOKEN_LOG_FILE; emit_lsp_coldstart_record pr-review agent-lsp 1 hit false 30000 ok; echo done' \
    bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

# ── AC #2/#3: end-to-end setup paths ──────────────────────────────────────────

_make_setup_env() {
  SANDBOX_BIN="$(mktemp -d)"
  export GITHUB_ENV="$(mktemp)"
  export TOKEN_LOG_FILE="$(mktemp)"
  export PATH="$SANDBOX_BIN:$PATH"
}

_teardown_setup_env() {
  rm -rf "$SANDBOX_BIN"
  rm -f "$GITHUB_ENV" "$TOKEN_LOG_FILE"
  unset GITHUB_ENV TOKEN_LOG_FILE SANDBOX_BIN
}

_stub_tools_present() {
  printf '#!/usr/bin/env bash\necho agent-lsp 0.15.0\n' > "$SANDBOX_BIN/agent-lsp"
  printf '#!/usr/bin/env bash\necho 5.6.0\n' > "$SANDBOX_BIN/bash-language-server"
  chmod +x "$SANDBOX_BIN/agent-lsp" "$SANDBOX_BIN/bash-language-server"
}

@test "setup: cold-start under SLA → knobs wired + record skipped:false" {
  _make_setup_env
  _stub_tools_present
  export LSP_INDEX_CACHE_HIT=true
  LSP_COLD_START_SLA_MS=30000 run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "^REVIEW_MCP_CONFIG=.github/mcp/lsp.json$" "$GITHUB_ENV"
  grep -q "^REVIEW_MCP_ALLOWED_TOOLS=mcp__lsp__" "$GITHUB_ENV"
  run jq -e 'select(.kind=="lsp_cold_start") | .skipped==false and .reason=="ok" and .cache=="hit"' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
  unset LSP_INDEX_CACHE_HIT
  _teardown_setup_env
}

@test "setup: cold-start over SLA → ::warning:: + no knobs + exit 0 + record skipped:true" {
  _make_setup_env
  _stub_tools_present
  # SLA of -1ms is exceeded by any non-negative cold-start → deterministic skip.
  LSP_COLD_START_SLA_MS=-1 run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"exceeded SLA"* ]]
  ! grep -q "^REVIEW_MCP_CONFIG=" "$GITHUB_ENV"
  ! grep -q "^REVIEW_MCP_ALLOWED_TOOLS=" "$GITHUB_ENV"
  run jq -e 'select(.kind=="lsp_cold_start") | .skipped==true and .reason=="sla-exceeded"' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
  _teardown_setup_env
}

@test "setup: toolchain uninstallable → record skipped:true (toolchain-unavailable) + exit 0, no knobs" {
  _make_setup_env
  # No agent-lsp / bash-language-server on PATH; stub the installers to fail so
  # nothing installs and no network is touched.
  for cmd in npm gh curl uv; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX_BIN/$cmd"
    chmod +x "$SANDBOX_BIN/$cmd"
  done
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  ! grep -q "^REVIEW_MCP_CONFIG=" "$GITHUB_ENV"
  run jq -e 'select(.kind=="lsp_cold_start") | .skipped==true and .reason=="toolchain-unavailable"' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
  _teardown_setup_env
}

# ── AC #1: workflow wiring ────────────────────────────────────────────────────

@test "workflow: pr-review.yml caches the LSP index (SHA-pinned) and threads cache-hit" {
  # SHA-pinned actions/cache (the same SHA the Claude CLI cache uses), a Cache LSP
  # index step, and the cache-hit output threaded into the setup step's env.
  grep -q "name: Cache LSP index" "$WORKFLOW"
  grep -q "actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae" "$WORKFLOW"
  grep -q "LSP_INDEX_CACHE_HIT: \${{ steps.lsp-cache.outputs.cache-hit }}" "$WORKFLOW"
}
