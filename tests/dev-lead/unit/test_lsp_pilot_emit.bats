#!/usr/bin/env bats
# Unit tests for scripts/lsp_pilot_emit.sh — the production-review pilot record
# emitter (epic #839, story #844, issue #960). It is the glue that turns a real
# pr-review (under the pilot flag) into ONE pilot-schema record on TOKEN_LOG_FILE:
#   * the gate (LSP_PILOT_ENABLED), variant/candidate resolution, and pr join key,
#   * emit_record: run lsp_pilot_measure.sh over the captured stream, tag the
#     output with kind:"lsp_pilot_run" so token_report.sh keeps excluding it.
# The off-pilot path must be a strict no-op (the five consumer repos rely on it).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
EMIT="$SCRIPT_DIR/scripts/lsp_pilot_emit.sh"

_call() { run bash -c 'source "$1"; shift; "$@"' bash "$EMIT" "$@"; }

setup() {
  unset LSP_PILOT_ENABLED LSP_PILOT_VARIANT REVIEW_MCP_CONFIG LSP_CANDIDATE TOKEN_LOG_FILE
  STREAM_DIR="$(mktemp -d)"
  TOKEN_LOG="$(mktemp)"
  : > "$TOKEN_LOG"
}

teardown() {
  rm -rf "$STREAM_DIR"
  rm -f "$TOKEN_LOG"
}

# A minimal stream-json transcript: one navigation tool_use (Grep) + its result,
# then a terminal `result` event carrying .result text and real .usage.
_write_stream() {
  local dest="$1"
  cat > "$dest" <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"foo"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"scripts/x.sh:1:foo"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"verdict","model":"claude-opus-4-8","usage":{"input_tokens":1200,"cache_read_input_tokens":300,"output_tokens":80}}
JSON
}

# ── Gate ─────────────────────────────────────────────────────────────────────

@test "lpe_pilot_active: true only when LSP_PILOT_ENABLED=true" {
  LSP_PILOT_ENABLED=true _call lpe_pilot_active
  [ "$status" -eq 0 ]
}

@test "lpe_pilot_active: false when flag unset" {
  _call lpe_pilot_active
  [ "$status" -ne 0 ]
}

@test "lpe_pilot_active: false for any non-true value" {
  LSP_PILOT_ENABLED=1 _call lpe_pilot_active
  [ "$status" -ne 0 ]
  LSP_PILOT_ENABLED=yes _call lpe_pilot_active
  [ "$status" -ne 0 ]
}

# ── Variant / candidate ──────────────────────────────────────────────────────

@test "lpe_variant: lsp-off when REVIEW_MCP_CONFIG unset" {
  _call lpe_variant
  [ "$output" = "lsp-off" ]
}

@test "lpe_variant: lsp-on when REVIEW_MCP_CONFIG points at a readable file" {
  local cfg; cfg="$(mktemp)"; echo '{}' > "$cfg"
  REVIEW_MCP_CONFIG="$cfg" _call lpe_variant
  rm -f "$cfg"
  [ "$output" = "lsp-on" ]
}

@test "lpe_variant: lsp-off when REVIEW_MCP_CONFIG path is missing" {
  REVIEW_MCP_CONFIG="/no/such/file" _call lpe_variant
  [ "$output" = "lsp-off" ]
}

@test "lpe_candidate: baseline for lsp-off, agent-lsp for lsp-on" {
  _call lpe_candidate
  [ "$output" = "baseline" ]
  local cfg; cfg="$(mktemp)"; echo '{}' > "$cfg"
  REVIEW_MCP_CONFIG="$cfg" _call lpe_candidate
  rm -f "$cfg"
  [ "$output" = "agent-lsp" ]
}

@test "lpe_candidate: honors LSP_CANDIDATE override on the lsp-on leg" {
  local cfg; cfg="$(mktemp)"; echo '{}' > "$cfg"
  REVIEW_MCP_CONFIG="$cfg" LSP_CANDIDATE="agent-lsp-next" _call lpe_candidate
  rm -f "$cfg"
  [ "$output" = "agent-lsp-next" ]
}

# ── Decoupling: explicit LSP_PILOT_VARIANT is authoritative (issue #1031) ─────
# The A/B legs must be selectable independently of REVIEW_MCP_CONFIG, because
# engine.sh auto-defaults REVIEW_MCP_CONFIG to the committed .github/review-mcp.json
# (the GitHub review MCP) — so the lsp-off (A) control leg would otherwise be
# mislabelled lsp-on. LSP_PILOT_VARIANT=off|on overrides the detection.

