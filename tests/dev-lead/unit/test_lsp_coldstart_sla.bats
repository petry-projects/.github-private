#!/usr/bin/env bats
# Unit tests for the LSP cold-start SLA + index-cache instrumentation
# (epic #839, story #846). TDD — written before implementation.
#
# This story layers three things on top of the #842 wiring:
#   AC #1 — actions/cache for the LSP index in pr-review.yml (asserted by the
#           workflow grep tests below; the cache *outcome* is threaded into the
#           setup script as LSP_INDEX_CACHE_HIT).
#   AC #2 — cold-start time + cache hit/miss recorded to the Token Cost
#           Observatory JSONL via emit_lsp_coldstart_record.
#   AC #3 — cold-start over the 30s P95 SLA auto-skips LSP (warn, don't fail):
#           the review proceeds without LSP and the workflow never fails.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
TOKEN_LIB="$SCRIPT_DIR/scripts/lib/token-metrics.sh"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup-lsp-pilot.sh"
WORKFLOW="$SCRIPT_DIR/.github/workflows/pr-review.yml"

setup() {
  TOKEN_LOG_FILE="$(mktemp)"
  export TOKEN_LOG_FILE
  unset LSP_INDEX_CACHE_HIT LSP_COLD_START_SLA_MS GITHUB_RUN_ID
}

