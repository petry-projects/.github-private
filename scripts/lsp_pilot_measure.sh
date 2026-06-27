#!/usr/bin/env bash
# lsp_pilot_measure.sh — turn ONE review run into ONE pilot-schema JSONL record
# (#844, epic #839). The companion to scripts/lsp_pilot_compare.sh: compare renders
# baseline-vs-candidate; measure PRODUCES the per-run records compare consumes.
#
# Why this exists: the review engine (scripts/engine.sh) emits aggregate token
# records + finding-verification records, but NOT the pilot's headline navigation
# fields (nav_tokens, tool_calls). Those are only observable in the model's
# tool-call transcript. So the pilot runner invokes claude with
# `--output-format stream-json --verbose`, tees the transcript, and hands it here.
#
# What it measures, and how (honest + documented — no field is invented):
#   tool_calls   COUNT of navigation tool_use events in the transcript (a tool is
#                "navigation" when its name starts with one of NAV_TOOL_PREFIXES).
#                This is symmetric across variants: LSP-off navigates with
#                Grep/Glob/Read/Bash; LSP-on navigates with mcp__lsp__*. Both are
#                counted by the same rule so the comparison is apples-to-apples.
#   nav_tokens   ESTIMATED tokens those navigation calls cost the context: for each
#                navigation tool_use, length(input)/4 + length(matching tool_result
#                content)/4 (the char/4 proxy the repo already uses in
#                estimate_tokens_from_file). It is the read+write context churn of
#                navigation — exactly the cost the LSP index is meant to cut. Marked
#                an estimate; the *_tokens / usage fields below are the engine's
#                real reported usage, not estimates.
#   findings /   From kind:"finding_verification" records on TOKEN_LOG_FILE (story
#   false_pos.   #843): findings = verification records; false_positives = those
#                whose outcome downgraded/removed the finding. Populated only when
#                the verification step ran (the LSP path); 0 otherwise — the quality
#                proxy is asymmetric by construction and documented as such.
#   cold_start_s From the kind:"lsp_cold_start" record (story #846): cold_start_ms/1000.
#                null for lsp-off (no server to launch) — matches the frozen baseline.
#   input/cache/ The run's REAL reported usage, read from the stream's terminal
#   output_tokens `result` event (.usage), falling back to the last assistant usage.
#   model        From --model, else the transcript's reported model.
#   wall_time_s  Passed in (the runner times the claude call end-to-end).
#
# Output: exactly one JSON object (the pilot record) on stdout, joinable against the
# baseline by its `pr` key and renderable by lsp_pilot_compare.sh.
#
# Pure/Testable: the lpm_* helpers read only their file/string args (no network),
# and main() only parses flags and prints — mirrors token_report.sh / the compare
# harness. Unit-tested in tests/dev-lead/unit/test_lsp_pilot_measure.bats.
#
# Usage:
#   lsp_pilot_measure.sh <stream-json-transcript> \
#     --pr "<repo>#<num>@<sha>" --variant lsp-on --candidate agent-lsp \
#     [--model claude-opus-4-8] [--wall-time-s 173.0] \
#     [--cold-start-ms 8200] [--token-log <file>] [--nav-prefixes "a,b,c"]

set -euo pipefail

# Navigation tool-name prefixes (a tool counts as navigation when its name starts
# with any of these). Override via NAV_TOOL_PREFIXES for a different toolset. The
# default set is symmetric across variants on purpose (see header).
NAV_TOOL_PREFIXES_DEFAULT="mcp__lsp__,Grep,Glob,Read,Bash"

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# _lpm_have_jq — jq is required for transcript parsing; fail loud if absent.
_lpm_have_jq() { command -v jq >/dev/null 2>&1; }