@test "lpe_variant: LSP_PILOT_VARIANT=off forces lsp-off even with a readable REVIEW_MCP_CONFIG" {
  local cfg; cfg="$(mktemp "$STREAM_DIR/cfg.XXXXXX")"; echo '{}' > "$cfg"
  REVIEW_MCP_CONFIG="$cfg" LSP_PILOT_VARIANT=off _call lpe_variant
  [ "$output" = "lsp-off" ]
}

@test "lpe_variant: LSP_PILOT_VARIANT=on forces lsp-on even when REVIEW_MCP_CONFIG is unset" {
  LSP_PILOT_VARIANT=on _call lpe_variant
  [ "$output" = "lsp-on" ]
}

@test "lpe_variant: LSP_PILOT_VARIANT=none/empty falls back to REVIEW_MCP_CONFIG detection" {
  LSP_PILOT_VARIANT=none _call lpe_variant
  [ "$output" = "lsp-off" ]
  local cfg; cfg="$(mktemp "$STREAM_DIR/cfg.XXXXXX")"; echo '{}' > "$cfg"
  REVIEW_MCP_CONFIG="$cfg" LSP_PILOT_VARIANT=none _call lpe_variant
  [ "$output" = "lsp-on" ]
}

@test "lpe_candidate: follows the explicit variant (off→baseline, on→agent-lsp)" {
  local cfg; cfg="$(mktemp "$STREAM_DIR/cfg.XXXXXX")"; echo '{}' > "$cfg"
  REVIEW_MCP_CONFIG="$cfg" LSP_PILOT_VARIANT=off _call lpe_candidate
  [ "$output" = "baseline" ]
  LSP_PILOT_VARIANT=on _call lpe_candidate
  [ "$output" = "agent-lsp" ]
}

# ── pr join key ──────────────────────────────────────────────────────────────

@test "lpe_pr_key: builds <owner/repo>#<num>@<sha> from a PR URL" {
  _call lpe_pr_key "https://github.com/petry-projects/.github-private/pull/960" "deadbeef"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github-private#960@deadbeef" ]
}

# ── wall seconds ─────────────────────────────────────────────────────────────

@test "lpe_wall_seconds: positive delta → seconds (1dp); backwards → 0.0" {
  _call lpe_wall_seconds 1000000000 4500000000
  [ "$output" = "3.5" ]
  _call lpe_wall_seconds 5000000000 1000000000
  [ "$output" = "0.0" ]
}

# ── emit_record ──────────────────────────────────────────────────────────────

@test "lpe_emit_record: off-pilot is a strict no-op (no record appended)" {
  _write_stream "$STREAM_DIR/stream.aaa"
  unset LSP_PILOT_ENABLED
  run bash -c 'source "$1"; shift; TOKEN_LOG_FILE="$1"; shift; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" \
    "$STREAM_DIR" "https://github.com/o/r/pull/5" "sha5" "12.0"
  [ "$status" -eq 0 ]
  [ ! -s "$TOKEN_LOG" ]
}

@test "lpe_emit_record: active + transcript → exactly one kind:lsp_pilot_run record" {
  _write_stream "$STREAM_DIR/stream.aaa"
  run bash -c 'source "$1"; shift; export LSP_PILOT_ENABLED=true TOKEN_LOG_FILE="$1"; shift; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" \
    "$STREAM_DIR" "https://github.com/petry-projects/.github-private/pull/960" "abc123" "17.5"
  [ "$status" -eq 0 ]
  # exactly one line
  [ "$(wc -l < "$TOKEN_LOG")" -eq 1 ]
  run jq -r '.kind' "$TOKEN_LOG";          [ "$output" = "lsp_pilot_run" ]
  run jq -r '.pr' "$TOKEN_LOG";            [ "$output" = "petry-projects/.github-private#960@abc123" ]
  run jq -r '.variant' "$TOKEN_LOG";       [ "$output" = "lsp-off" ]
  run jq -r '.candidate' "$TOKEN_LOG";     [ "$output" = "baseline" ]
  run jq -r '.wall_time_s' "$TOKEN_LOG";   [ "$output" = "17.5" ]
  run jq -r '.tool_calls' "$TOKEN_LOG";    [ "$output" = "1" ]
  run jq -r '.input_tokens' "$TOKEN_LOG";  [ "$output" = "1200" ]
}