teardown() {
  [ -n "${TOKEN_LOG_FILE:-}" ] && rm -f "$TOKEN_LOG_FILE" 2>/dev/null || true
  [ -n "${GITHUB_ENV:-}" ] && rm -f "$GITHUB_ENV" 2>/dev/null || true
  [ -n "${SANDBOX_BIN:-}" ] && rm -rf "$SANDBOX_BIN" 2>/dev/null || true
  if [ -n "${INSTALL_BIN:-}" ]; then
    local _parent
    _parent="$(dirname "$INSTALL_BIN")"
    # Sourcing setup-lsp-pilot.sh sets INSTALL_BIN=$HOME/.local/bin as a side
    # effect; only remove the parent when it is a mktemp'd tmp dir, never a
    # system path like $HOME/.local (which would destroy the bats installation).
    case "$_parent" in /tmp/*) rm -rf "$_parent" 2>/dev/null || true ;; esac
  fi
  unset TOKEN_LOG_FILE LSP_INDEX_CACHE_HIT LSP_COLD_START_SLA_MS GITHUB_ENV SANDBOX_BIN INSTALL_BIN
}

# Hermetic setup sandbox mirroring test_lsp_pilot.bats: isolated PATH bin dir,
# fresh GITHUB_ENV, INSTALL_BIN pointed at a temp dir so no real install lands.
_make_setup_env() {
  export SANDBOX_BIN="$(mktemp -d)"
  export GITHUB_ENV="$(mktemp)"
  export INSTALL_BIN="$(mktemp -d)/bin"
  # Hermetic PATH: the sandbox + base system dirs only, deliberately excluding
  # ~/.local/bin so a pre-installed agent-lsp/bash-language-server on the host
  # cannot leak into the "uninstallable"/"present" scenarios (these tests must be
  # deterministic regardless of what the runner already has on PATH).
  export PATH="$SANDBOX_BIN:/usr/local/bin:/usr/bin:/bin"
}

_present_tools() {
  # Stub agent-lsp: handle --version for install checks and emit an instant
  # JSON-RPC initialize response for _lsp_probe_server_ms so warm-run tests
  # are not gated by a real server startup or network.
  cat > "$SANDBOX_BIN/agent-lsp" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "agent-lsp 0.15.0"
  exit 0
fi
# MCP startup probe: emit a minimal initialize response then drain stdin.
resp='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}'
printf 'Content-Length: %d\r\n\r\n%s' "${#resp}" "$resp"
cat >/dev/null
STUB
  chmod +x "$SANDBOX_BIN/agent-lsp"
  printf '#!/usr/bin/env bash\necho 5.6.0\n' > "$SANDBOX_BIN/bash-language-server"
  chmod +x "$SANDBOX_BIN/bash-language-server"
}

# ── AC #2: emit_lsp_coldstart_record JSONL contract ──────────────────────────

@test "coldstart record: emits a well-formed lsp_cold_start JSONL record" {
  source "$TOKEN_LIB"
  emit_lsp_coldstart_record 1234 hit false 30000 "lsp-pilot:agent-lsp"
  [ -s "$TOKEN_LOG_FILE" ]
  run jq -r '.metric' "$TOKEN_LOG_FILE"
  [ "$output" = "lsp_cold_start" ]
  run jq -r '.cold_start_ms' "$TOKEN_LOG_FILE"
  [ "$output" = "1234" ]
  run jq -r '.cache' "$TOKEN_LOG_FILE"
  [ "$output" = "hit" ]
  run jq -r '.skipped' "$TOKEN_LOG_FILE"
  [ "$output" = "false" ]
  run jq -r '.sla_ms' "$TOKEN_LOG_FILE"
  [ "$output" = "30000" ]
}

@test "coldstart record: skipped flag is encoded as a JSON boolean true" {
  source "$TOKEN_LIB"
  emit_lsp_coldstart_record 45000 miss true 30000 "lsp-pilot:agent-lsp"
  run jq -e '.skipped == true' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
}

@test "coldstart record: no-op when TOKEN_LOG_FILE is unset" {
  source "$TOKEN_LIB"
  unset TOKEN_LOG_FILE
  run emit_lsp_coldstart_record 1234 hit false 30000 "ctx"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── AC #3: the SLA auto-skip decision (pure function) ────────────────────────

@test "sla decision: cold-start over budget → exceeded (true)" {
  # shellcheck source=/dev/null
  source "$SETUP_SCRIPT" >/dev/null 2>&1 || true
  run _lsp_sla_exceeded 30001 30000
  [ "$status" -eq 0 ]
}

@test "sla decision: cold-start at budget → not exceeded (false)" {
  source "$SETUP_SCRIPT" >/dev/null 2>&1 || true
  run _lsp_sla_exceeded 30000 30000
  [ "$status" -ne 0 ]
}

@test "sla decision: cold-start under budget → not exceeded (false)" {
  source "$SETUP_SCRIPT" >/dev/null 2>&1 || true
  run _lsp_sla_exceeded 12000 30000
  [ "$status" -ne 0 ]
}

@test "sla decision: non-numeric input is treated as not-exceeded (safe default)" {
  source "$SETUP_SCRIPT" >/dev/null 2>&1 || true
  run _lsp_sla_exceeded "garbage" 30000
  [ "$status" -ne 0 ]
}

# ── AC #2: cache hit/miss normalization ──────────────────────────────────────

@test "cache status: LSP_INDEX_CACHE_HIT=true → hit" {
  source "$SETUP_SCRIPT" >/dev/null 2>&1 || true
  export LSP_INDEX_CACHE_HIT=true
  run _lsp_cache_status
  [ "$output" = "hit" ]
}

@test "cache status: LSP_INDEX_CACHE_HIT=false → miss" {
  source "$SETUP_SCRIPT" >/dev/null 2>&1 || true
  export LSP_INDEX_CACHE_HIT=false
  run _lsp_cache_status
  [ "$output" = "miss" ]
}

@test "cache status: LSP_INDEX_CACHE_HIT unset → unknown" {
  source "$SETUP_SCRIPT" >/dev/null 2>&1 || true
  unset LSP_INDEX_CACHE_HIT
  run _lsp_cache_status
  [ "$output" = "unknown" ]
}

# ── AC #2/#3: end-to-end through setup-lsp-pilot.sh main() ────────────────────

@test "setup: under-SLA warm run → wires knobs + records skipped:false + cache hit" {
  _make_setup_env
  _present_tools
  export LSP_INDEX_CACHE_HIT=true
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  # Knobs wired (under SLA, tools present).
  grep -q "^REVIEW_MCP_CONFIG=.github/mcp/lsp.json$" "$GITHUB_ENV"
  # Cold-start record present, not skipped, cache hit.
  run jq -e 'select(.metric=="lsp_cold_start") | .skipped == false and .cache == "hit"' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
}

@test "setup: cold-start over SLA → auto-skip (warn, no knobs, exit 0, skipped:true)" {
  _make_setup_env
  # Tools present but the --version smoke spends real wall time; SLA of 0ms makes
  # any positive cold-start exceed the budget deterministically.
  printf '#!/usr/bin/env bash\nsleep 0.05\necho agent-lsp 0.15.0\n' > "$SANDBOX_BIN/agent-lsp"
  printf '#!/usr/bin/env bash\necho 5.6.0\n' > "$SANDBOX_BIN/bash-language-server"
  chmod +x "$SANDBOX_BIN/agent-lsp" "$SANDBOX_BIN/bash-language-server"
  export LSP_COLD_START_SLA_MS=0
  export LSP_INDEX_CACHE_HIT=false
  run bash "$SETUP_SCRIPT"
  # AC #3: never fails the workflow.
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"SLA"* ]]
  # No knobs wired — review proceeds without LSP.
  ! grep -q "^REVIEW_MCP_CONFIG=" "$GITHUB_ENV"
  # Cold-start record marks the run skipped.
  run jq -e 'select(.metric=="lsp_cold_start") | .skipped == true' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
}

@test "setup: toolchain uninstallable → records skipped:true and exits 0" {
  _make_setup_env
  for cmd in npm gh curl uv; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX_BIN/$cmd"
    chmod +x "$SANDBOX_BIN/$cmd"
  done
  export LSP_INDEX_CACHE_HIT=false
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q "^REVIEW_MCP_CONFIG=" "$GITHUB_ENV"
  run jq -e 'select(.metric=="lsp_cold_start") | .skipped == true and .cache == "miss"' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
}

# ── AC #1: actions/cache for the LSP index is wired into pr-review.yml ────────

@test "workflow: an actions/cache step caches the LSP index (SHA-pinned)" {
  grep -q "Cache LSP index" "$WORKFLOW"
  # SHA-pinned per the org standard (no bare @v tag), scoped to the LSP cache step.
  run awk '
    /- name: Cache LSP index/ { in_step=1 }
    in_step { print }
    in_step && /^[[:space:]]*- name:/ && !/- name: Cache LSP index/ { exit }
  ' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [[ "$output" =~ uses:\ actions/cache@[0-9a-f]{40} ]]
}

@test "workflow: LSP index cache key is keyed on OS + server version + source hash" {
  run grep -E "key: lsp-index-.*runner\.os.*AGENT_LSP_VERSION.*BASH_LANGUAGE_SERVER_VERSION.*hashFiles" "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "workflow: the cache-hit outcome is threaded into the setup step" {
  grep -q "LSP_INDEX_CACHE_HIT:" "$WORKFLOW"
}

@test "workflow: LSP index cache is opt-in behind LSP_PILOT_ENABLED" {
  # The Cache LSP index step must be gated.
  run awk '
    /- name: Cache LSP index/ { in_step=1 }
    in_step { print }
    in_step && /^[[:space:]]*- name:/ && !/- name: Cache LSP index/ { exit }
  ' "$WORKFLOW"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^[[:space:]]*if:[[:space:]].*LSP_PILOT_ENABLED'

  # The Set up LSP pilot servers step must also be gated.
  run awk '
    /- name: Set up LSP pilot servers/ { in_step=1 }
    in_step { print }
    in_step && /^[[:space:]]*- name:/ && !/- name: Set up LSP pilot servers/ { exit }
  ' "$WORKFLOW"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^[[:space:]]*if:[[:space:]].*LSP_PILOT_ENABLED'
}
