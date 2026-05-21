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

@test "model_multiplier_for: opus 4.7 returns 15.0" {
  run model_multiplier_for "claude-opus-4-7"
  [ "$status" -eq 0 ]
  [ "$output" = "15.0" ]
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
  # m=15.0, I=1000, C=500, O=100 → ET = 15.0*(1000+50+400) = 21750.00
  emit_token_record "pr-review" "audit" "claude" "claude-opus-4-7" 1000 500 100 ""
  local et
  et=$(jq -r '.et' < "$TOKEN_LOG_FILE")
  [ "$et" = "21750.00" ]
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
