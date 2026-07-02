#!/usr/bin/env bats
# Unit tests for scripts/lib/token-metrics.sh (TDD — written before implementation)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
TOKEN_LIB="$SCRIPT_DIR/scripts/lib/token-metrics.sh"

setup() {
  # shellcheck source=../../../scripts/lib/token-metrics.sh
  source "$TOKEN_LIB"
  TOKEN_LOG_FILE="$(mktemp)"
  export TOKEN_LOG_FILE
}

teardown() {
  [ -n "${TOKEN_LOG_FILE:-}" ] && rm -f "$TOKEN_LOG_FILE"
  unset TOKEN_LOG_FILE
}

# ── model_multiplier_for ──────────────────────────────────────────────────────

@test "model_multiplier_for: haiku 4.5 returns 1.0" {
  run model_multiplier_for "claude-haiku-4-5-20251001"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0" ]
}

@test "model_multiplier_for: sonnet 4.6 returns 3.0" {
  run model_multiplier_for "claude-sonnet-4-6"
  [ "$status" -eq 0 ]
  [ "$output" = "3.0" ]
}

@test "model_multiplier_for: opus 4.7 returns 5.0 (table-derived: \$5 input / \$1 haiku)" {
  run model_multiplier_for "claude-opus-4-7"
  [ "$status" -eq 0 ]
  [ "$output" = "5.0" ]
}

@test "model_multiplier_for: o4-mini returns 2.0" {
  run model_multiplier_for "o4-mini"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0" ]
}

@test "model_multiplier_for: gemini-2.0-flash returns 0.5" {
  run model_multiplier_for "gemini-2.0-flash"
  [ "$status" -eq 0 ]
  [ "$output" = "0.5" ]
}

@test "model_multiplier_for: gemini-1.5-pro returns 2.0" {
  run model_multiplier_for "gemini-1.5-pro"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0" ]
}

@test "model_multiplier_for: unknown model returns safe default 1.0" {
  run model_multiplier_for "some-future-model-v99"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0" ]
}

# ── calculate_et ──────────────────────────────────────────────────────────────

@test "calculate_et: I=1000 C=500 O=100 m=1.0 → 1450.00" {
  run calculate_et 1000 500 100 1.0
  [ "$status" -eq 0 ]
  [ "$output" = "1450.00" ]
}

@test "calculate_et: sonnet multiplier I=1000 C=500 O=100 m=3.0 → 4350.00" {
  run calculate_et 1000 500 100 3.0
  [ "$status" -eq 0 ]
  [ "$output" = "4350.00" ]
}

@test "calculate_et: zero tokens returns 0.00" {
  run calculate_et 0 0 0 1.0
  [ "$status" -eq 0 ]
  [ "$output" = "0.00" ]
}

@test "calculate_et: output tokens weighted 4x: I=0 C=0 O=100 m=1.0 → 400.00" {
  run calculate_et 0 0 100 1.0
  [ "$status" -eq 0 ]
  [ "$output" = "400.00" ]
}

@test "calculate_et: cache tokens weighted 0.1x: I=0 C=1000 O=0 m=1.0 → 100.00" {
  run calculate_et 0 1000 0 1.0
  [ "$status" -eq 0 ]
  [ "$output" = "100.00" ]
}

@test "calculate_et: opus audit example: I=1000 C=500 O=100 m=15.0 → 21750.00" {
  run calculate_et 1000 500 100 15.0
  [ "$status" -eq 0 ]
  [ "$output" = "21750.00" ]
}

# ── estimate_tokens_from_file ─────────────────────────────────────────────────