# lpm_nav_from_stream <stream_json> <nav_prefixes_csv>
# Emits "<tool_calls>\t<nav_tokens>" — the count of navigation tool_use events and
# the estimated tokens they cost (input + matching tool_result, char/4). A missing
# or unparseable transcript yields "0\t0" (Fail Loud upstream, soft here).
lpm_nav_from_stream() {
  local stream="$1" prefixes="${2:-$NAV_TOOL_PREFIXES_DEFAULT}"
  if [ ! -f "$stream" ] || ! _lpm_have_jq; then
    printf '0\t0\n'; return 0
  fi
  # Slurp the NDJSON: gather tool_use {id,name,input} and tool_result {id,content},
  # join on id, keep navigation names, sum char/4 of input + result content.
  jq -rs --arg prefixes "$prefixes" '
    ($prefixes | split(",") | map(select(length > 0))) as $pre |
    def is_nav($n): ($n != null) and ([ $pre[] | . as $p | ($n | startswith($p)) ] | any);
    # content can be a string or an array of {type,text}; normalize to a string.
    def text_of($c):
      if   ($c | type) == "string" then $c
      elif ($c | type) == "array"  then ([ $c[]? | (.text // (. | tostring)) ] | join(""))
      elif  $c == null             then ""
      else ($c | tostring) end;
    [ .[] | select(type=="object") ] as $events |
    [ $events[] | select(.type=="assistant") | (.message.content // [])[]?
        | select(.type=="tool_use") | {id, name, input: (.input // {})} ] as $uses |
    ( [ $events[] | select(.type=="user") | (.message.content // [])[]?
        | select(.type=="tool_result")
        | {id: .tool_use_id, content: text_of(.content)} ]
      | map({(.id): .content}) | add // {} ) as $results |
    ( [ $uses[] | select(is_nav(.name)) ] ) as $nav |
    ( $nav | length ) as $calls |
    ( [ $nav[]
        | ((.input | tostring | length) / 4)
        + (((($results[.id]) // "") | length) / 4)
      ] | add // 0 ) as $tokens |
    "\($calls)\t\($tokens | floor)"
  ' "$stream" 2>/dev/null || printf '0\t0\n'
}

# lpm_usage_from_stream <stream_json>
# Emits "<input>\t<cache_read>\t<output>\t<model>" from the terminal `result` event's
# .usage, falling back to the last assistant message usage. Zeros + "-" when absent.
lpm_usage_from_stream() {
  local stream="$1"
  if [ ! -f "$stream" ] || ! _lpm_have_jq; then
    printf '0\t0\t0\t-\n'; return 0
  fi
  jq -rs '
    [ .[] | select(type=="object") ] as $e |
    ( [ $e[] | select(.type=="result") ] | last ) as $r |
    ( [ $e[] | select(.type=="assistant") ] | last ) as $a |
    ( $r.usage // $a.message.usage // {} ) as $u |
    ( $r.model // $a.message.model // "-" ) as $m |
    "\(($u.input_tokens // 0))\t\(($u.cache_read_input_tokens // 0))\t\(($u.output_tokens // 0))\t\($m)"
  ' "$stream" 2>/dev/null || printf '0\t0\t0\t-\n'
}

# lpm_quality_from_log <token_log> <pr>
# Emits "<findings>\t<false_positives>" from kind:"finding_verification" records.
# false_positives = records whose outcome marks the finding downgraded/removed
# (outcome matching removed|downgrade|false_positive|refuted, case-insensitive).
# "0\t0" when the log is absent or has no verification records.
lpm_quality_from_log() {
  local log="$1"
  if [ ! -f "$log" ] || ! _lpm_have_jq; then
    printf '0\t0\n'; return 0
  fi
  jq -rs '
    [ .[] | select(type=="object") | select((.kind // "") == "finding_verification") ] as $v |
    ( $v | length ) as $findings |
    ( [ $v[] | (.outcome // "" | ascii_downcase)
        | select(test("removed|downgrade|false[_ ]?positive|refuted")) ] | length ) as $fp |
    "\($findings)\t\($fp)"
  ' "$log" 2>/dev/null || printf '0\t0\n'
}

# lpm_coldstart_from_log <token_log>
# Emits the cold-start seconds from the (last) kind:"lsp_cold_start" record, or the
# literal "null" when none exists (the lsp-off control, matching the frozen baseline).
lpm_coldstart_from_log() {
  local log="$1"
  if [ ! -f "$log" ] || ! _lpm_have_jq; then
    printf 'null\n'; return 0
  fi
  jq -rs '
    ( [ .[] | select(type=="object") | select((.kind // "") == "lsp_cold_start") ] | last ) as $c |
    if $c == null then "null" else (($c.cold_start_ms // 0) / 1000) end
  ' "$log" 2>/dev/null || printf 'null\n'
}

# lpm_record — assemble the pilot JSON record from already-extracted scalars.
# Args (all by flagless position): pr variant candidate model input cache output
#   nav_tokens tool_calls findings false_positives cold_start_s wall_time_s
lpm_record() {
  local pr="$1" variant="$2" candidate="$3" model="$4" input="$5" cache="$6" output="$7"
  local nav_tokens="$8" tool_calls="$9" findings="${10}" false_positives="${11}"
  local cold_start_s="${12}" wall_time_s="${13}"
  _lpm_have_jq || { echo "[lsp-pilot-measure] ERROR: jq required" >&2; return 2; }
  jq -cn \
    --arg pr "$pr" --arg variant "$variant" --arg candidate "$candidate" --arg model "$model" \
    --argjson input "${input:-0}" --argjson cache "${cache:-0}" --argjson output "${output:-0}" \
    --argjson nav_tokens "${nav_tokens:-0}" --argjson tool_calls "${tool_calls:-0}" \
    --argjson findings "${findings:-0}" --argjson false_positives "${false_positives:-0}" \
    --argjson cold_start_s "${cold_start_s:-null}" --argjson wall_time_s "${wall_time_s:-0}" \
    '{
       pr: $pr, variant: $variant, candidate: $candidate, model: $model,
       input_tokens: $input, cache_read_tokens: $cache, output_tokens: $output,
       nav_tokens: $nav_tokens, tool_calls: $tool_calls,
       findings: $findings, false_positives: $false_positives,
       cold_start_s: $cold_start_s, wall_time_s: $wall_time_s
     }'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  # Pre-flight: jq drives every parser; fail loud + early rather than letting the
  # helpers silently return zeros on a box without it.
  _lpm_have_jq || { echo "[lsp-pilot-measure] ERROR: jq is required but not installed" >&2; exit 1; }

  local stream="" pr="" variant="lsp-on" candidate="candidate" model=""
  local wall_time_s="0" cold_start_ms="" token_log=""
  local nav_prefixes="${NAV_TOOL_PREFIXES:-$NAV_TOOL_PREFIXES_DEFAULT}"

  # ${2?…} makes a value-flag with no argument fail loud under set -u (rather than
  # crashing on an unbound $2); shift 2 is then only reached when $2 exists.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr)            pr="${2?--pr requires an argument}"; shift 2 ;;
      --variant)       variant="${2?--variant requires an argument}"; shift 2 ;;
      --candidate)     candidate="${2?--candidate requires an argument}"; shift 2 ;;
      --model)         model="${2?--model requires an argument}"; shift 2 ;;
      --wall-time-s)   wall_time_s="${2?--wall-time-s requires an argument}"; shift 2 ;;
      --cold-start-ms) cold_start_ms="${2?--cold-start-ms requires an argument}"; shift 2 ;;
      --token-log)     token_log="${2?--token-log requires an argument}"; shift 2 ;;
      --nav-prefixes)  nav_prefixes="${2?--nav-prefixes requires an argument}"; shift 2 ;;
      -h|--help)       sed -n '1,40p' "$0"; exit 0 ;;
      --*)             echo "[lsp-pilot-measure] unknown flag: $1" >&2; exit 2 ;;
      *)               stream="$1"; shift ;;
    esac
  done

  if [ -z "$stream" ] || [ -z "$pr" ]; then
    echo "usage: $0 <stream-json> --pr <id> [--variant ..] [--candidate ..] [--model ..] [--wall-time-s ..] [--cold-start-ms ..] [--token-log ..]" >&2
    exit 2
  fi

  local calls nav_tokens input cache output stream_model findings fp cold_start_s
  IFS=$'\t' read -r calls nav_tokens < <(lpm_nav_from_stream "$stream" "$nav_prefixes")
  IFS=$'\t' read -r input cache output stream_model < <(lpm_usage_from_stream "$stream")
  IFS=$'\t' read -r findings fp < <(lpm_quality_from_log "$token_log")

  # cold-start: an explicit --cold-start-ms wins (the runner knows it directly);
  # else read it from the token log; else null for the lsp-off control.
  if [ -n "$cold_start_ms" ]; then
    case "$cold_start_ms" in
      ''|*[!0-9]*) cold_start_s="null" ;;
      *)           cold_start_s="$(awk "BEGIN { printf \"%.1f\", $cold_start_ms / 1000 }")" ;;
    esac
  else
    cold_start_s="$(lpm_coldstart_from_log "$token_log")"
  fi
  [ "$variant" = "lsp-off" ] && cold_start_s="null"

  [ -n "$model" ] || model="$stream_model"

  lpm_record "$pr" "$variant" "$candidate" "$model" \
    "$input" "$cache" "$output" "$nav_tokens" "$calls" \
    "$findings" "$fp" "$cold_start_s" "$wall_time_s"
}

# Run main only when executed directly (sourcing for unit tests must not run it).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