@test "lpe_emit_record: lsp-on variant uses REVIEW_MCP_CONFIG + agent-lsp candidate" {
  _write_stream "$STREAM_DIR/stream.aaa"
  local cfg; cfg="$(mktemp)"; echo '{}' > "$cfg"
  run bash -c 'source "$1"; shift; export LSP_PILOT_ENABLED=true TOKEN_LOG_FILE="$1" REVIEW_MCP_CONFIG="$2"; shift 2; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" "$cfg" \
    "$STREAM_DIR" "https://github.com/o/r/pull/7" "sha7" "9.0"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  run jq -r '.variant' "$TOKEN_LOG";   [ "$output" = "lsp-on" ]
  run jq -r '.candidate' "$TOKEN_LOG"; [ "$output" = "agent-lsp" ]
}

@test "lpe_emit_record: LSP_PILOT_VARIANT=off yields an lsp-off record even with REVIEW_MCP_CONFIG set (A-leg decoupling)" {
  _write_stream "$STREAM_DIR/stream.aaa"
  local cfg; cfg="$(mktemp "$STREAM_DIR/cfg.XXXXXX")"; echo '{}' > "$cfg"
  run bash -c 'source "$1"; shift; export LSP_PILOT_ENABLED=true LSP_PILOT_VARIANT=off TOKEN_LOG_FILE="$1" REVIEW_MCP_CONFIG="$2"; shift 2; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" "$cfg" \
    "$STREAM_DIR" "https://github.com/petry-projects/.github-private/pull/1031" "shaA" "6.0"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TOKEN_LOG")" -eq 1 ]
  run jq -r '.pr' "$TOKEN_LOG";        [ "$output" = "petry-projects/.github-private#1031@shaA" ]
  run jq -r '.variant' "$TOKEN_LOG";   [ "$output" = "lsp-off" ]
  run jq -r '.candidate' "$TOKEN_LOG"; [ "$output" = "baseline" ]
}

@test "lpe_emit_record: LSP_PILOT_VARIANT=on yields an lsp-on/agent-lsp record (B leg, same PR key)" {
  _write_stream "$STREAM_DIR/stream.aaa"
  local cfg; cfg="$(mktemp "$STREAM_DIR/cfg.XXXXXX")"; echo '{}' > "$cfg"
  run bash -c 'source "$1"; shift; export LSP_PILOT_ENABLED=true LSP_PILOT_VARIANT=on TOKEN_LOG_FILE="$1" REVIEW_MCP_CONFIG="$2"; shift 2; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" "$cfg" \
    "$STREAM_DIR" "https://github.com/petry-projects/.github-private/pull/1031" "shaA" "6.0"
  [ "$status" -eq 0 ]
  run jq -r '.pr' "$TOKEN_LOG";        [ "$output" = "petry-projects/.github-private#1031@shaA" ]
  run jq -r '.variant' "$TOKEN_LOG";   [ "$output" = "lsp-on" ]
  run jq -r '.candidate' "$TOKEN_LOG"; [ "$output" = "agent-lsp" ]
}

@test "lpe_emit_record: empty stream dir (no review transcript) → no record" {
  run bash -c 'source "$1"; shift; export LSP_PILOT_ENABLED=true TOKEN_LOG_FILE="$1"; shift; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" \
    "$STREAM_DIR" "https://github.com/o/r/pull/8" "sha8" "1.0"
  [ "$status" -eq 0 ]
  [ ! -s "$TOKEN_LOG" ]
}

@test "lpe_emit_record: concatenates multiple per-call transcripts (sums nav tool_calls)" {
  _write_stream "$STREAM_DIR/stream.aaa"
  _write_stream "$STREAM_DIR/stream.bbb"
  run bash -c 'source "$1"; shift; export LSP_PILOT_ENABLED=true TOKEN_LOG_FILE="$1"; shift; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" \
    "$STREAM_DIR" "https://github.com/o/r/pull/9" "sha9" "2.0"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TOKEN_LOG")" -eq 1 ]
  run jq -r '.tool_calls' "$TOKEN_LOG"; [ "$output" = "2" ]
}

@test "lpe_emit_record: emitted record is excluded by token_report's kind filter" {
  _write_stream "$STREAM_DIR/stream.aaa"
  run bash -c 'source "$1"; shift; export LSP_PILOT_ENABLED=true TOKEN_LOG_FILE="$1"; shift; lpe_emit_record "$@"' \
    bash "$EMIT" "$TOKEN_LOG" \
    "$STREAM_DIR" "https://github.com/o/r/pull/10" "sha10" "3.0"
  [ "$status" -eq 0 ]
  # token_report.sh keeps only (.kind // "token_usage") == "token_usage"
  run jq -r 'select((.kind // "token_usage") == "token_usage")' "$TOKEN_LOG"
  [ -z "$output" ]
}