@test "estimate_tokens_from_file: 400 chars → 100 tokens" {
  local f
  f=$(mktemp)
  python3 -c "import sys; sys.stdout.write('a' * 400)" > "$f"
  run estimate_tokens_from_file "$f"
  rm -f "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "estimate_tokens_from_file: non-existent file returns 0" {
  run estimate_tokens_from_file "/tmp/nonexistent-$$-absent.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "estimate_tokens_from_file: empty file returns 0" {
  local f
  f=$(mktemp)
  run estimate_tokens_from_file "$f"
  rm -f "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "estimate_tokens_from_file: 1 char → 1 token (ceiling division)" {
  local f
  f=$(mktemp)
  printf 'x' > "$f"
  run estimate_tokens_from_file "$f"
  rm -f "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "estimate_tokens_from_file: 3 chars → 1 token (ceiling: ceil(3/4)=1)" {
  local f
  f=$(mktemp)
  printf 'abc' > "$f"
  run estimate_tokens_from_file "$f"
  rm -f "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ── emit_token_record ─────────────────────────────────────────────────────────

@test "emit_token_record: appends a valid JSONL line to TOKEN_LOG_FILE" {
  emit_token_record "pr-review" "triage" "claude" "claude-haiku-4-5-20251001" 1000 200 100 ""
  [ -s "$TOKEN_LOG_FILE" ]
  jq empty < "$TOKEN_LOG_FILE"
}

@test "emit_token_record: record contains correct workflow and tier fields" {
  emit_token_record "pr-review" "triage" "claude" "claude-haiku-4-5-20251001" 1000 200 100 ""
  local workflow tier
  workflow=$(jq -r '.workflow' < "$TOKEN_LOG_FILE")
  tier=$(jq -r '.tier' < "$TOKEN_LOG_FILE")
  [ "$workflow" = "pr-review" ]
  [ "$tier" = "triage" ]
}

@test "emit_token_record: record contains correct engine and model fields" {
  emit_token_record "dev-lead" "writer" "claude" "claude-sonnet-4-6" 2000 500 150 ""
  local engine model
  engine=$(jq -r '.engine' < "$TOKEN_LOG_FILE")
  model=$(jq -r '.model' < "$TOKEN_LOG_FILE")
  [ "$engine" = "claude" ]
  [ "$model" = "claude-sonnet-4-6" ]
}

@test "emit_token_record: et value matches formula for haiku" {
  # m=1.0, I=1000, C=200, O=100 → ET = 1.0*(1000 + 0.1*200 + 4*100) = 1420.00
  emit_token_record "pr-review" "triage" "claude" "claude-haiku-4-5-20251001" 1000 200 100 ""
  local et
  et=$(jq -r '.et' < "$TOKEN_LOG_FILE")
  [ "$et" = "1420.00" ]
}

@test "emit_token_record: et value matches formula for opus" {
  # m=5.0 (Opus 4.5+ = \$5 input), I=1000, C=500, O=100 → ET = 5.0*(1000+50+400) = 7250.00
  emit_token_record "pr-review" "audit" "claude" "claude-opus-4-7" 1000 500 100 ""
  local et
  et=$(jq -r '.et' < "$TOKEN_LOG_FILE")
  [ "$et" = "7250.00" ]
}

@test "emit_token_record: records cache_creation_tokens from the 9th arg" {
  emit_token_record "pr-review" "deep" "claude" "claude-sonnet-4-6" 1000 200 100 "" 350
  local cw
  cw=$(jq -r '.cache_creation_tokens' < "$TOKEN_LOG_FILE")
  [ "$cw" = "350" ]
}

@test "emit_token_record: cache_creation_tokens defaults to 0 when omitted" {
  emit_token_record "pr-review" "triage" "claude" "claude-haiku-4-5-20251001" 1000 200 100 ""
  local cw
  cw=$(jq -r '.cache_creation_tokens' < "$TOKEN_LOG_FILE")
  [ "$cw" = "0" ]
}

# ── emit_token_record: empty model-less all-zero suppression (#1009) ───────────

@test "emit_token_record: suppresses an empty model-less all-zero record" {
  # dev-lead error/fallback path emits (workflow, tier, engine, model="") with 0 usage.
  # Such a record carries no signal — it only inflates the report's "no price" count
  # and adds a junk `- / -` cost-driver row, so it must not be written at all.
  emit_token_record "dev-lead" "" "claude" "" 0 0 0 ""
  [ ! -s "$TOKEN_LOG_FILE" ]
}

@test "emit_token_record: suppresses a '-' model all-zero record (incl. cache_write)" {
  emit_token_record "dev-lead" "" "claude" "-" 0 0 0 "" 0
  [ ! -s "$TOKEN_LOG_FILE" ]
}

@test "emit_token_record: still emits a real model with an all-zero usage block" {
  # A genuine empty call (real model, zero tokens) is legitimate and must survive.
  emit_token_record "dev-lead" "writer" "claude" "claude-sonnet-4-6" 0 0 0 ""
  [ -s "$TOKEN_LOG_FILE" ]
  local model
  model=$(jq -r '.model' < "$TOKEN_LOG_FILE")
  [ "$model" = "claude-sonnet-4-6" ]
}

@test "emit_token_record: still emits a model-less record that carries real usage" {
  # Only the *all-zero AND model-less* case is junk; non-zero usage is real signal.
  emit_token_record "dev-lead" "writer" "claude" "" 100 0 50 ""
  [ -s "$TOKEN_LOG_FILE" ]
}

@test "emit_token_record: suppresses model-less record whose only tokens are cache_write" {
  # Guard must consider cache_write (9th arg), not just the first three counts.
  emit_token_record "dev-lead" "" "claude" "" 0 0 0 "" 0
  [ ! -s "$TOKEN_LOG_FILE" ]
  emit_token_record "dev-lead" "" "claude" "" 0 0 0 "" 25
  [ -s "$TOKEN_LOG_FILE" ]
}

# ── parse_engine_usage / extract_engine_text ──────────────────────────────────

@test "parse_engine_usage: claude JSON sets input/cache-read/cache-write/output" {
  local f; f=$(mktemp)
  printf '%s\n' '{"result":"hi","usage":{"input_tokens":1234,"cache_read_input_tokens":500,"cache_creation_input_tokens":300,"output_tokens":90}}' > "$f"
  run parse_engine_usage claude "$f"
  rm -f "$f"
  [ "$status" -eq 0 ]
}

@test "parse_engine_usage: claude globals carry the parsed values" {
  local f; f=$(mktemp)
  printf '%s\n' '{"result":"hi","usage":{"input_tokens":1234,"cache_read_input_tokens":500,"cache_creation_input_tokens":300,"output_tokens":90}}' > "$f"
  parse_engine_usage claude "$f"
  rm -f "$f"
  [ "$LAST_USAGE_OK" = "1" ]
  [ "$LAST_INPUT_TOKENS" = "1234" ]
  [ "$LAST_CACHE_READ_TOKENS" = "500" ]
  [ "$LAST_CACHE_WRITE_TOKENS" = "300" ]
  [ "$LAST_OUTPUT_TOKENS" = "90" ]
}

@test "parse_engine_usage: gemini computes non-cached input = prompt - cached" {
  local f; f=$(mktemp)
  printf '%s\n' '{"response":"hi","stats":{"models":{"g":{"tokens":{"prompt":500,"cached":100,"candidates":60}}}}}' > "$f"
  parse_engine_usage gemini "$f"
  rm -f "$f"
  [ "$LAST_USAGE_OK" = "1" ]
  [ "$LAST_INPUT_TOKENS" = "400" ]
  [ "$LAST_CACHE_READ_TOKENS" = "100" ]
  [ "$LAST_CACHE_WRITE_TOKENS" = "0" ]
  [ "$LAST_OUTPUT_TOKENS" = "60" ]
}

@test "parse_engine_usage: gemini adds thinking tokens to output count" {
  local f; f=$(mktemp)
  printf '%s\n' '{"response":"hi","stats":{"models":{"g":{"tokens":{"prompt":500,"cached":100,"candidates":60,"thoughts":25}}}}}' > "$f"
  parse_engine_usage gemini "$f"
  rm -f "$f"
  [ "$LAST_USAGE_OK" = "1" ]
  [ "$LAST_INPUT_TOKENS" = "400" ]
  [ "$LAST_CACHE_READ_TOKENS" = "100" ]
  [ "$LAST_OUTPUT_TOKENS" = "85" ]   # 60 candidates + 25 thoughts
}

@test "_engine_usage_sidecar: fallback path is \$\$-keyed when no per-call key set" {
  # Without a per-call _ENGINE_USAGE_OUT the sidecar falls back to a $$-keyed path.
  # NOTE: $$ does NOT isolate concurrent background jobs (they share the parent PID)
  # — per-call isolation comes from _ENGINE_USAGE_OUT (see the concurrency test).
  unset _ENGINE_USAGE_OUT
  local sidecar
  sidecar="$(_engine_usage_sidecar)"
  [ -n "$sidecar" ]
  [[ "$sidecar" == "${TOKEN_LOG_FILE}.last-usage.$$" ]]
}

@test "parse_engine_usage: missing usage block returns non-zero (→ estimate)" {
  local f; f=$(mktemp)
  printf '%s\n' '{"result":"no usage here"}' > "$f"
  run parse_engine_usage claude "$f"
  rm -f "$f"
  [ "$status" -ne 0 ]
}

@test "extract_engine_text: claude returns the .result text" {
  local f; f=$(mktemp)
  printf '%s\n' '{"result":"hello world","usage":{}}' > "$f"
  run extract_engine_text claude "$f"
  rm -f "$f"
  [ "$output" = "hello world" ]
}

@test "emit_token_record: is a no-op when TOKEN_LOG_FILE is unset" {
  unset TOKEN_LOG_FILE
  run emit_token_record "pr-review" "triage" "claude" "haiku" 100 0 50 ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit_token_record: appends on multiple calls without truncating" {
  emit_token_record "pr-review" "triage" "claude" "claude-haiku-4-5-20251001" 100 0 50 ""
  emit_token_record "pr-review" "deep" "claude" "claude-sonnet-4-6" 5000 1000 200 ""
  local count
  count=$(wc -l < "$TOKEN_LOG_FILE")
  [ "$count" -eq 2 ]
  while IFS= read -r line; do
    echo "$line" | jq empty
  done < "$TOKEN_LOG_FILE"
}

@test "emit_token_record: ts field is a non-empty ISO-8601 timestamp" {
  emit_token_record "dev-lead" "writer" "claude" "claude-sonnet-4-6" 2000 500 150 ""
  local ts
  ts=$(jq -r '.ts' < "$TOKEN_LOG_FILE")
  [ -n "$ts" ]
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "emit_token_record: includes context field (pr_url)" {
  emit_token_record "pr-review" "deep" "claude" "claude-sonnet-4-6" 5000 0 300 "https://github.com/org/repo/pull/42"
  local context
  context=$(jq -r '.context' < "$TOKEN_LOG_FILE")
  [ "$context" = "https://github.com/org/repo/pull/42" ]
}

@test "emit_token_record: escapes quoted and multiline context as valid JSONL" {
  local context='line "one"
line two'
  emit_token_record "pr-review" "deep" "claude" "claude-sonnet-4-6" 5000 0 300 "$context"
  jq empty < "$TOKEN_LOG_FILE"
  local parsed
  parsed=$(jq -r '.context' < "$TOKEN_LOG_FILE")
  [ "$parsed" = "$context" ]
}

@test "emit_token_record: is non-fatal when TOKEN_LOG_FILE path is unwritable" {
  export TOKEN_LOG_FILE="/proc/nonexistent-readonly-path/token.jsonl"
  run emit_token_record "pr-review" "triage" "claude" "haiku" 100 0 50 ""
  [ "$status" -eq 0 ]
}

# ── usage sidecar keying (concurrency safety) ─────────────────────────────────

@test "_engine_usage_sidecar: uses the exported per-call key when set" {
  export _ENGINE_USAGE_OUT="$TOKEN_LOG_FILE.callX.usage"
  run _engine_usage_sidecar
  unset _ENGINE_USAGE_OUT
  [ "$output" = "$TOKEN_LOG_FILE.callX.usage" ]
}

@test "_engine_usage_sidecar: set-but-empty key falls back to \$\$ (mktemp-failure state)" {
  # run_* clears _ENGINE_USAGE_OUT before mktemp; if mktemp fails the key is empty/
  # unset and MUST fall back rather than reuse a prior/inherited key.
  export _ENGINE_USAGE_OUT=""
  run _engine_usage_sidecar
  unset _ENGINE_USAGE_OUT
  [ "$output" = "$TOKEN_LOG_FILE.last-usage.$$" ]
}

@test "_engine_usage_sidecar: empty when TOKEN_LOG_FILE is unset" {
  unset TOKEN_LOG_FILE _ENGINE_USAGE_OUT
  run _engine_usage_sidecar
  [ -z "$output" ]
}

@test "usage sidecar: concurrent calls sharing \$\$ stay isolated (no cross-read)" {
  # Reproduces the review-one-pr.sh pattern: two engine calls backgrounded at once.
  # Background subshells share the parent's $$, so a $$-keyed sidecar would collide;
  # the per-call _ENGINE_USAGE_OUT (unique mktemp path) must keep them isolated.
  local dir; dir="$(mktemp -d)"
  printf '%s' '{"result":"a","usage":{"input_tokens":111,"cache_read_input_tokens":1,"cache_creation_input_tokens":2,"output_tokens":11}}' > "$dir/a.json"
  printf '%s' '{"result":"b","usage":{"input_tokens":222,"cache_read_input_tokens":3,"cache_creation_input_tokens":4,"output_tokens":22}}' > "$dir/b.json"
  (
    export _ENGINE_USAGE_OUT="$dir/A.usage"
    parse_engine_usage claude "$dir/a.json"
    sleep 0.3   # widen the race window for any colliding writer
    cut -f1 < "$(_engine_usage_sidecar)" > "$dir/a.out"
  ) &
  (
    export _ENGINE_USAGE_OUT="$dir/B.usage"
    parse_engine_usage claude "$dir/b.json"
    sleep 0.3
    cut -f1 < "$(_engine_usage_sidecar)" > "$dir/b.out"
  ) &
  wait
  local a b; a="$(cat "$dir/a.out")"; b="$(cat "$dir/b.out")"
  rm -rf "$dir"
  [ "$a" = "111" ]
  [ "$b" = "222" ]
}
