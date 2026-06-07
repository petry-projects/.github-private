#!/usr/bin/env bash
set -euo pipefail

# Token Metrics Library — Effective Tokens (ET) metric + JSONL logging
#
# Provides cost visibility for the pr-review and dev-lead agents.
# ET formula (GitHub's framework): ET = m × (1.0×I + 0.1×C + 4.0×O)
#   I = input tokens, C = cache-read tokens, O = output tokens
#   m = model cost multiplier (relative to claude-haiku-4-5 = 1.0)
#
# Usage:
#   source scripts/lib/token-metrics.sh
#   emit_token_record <workflow> <tier> <engine> <model> \
#                     <input_tokens> <cache_tokens> <output_tokens> <context>
#
# Environment:
#   TOKEN_LOG_FILE  — path to JSONL output file; unset → all functions are no-ops.
#   GITHUB_RUN_ID   — included in JSONL records when available.
#
# All functions are safe to call even when TOKEN_LOG_FILE is unset or unwritable.

# Load the dated price table so ET multipliers derive from the same source as USD cost
# (and can never drift apart). Best-effort: if the lib is absent, model_multiplier_for
# falls back to a static table so this file stays self-contained.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/model-pricing.sh" ]; then
  # shellcheck source=scripts/lib/model-pricing.sh
  source "$(dirname "${BASH_SOURCE[0]}")/model-pricing.sh"
fi

# model_multiplier_for <model_name>
# Returns a float cost multiplier relative to claude-haiku-4-5 = 1.0, derived from
# model-pricing.tsv at today's rate. Prints 1.0 for unknown models (safe default).
model_multiplier_for() {
  local model="$1"
  if declare -f et_multiplier_for >/dev/null 2>&1; then
    et_multiplier_for "$model"
    return
  fi
  # Fallback static table (used only if model-pricing.sh failed to load).
  case "$model" in
    *haiku*)                    echo "1.0" ;;
    *sonnet*)                   echo "3.0" ;;
    *opus*)                     echo "5.0" ;;
    o4-mini | *o4-mini*)        echo "2.0" ;;
    *gemini*flash*)             echo "0.5" ;;
    *gemini*pro*)               echo "2.0" ;;
    *)                          echo "1.0" ;;
  esac
}

# calculate_et <input_tokens> <cache_tokens> <output_tokens> <multiplier>
# Returns ET = multiplier × (1.0×input + 0.1×cache + 4.0×output), two decimal places.
calculate_et() {
  local input="${1:-0}" cache="${2:-0}" output="${3:-0}" mult="${4:-1.0}"
  awk "BEGIN { printf \"%.2f\", $mult * (1.0 * $input + 0.1 * $cache + 4.0 * $output) }"
}

# estimate_tokens_from_file <file>
# Returns ceiling(byte_count / 4) as a rough token estimate (4 chars ≈ 1 token).
# Returns 0 if the file does not exist or is empty.
estimate_tokens_from_file() {
  local file="${1:-}"
  [ -f "$file" ] || { echo "0"; return 0; }
  local chars
  chars=$(wc -c < "$file" 2>/dev/null || echo "0")
  awk "BEGIN { printf \"%d\", int(($chars + 3) / 4) }"
}

# emit_token_record <workflow> <tier> <engine> <model>
#                   <input_tokens> <cache_tokens> <output_tokens> <context>
# Appends one JSONL record to TOKEN_LOG_FILE. No-op when TOKEN_LOG_FILE is unset.
# Silently swallows I/O errors so token logging never aborts a workflow run.
emit_token_record() {
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0

  local workflow="$1" tier="$2" engine="$3" model="$4"
  local input="${5:-0}" cache="${6:-0}" output="${7:-0}" context="${8:-}"

  local mult et ts run_id record
  mult=$(model_multiplier_for "$model")
  et=$(calculate_et "$input" "$cache" "$output" "$mult")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  run_id="${GITHUB_RUN_ID:-}"

  record=$(jq -cn \
    --arg ts "$ts" \
    --arg workflow "$workflow" \
    --arg tier "$tier" \
    --arg engine "$engine" \
    --arg model "$model" \
    --arg input "$input" \
    --arg cache "$cache" \
    --arg output "$output" \
    --arg et "$et" \
    --arg run_id "$run_id" \
    --arg context "$context" \
    '{
      ts: $ts,
      workflow: $workflow,
      tier: $tier,
      engine: $engine,
      model: $model,
      input_tokens: ($input | tonumber? // 0),
      cache_read_tokens: ($cache | tonumber? // 0),
      output_tokens: ($output | tonumber? // 0),
      et: ($et | tonumber? // 0),
      run_id: $run_id,
      context: $context
    }' 2>/dev/null) || return 0

  printf '%s\n' "$record" >> "$TOKEN_LOG_FILE" 2>/dev/null || true
}
