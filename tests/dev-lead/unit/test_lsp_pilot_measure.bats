#!/usr/bin/env bats
# Unit tests for the LSP-pilot measurement extractor (epic #839, story #844).
#
# scripts/lsp_pilot_measure.sh turns one review run's stream-json transcript (+ the
# Token Cost Observatory log) into one pilot-schema JSONL record that
# scripts/lsp_pilot_compare.sh can render. These tests pin the pure extractors:
#   lpm_nav_from_stream     — navigation tool_use count + estimated nav tokens
#   lpm_usage_from_stream   — real reported usage from the terminal result event
#   lpm_quality_from_log    — findings / false_positives from verification records
#   lpm_coldstart_from_log  — cold_start_s from the lsp_cold_start record (null off)
#   main                    — end-to-end record assembly, lsp-off cold_start=null

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
MEASURE="$SCRIPT_DIR/scripts/lsp_pilot_measure.sh"

# Source the script in a clean subshell so its `set -euo pipefail` never leaks and
# the source-guard keeps main() from running.
_call() { run bash -c 'source "$1"; shift; "$@"' bash "$MEASURE" "$@"; }

setup() {
  STREAM="$BATS_TEST_TMPDIR/stream.jsonl"
  LOG="$BATS_TEST_TMPDIR/token.jsonl"

  # A realistic LSP-ON transcript: two navigation calls (one mcp__lsp__, one Grep),
  # one non-navigation call (Write), each with a matching tool_result, then the
  # terminal result event carrying real usage. (printf, not heredoc — bats 1.10's
  # preprocessor mis-parses heredocs inside setup().)
  printf '%s\n' \
    '{"type":"system","subtype":"init","model":"claude-opus-4-8"}' \
    '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"checking callers"},{"type":"tool_use","id":"t1","name":"mcp__lsp__find_references","input":{"symbol":"emit_token_record"}}],"usage":{"input_tokens":10,"output_tokens":5}}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ref1\nref2\nref3\nref4"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"foo"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"scripts/a.sh:12:foo"}]}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Write","input":{"file":"x"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]}}' \
    '{"type":"result","subtype":"success","model":"claude-opus-4-8","result":"done","usage":{"input_tokens":1200,"cache_read_input_tokens":800,"output_tokens":300}}' \
    > "$STREAM"

  printf '%s\n' \
    '{"kind":"lsp_cold_start","candidate":"agent-lsp","cold_start_ms":8200,"cache":"miss","skipped":false,"sla_ms":30000,"reason":"ok"}' \
    '{"kind":"finding_verification","finding_index":0,"category":"cross-file","outcome":"confirmed"}' \
    '{"kind":"finding_verification","finding_index":1,"category":"unused-symbol","outcome":"removed"}' \
    '{"ts":"2026-06-26T00:00:00Z","tier":"deep","input_tokens":1200,"output_tokens":300}' \
    > "$LOG"
}

# ── lpm_nav_from_stream: count + estimated tokens ────────────────────────────

@test "lpm_nav_from_stream: counts only navigation tool_use (mcp__lsp__ + Grep, not Write)" {
  _call lpm_nav_from_stream "$STREAM" "mcp__lsp__,Grep,Glob,Read,Bash"
  [ "$status" -eq 0 ]
  # t1 (mcp__lsp__find_references) + t2 (Grep) = 2; t3 (Write) excluded.
  calls="$(printf '%s' "$output" | cut -f1)"
  [ "$calls" -eq 2 ]
}

@test "lpm_nav_from_stream: nav tokens are a positive char/4 estimate of input+result" {
  _call lpm_nav_from_stream "$STREAM" "mcp__lsp__,Grep,Glob,Read,Bash"
  tokens="$(printf '%s' "$output" | cut -f2)"
  [ "$tokens" -gt 0 ]
}

@test "lpm_nav_from_stream: a restricted prefix set counts only matching tools" {
  # Only mcp__lsp__ counts → just t1.
  _call lpm_nav_from_stream "$STREAM" "mcp__lsp__"
  [ "$(printf '%s' "$output" | cut -f1)" -eq 1 ]
}

