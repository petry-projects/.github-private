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
#                   <input_tokens> <cache_read_tokens> <output_tokens> <context>
#                   [cache_write_tokens]
# Appends one JSONL record to TOKEN_LOG_FILE. No-op when TOKEN_LOG_FILE is unset.
# Silently swallows I/O errors so token logging never aborts a workflow run.
# cache_write_tokens (cache-creation) is optional and defaults to 0 for callers
# that do not capture it (backward compatible).
emit_token_record() {
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0

  local workflow="$1" tier="$2" engine="$3" model="$4"
  local input="${5:-0}" cache="${6:-0}" output="${7:-0}" context="${8:-}"
  local cache_write="${9:-0}"

  # Drop empty, model-less records: no model (empty or "-") AND zero usage across
  # every token count. These carry no signal — a dev-lead error/fallback branch can
  # emit one when usage failed to parse and no model was resolved — and they only
  # inflate the cost report's "no price" count and add a junk `- / -` cost-driver
  # row (#1009). A real model with an all-zero usage block is a legitimate empty
  # call and is still emitted. Counts are trusted integers (0-defaulted above).
  case "$model" in
    "" | "-")
      if [ "$(( input + cache + output + cache_write ))" -eq 0 ]; then
        return 0
      fi
      ;;
  esac

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
    --arg cache_write "$cache_write" \
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
      cache_creation_tokens: ($cache_write | tonumber? // 0),
      output_tokens: ($output | tonumber? // 0),
      et: ($et | tonumber? // 0),
      run_id: $run_id,
      context: $context
    }' 2>/dev/null) || return 0

  printf '%s\n' "$record" >> "$TOKEN_LOG_FILE" 2>/dev/null || true
}

# emit_verification_record <workflow> <tier> <outcome>
#                          <severity_before> <severity_after> <finding_index> <context>
# Appends one kind:"finding_verification" audit record to TOKEN_LOG_FILE (the
# shared Token Observatory JSONL channel). No-op when TOKEN_LOG_FILE is unset.
#
# These records are the false-positive-rate signal for the agentic-validation
# story (#1092, epic #1088): the deep tier's iterative-validation post-processor
# (scripts/lib/finding-verification.sh) emits one per verified logic/correctness
# finding, recording whether a repro confirmed / refuted / could-not-verify it and
# the resulting severity change. token_report.sh prices only records whose kind is
# "token_usage" (the default), so these audit records never pollute the cost report
# (story #843, pinned by tests/token_report.bats). Silently swallows I/O errors so
# verification logging never aborts a review.
emit_verification_record() {
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0

  local workflow="${1:-}" tier="${2:-}" outcome="${3:-}"
  local sev_before="${4:-}" sev_after="${5:-}" idx="${6:-0}" context="${7:-}"

  local ts run_id record
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  run_id="${GITHUB_RUN_ID:-}"

  record=$(jq -cn \
    --arg ts "$ts" \
    --arg workflow "$workflow" \
    --arg tier "$tier" \
    --arg outcome "$outcome" \
    --arg sb "$sev_before" \
    --arg sa "$sev_after" \
    --arg idx "$idx" \
    --arg run_id "$run_id" \
    --arg context "$context" \
    '{
      kind: "finding_verification",
      ts: $ts,
      workflow: $workflow,
      tier: $tier,
      outcome: $outcome,
      severity_before: $sb,
      severity_after: $sa,
      finding_index: ($idx | tonumber? // 0),
      run_id: $run_id,
      context: $context
    }' 2>/dev/null) || return 0

  printf '%s\n' "$record" >> "$TOKEN_LOG_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Real-usage capture (replaces the char/4 estimate when an engine reports usage)
#
# Engines that emit a machine-readable usage block (claude/gemini --output-format
# json) let us record actual input / cache-read / cache-write / output tokens
# instead of estimating. Parsers set these globals; engine.sh reads them:
#   LAST_USAGE_OK            1 when real usage was parsed, else 0 (→ estimate)
#   LAST_INPUT_TOKENS        non-cached input tokens
#   LAST_CACHE_READ_TOKENS   cache-hit (read) tokens
#   LAST_CACHE_WRITE_TOKENS  cache-creation (write) tokens
#   LAST_OUTPUT_TOKENS       output tokens
# ─────────────────────────────────────────────────────────────────────────────

# _engine_usage_sidecar
# Prints the path of the per-CALL usage sidecar (empty when TOKEN_LOG_FILE is
# unset). Engine invocations run inside a `cmd | tee` pipeline — i.e. a SUBSHELL —
# so the LAST_* globals they set never reach the parent; writing usage to this file
# (the filesystem is shared) lets _record_engine_tokens read it back.
#
# The key must be unique per concurrent engine call AND identical between the
# writer (the pipeline subshell) and the reader (the calling shell). $$ fails the
# first requirement: review-one-pr.sh backgrounds `run_agentic &` and `(run_duck) &`
# at the same time, and $$ stays the parent PID inside both, so they would collide
# on one sidecar. BASHPID fails the second: it differs between the pipe subshell
# and the caller. So each run_* exports _ENGINE_USAGE_OUT, derived from its own
# per-call mktemp file (unique by construction) and inherited by the pipeline
# subshell. The $$ form is only a fallback for any non-concurrent direct caller.
_engine_usage_sidecar() {
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0
  if [[ -n "${_ENGINE_USAGE_OUT:-}" ]]; then
    printf '%s' "$_ENGINE_USAGE_OUT"
  else
    printf '%s' "${TOKEN_LOG_FILE}.last-usage.$$"
  fi
}

# reset_engine_usage
# Clears the LAST_* usage globals and the sidecar file. Call before each engine
# invocation so a parse failure falls back to estimation rather than reusing a
# prior call's numbers.
reset_engine_usage() {
  LAST_USAGE_OK=0
  LAST_INPUT_TOKENS=0
  LAST_CACHE_READ_TOKENS=0
  LAST_CACHE_WRITE_TOKENS=0
  LAST_OUTPUT_TOKENS=0
  local f; f="$(_engine_usage_sidecar)"
  [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
}

# _usage_all_numeric <a> <b> <c> <d>
# True when every argument is a non-negative integer (guards against null/garbage
# from a malformed usage block).
_usage_all_numeric() {
  local v
  for v in "$@"; do
    case "$v" in
      ''|*[!0-9]*) return 1 ;;
    esac
  done
  return 0
}

# parse_engine_usage <engine> <json_file>
# Parses a usage block into the LAST_* globals. Returns 0 and sets LAST_USAGE_OK=1
# on success; returns 1 (LAST_USAGE_OK stays 0) when usage is absent/malformed so
# the caller estimates instead. Never aborts (safe under set -e via the `||` guards).
parse_engine_usage() {
  local engine="$1" file="$2"
  reset_engine_usage
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local i cr cw o
  case "$engine" in
    claude)
      # claude --print --output-format json → top-level .usage block.
      IFS=$'\t' read -r i cr cw o < <(jq -r '
        (.usage // {}) |
        [ (.input_tokens // 0), (.cache_read_input_tokens // 0),
          (.cache_creation_input_tokens // 0), (.output_tokens // 0) ] | @tsv
      ' "$file" 2>/dev/null) || return 1
      ;;
    gemini)
      # gemini --output-format json → .stats.models.<model>.tokens.
      # prompt = total input (includes cached); cached = cache-read; gemini bills
      # no separate cache-write, so cache_write = 0 and input = prompt - cached.
      local prompt cached
      IFS=$'\t' read -r prompt cached o < <(jq -r '
        ([.. | objects | select(has("tokens")) | .tokens] | first // {}) as $t |
        [ ($t.prompt // 0), ($t.cached // 0), (($t.candidates // $t.output // 0) + ($t.thoughts // 0)) ] | @tsv
      ' "$file" 2>/dev/null) || return 1
      _usage_all_numeric "$prompt" "$cached" "$o" || return 1
      cr="$cached"; cw=0
      i=$(( prompt > cached ? prompt - cached : prompt ))
      ;;
    *)
      return 1 ;;
  esac

  _usage_all_numeric "$i" "$cr" "$cw" "$o" || return 1
  # All-zero usually means the block was missing rather than a real empty call.
  [ "$i" -eq 0 ] && [ "$cr" -eq 0 ] && [ "$cw" -eq 0 ] && [ "$o" -eq 0 ] && return 1

  # These globals are consumed by engine.sh (which sources this lib); shellcheck
  # can't see the cross-file read.
  # shellcheck disable=SC2034
  LAST_INPUT_TOKENS="$i"
  # shellcheck disable=SC2034
  LAST_CACHE_READ_TOKENS="$cr"
  # shellcheck disable=SC2034
  LAST_CACHE_WRITE_TOKENS="$cw"
  # shellcheck disable=SC2034
  LAST_OUTPUT_TOKENS="$o"
  # shellcheck disable=SC2034
  LAST_USAGE_OK=1

  # Persist to the sidecar so a parent shell can read usage captured inside a
  # `cmd | tee` subshell.
  local f; f="$(_engine_usage_sidecar)"
  [ -n "$f" ] && printf '%s\t%s\t%s\t%s\n' "$i" "$cr" "$cw" "$o" > "$f" 2>/dev/null || true
  return 0
}

# extract_engine_text <engine> <json_file>
# Prints the human-readable result text from an engine's JSON envelope to stdout.
# Prints nothing when the field is absent (caller decides how to fall back).
extract_engine_text() {
  local engine="$1" file="$2"
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || { cat "$file" 2>/dev/null; return 0; }
  case "$engine" in
    claude) jq -j '.result // empty' "$file" 2>/dev/null ;;
    gemini) jq -j '(.response // .text // empty)' "$file" 2>/dev/null ;;
    *)      cat "$file" 2>/dev/null ;;
  esac
}