@test "lpm_nav_from_stream: missing transcript → 0 calls, 0 tokens (soft)" {
  _call lpm_nav_from_stream "$BATS_TEST_TMPDIR/nope.jsonl" "Grep"
  [ "$output" = "$(printf '0\t0')" ]
}

# ── lpm_usage_from_stream: real reported usage ───────────────────────────────

@test "lpm_usage_from_stream: reads input/cache/output/model from the result event" {
  _call lpm_usage_from_stream "$STREAM"
  [ "$output" = "$(printf '1200\t800\t300\tclaude-opus-4-8')" ]
}

# ── lpm_quality_from_log: findings / false positives ─────────────────────────

@test "lpm_quality_from_log: findings = verification records, fp = downgraded/removed" {
  _call lpm_quality_from_log "$LOG"
  # 2 finding_verification records; one outcome 'removed' → 1 false positive.
  [ "$output" = "$(printf '2\t1')" ]
}

@test "lpm_quality_from_log: no log → 0 findings, 0 fp" {
  _call lpm_quality_from_log "$BATS_TEST_TMPDIR/none.jsonl"
  [ "$output" = "$(printf '0\t0')" ]
}

# ── lpm_coldstart_from_log: seconds or null ──────────────────────────────────

@test "lpm_coldstart_from_log: derives seconds from cold_start_ms" {
  _call lpm_coldstart_from_log "$LOG"
  [ "$output" = "8.2" ]
}

@test "lpm_coldstart_from_log: no record → null" {
  printf '%s\n' '{"ts":"x","tier":"deep"}' > "$BATS_TEST_TMPDIR/nocold.jsonl"
  _call lpm_coldstart_from_log "$BATS_TEST_TMPDIR/nocold.jsonl"
  [ "$output" = "null" ]
}

# ── main: end-to-end record assembly ─────────────────────────────────────────

@test "main: assembles a valid pilot record for an lsp-on run" {
  run bash "$MEASURE" "$STREAM" --pr "petry-projects/.github-private#1@abc" \
    --variant lsp-on --candidate agent-lsp --model claude-opus-4-8 \
    --wall-time-s 173.0 --token-log "$LOG"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pr == "petry-projects/.github-private#1@abc"' >/dev/null
  echo "$output" | jq -e '.variant == "lsp-on" and .candidate == "agent-lsp"' >/dev/null
  echo "$output" | jq -e '.tool_calls == 2' >/dev/null
  echo "$output" | jq -e '.nav_tokens > 0' >/dev/null
  echo "$output" | jq -e '.input_tokens == 1200 and .cache_read_tokens == 800 and .output_tokens == 300' >/dev/null
  echo "$output" | jq -e '.findings == 2 and .false_positives == 1' >/dev/null
  echo "$output" | jq -e '.cold_start_s == 8.2' >/dev/null
  echo "$output" | jq -e '.wall_time_s == 173.0' >/dev/null
}

@test "main: lsp-off run forces cold_start_s to null (matches the frozen baseline)" {
  run bash "$MEASURE" "$STREAM" --pr "petry-projects/.github-private#1@abc" \
    --variant lsp-off --candidate baseline --model claude-opus-4-8 \
    --wall-time-s 188.0 --cold-start-ms 8200 --token-log "$LOG"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cold_start_s == null' >/dev/null
  echo "$output" | jq -e '.variant == "lsp-off"' >/dev/null
}

@test "main: missing required --pr fails loud (exit 2)" {
  run bash "$MEASURE" "$STREAM"
  [ "$status" -eq 2 ]
}

@test "main: a value-flag with no argument fails loud, not an unbound-var crash" {
  run bash "$MEASURE" "$STREAM" --pr "x" --variant
  [ "$status" -ne 0 ]
  [[ "$output" == *"--variant requires an argument"* ]]
}
