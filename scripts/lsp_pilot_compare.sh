#!/usr/bin/env bash
# lsp_pilot_compare.sh — LSP-pilot comparison harness (#841, epic #839).
#
# Compares a candidate LSP-ON review run against the FROZEN LSP-off baseline
# captured once under evals/lsp-pilot/holdout/baseline-lsp-off.jsonl. It renders
# per-PR and aggregate deltas for:
#   * speed   — cold-start (N/A for the LSP-off control), wall-time
#   * cost    — navigation tool-call tokens, tool-call count, ET, USD
#   * quality — findings and labelled false-positives (the explicit proxy below)
#
# It FAILS LOUD (non-zero) when a candidate PR has no baseline counterpart, so a
# partial corpus can never masquerade as a clean comparison (the success metric
# requires every candidate be scored against the fixed, frozen target).
#
# Review-quality proxy (explicit, not ad hoc): quality per PR is
# (findings, false_positives). A candidate REGRESSES on a PR when its
# false_positive count exceeds the frozen baseline's — i.e. precision dropped. A
# navigation-token win that costs precision is a no-go, so this is mandatory.
#
# Record shape (one JSON object per line, both baseline and candidate streams) —
# a Token Cost Observatory record (scripts/lib/token-metrics.sh) plus pilot fields:
#   pr               "<repo>#<number>@<head_sha>" — the immutable join key
#   variant          "lsp-off" | "lsp-on"
#   candidate        "baseline" | "<server-name>"
#   model            model id (priced via scripts/lib/model-pricing.tsv)
#   input_tokens / cache_read_tokens / output_tokens
#   nav_tokens       navigation tool-call tokens
#   tool_calls       navigation tool-call count
#   findings         review findings count
#   false_positives  labelled false-positive count (quality proxy)
#   cold_start_s     server launch->query-ready seconds (null/N/A for lsp-off)
#   wall_time_s      end-to-end review seconds
# A candidate PR may appear on multiple lines (the corpus allows <=3 runs/PR);
# such runs are aggregated by mean.
#
# Layout (mirrors scripts/token_report.sh): the render_* / lp_* functions are
# PURE (no network) and unit-tested in tests/lsp_pilot_compare.bats; main() only
# resolves paths and prints.
#
# Usage:
#   bash scripts/lsp_pilot_compare.sh <baseline.jsonl> <candidate.jsonl> [name]

set -euo pipefail

# Reuse the single USD/int formatters (AGENTS.md "Cost reporting") and the dated
# pricing helpers (cost_usd, et_multiplier_for). Sourcing token_report.sh does not
# run its main() (guarded by the BASH_SOURCE check at its foot).
_LP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/token_report.sh
source "${_LP_DIR}/token_report.sh"

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# _lp_prs <jsonl> — emit the sorted-unique set of pr identifiers in a stream.
_lp_prs() {
  local jsonl="$1"
  [ -f "$jsonl" ] || return 0
  jq -r 'select(type=="object") | .pr // empty' "$jsonl" 2>/dev/null | sort -u
}

# lp_missing_baselines <baseline_jsonl> <candidate_jsonl>
# Prints every candidate pr that has no baseline counterpart (one per line).
# Returns 1 if any are missing, else 0. This is the AC5 coverage guard.
lp_missing_baselines() {
  local baseline="$1" candidate="$2" missing
  missing="$(comm -13 <(_lp_prs "$baseline") <(_lp_prs "$candidate"))"
  if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
    return 1
  fi
  return 0
}

# _lp_aggregate <jsonl> — fold a stream to one mean row per pr. Pricing (ET, USD)
# is computed per record from the dated price table, then averaged. Columns:
#   1 pr  2 nav  3 tool_calls  4 findings  5 false_positives
#   6 cold_start(mean | "NA")  7 wall_time  8 et  9 usd  10 usd_unknown(1/0)
# Pure: reads only the JSONL and the local price table.
_lp_aggregate() {
  local jsonl="$1"
  [ -f "$jsonl" ] || return 0

  local enriched; enriched="$(mktemp)"
  local pr model inp ca out nav tool find fp cold wall
  while IFS=$'\t' read -r pr model inp ca out nav tool find fp cold wall; do
    [ -n "$pr" ] || continue
    local mult et usd known=1
    mult="$(et_multiplier_for "$model")"
    et="$(awk -v m="$mult" -v i="$inp" -v c="$ca" -v o="$out" \
      'BEGIN { printf "%.4f", m * (1.0 * i + 0.1 * c + 4.0 * o) }')"
    usd="$(cost_usd "$model" "$inp" "$ca" "$out")"
    if [ -z "$usd" ]; then usd=0; known=0; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pr" "$nav" "$tool" "$find" "$fp" "$cold" "$wall" "$et" "$usd" "$known"
  done < <(jq -r 'select(type=="object") | [
      (.pr // "unknown"), (.model // "-"),
      (.input_tokens // 0), (.cache_read_tokens // 0), (.output_tokens // 0),
      (.nav_tokens // 0), (.tool_calls // 0), (.findings // 0), (.false_positives // 0),
      (if (.cold_start_s == null) then "null" else (.cold_start_s|tostring) end),
      (.wall_time_s // 0)
    ] | @tsv' "$jsonl" 2>/dev/null) > "$enriched"

  awk -F'\t' '
    {
      pr = $1; n[pr]++
      nav[pr]  += $2; tool[pr] += $3; find[pr] += $4; fp[pr] += $5
      wall[pr] += $7; et[pr]   += $8; usd[pr]  += $9
      if ($10 == 0) unk[pr] = 1
      if ($6 != "null" && $6 != "" && $6 != "NA") { cold[pr] += $6; coldn[pr]++ }
    }
    END {
      for (pr in n) {
        c = n[pr]
        coldval = (coldn[pr] > 0) ? sprintf("%.1f", cold[pr] / coldn[pr]) : "NA"
        printf "%s\t%.1f\t%.1f\t%.2f\t%.2f\t%s\t%.1f\t%.4f\t%.6f\t%d\n",
          pr, nav[pr]/c, tool[pr]/c, find[pr]/c, fp[pr]/c, coldval,
          wall[pr]/c, et[pr]/c, usd[pr]/c, (unk[pr] ? 1 : 0)
      }
    }' "$enriched" | sort
  rm -f "$enriched"
}

# _lp_ratio <baseline> <candidate> — baseline/candidate as "N.Nx" (— if candidate is 0).
_lp_ratio() {
  awk -v b="$1" -v c="$2" 'BEGIN { if (c > 0) printf "%.1fx", b / c; else printf "—" }'
}

# render_lsp_comparison <baseline_jsonl> <candidate_jsonl> [candidate_name]
# Writes the Markdown comparison to stdout. Returns non-zero (AC5) WITHOUT
# emitting a clean comparison when any candidate PR lacks a baseline counterpart.
render_lsp_comparison() {
  local baseline="$1" candidate="$2" name="${3:-candidate}"

  if [ ! -f "$baseline" ] || [ ! -f "$candidate" ]; then
    echo "[lsp-pilot] ERROR: baseline and candidate JSONL paths are both required" >&2
    return 2
  fi

  # AC5 — fail loud on any candidate PR with no frozen baseline counterpart.
  local missing
  if ! missing="$(lp_missing_baselines "$baseline" "$candidate")"; then
    printf '# ❌ LSP pilot comparison — INCOMPLETE\n\n'
    printf 'Candidate run has PR(s) with **no frozen LSP-off baseline counterpart**, so '
    printf 'this is not a clean comparison against the fixed target. Refusing to score.\n\n'
    printf 'Missing baseline for:\n\n'
    local pr
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      printf -- '- `%s`\n' "$pr"
    done <<< "$missing"
    return 1
  fi

  local bagg cagg
  bagg="$(_lp_aggregate "$baseline")"
  cagg="$(_lp_aggregate "$candidate")"

  # Index the baseline aggregate by pr.
  declare -A B_NAV B_TOOL B_FIND B_FP B_WALL B_ET B_USD
  local pr nav tool find fp cold wall et usd unk
  while IFS=$'\t' read -r pr nav tool find fp cold wall et usd unk; do
    [ -n "$pr" ] || continue
    B_NAV["$pr"]="$nav"; B_TOOL["$pr"]="$tool"; B_FIND["$pr"]="$find"
    B_FP["$pr"]="$fp";   B_WALL["$pr"]="$wall"; B_ET["$pr"]="$et"; B_USD["$pr"]="$usd"
  done <<< "$bagg"

  printf '# 🔬 LSP pilot comparison — `%s` vs frozen LSP-off baseline\n\n' "$name"
  printf '_Speed (cold-start, wall-time) · cost (nav tokens, tool calls, ET, USD) · '
  printf 'quality (findings, false positives), LSP-on vs the immutable LSP-off control._\n\n'
  printf '**Quality proxy:** a PR regresses when its **false-positive** count exceeds the '
  printf 'frozen baseline'"'"'s (precision dropped). A navigation-token win that costs '
  printf 'precision is a no-go.\n\n'

  printf '## Per PR (off → on)\n\n'
  printf '| PR | Nav tokens | Nav reduction | Tool calls | Cold start | Wall time | ET | USD | Findings | False positives | Quality |\n'
  printf '|---|---|---:|---|---:|---|---:|---:|---|---:|:--|\n'

  local tot_bnav=0 tot_cnav=0 tot_bet=0 tot_cet=0 tot_busd=0 tot_cusd=0
  local tot_bfind=0 tot_cfind=0 tot_bfp=0 tot_cfp=0 cold_sum=0 cold_n=0
  local any_regression=0

  while IFS=$'\t' read -r pr nav tool find fp cold wall et usd unk; do
    [ -n "$pr" ] || continue
    local bnav="${B_NAV[$pr]}" btool="${B_TOOL[$pr]}" bfind="${B_FIND[$pr]}"
    local bfp="${B_FP[$pr]}" bwall="${B_WALL[$pr]}" bet="${B_ET[$pr]}" busd="${B_USD[$pr]}"

    local ratio; ratio="$(_lp_ratio "$bnav" "$nav")"
    local regressed quality
    regressed="$(awk -v c="$fp" -v b="$bfp" 'BEGIN { print (c > b) ? 1 : 0 }')"
    if [ "$regressed" -eq 1 ]; then quality="⚠️ REGRESSION"; any_regression=1; else quality="ok"; fi

    local coldcell="N/A → ${cold}s"
    [ "$cold" = "NA" ] && coldcell="N/A → N/A"

    printf '| `%s` | %s → %s | %s | %s → %s | %s | %ss → %ss | %s → %s | %s → %s | %s → %s | %s → %s | %s |\n' \
      "$pr" \
      "$(_fmt_int "$bnav")" "$(_fmt_int "$nav")" "$ratio" \
      "$(_fmt_int "$btool")" "$(_fmt_int "$tool")" \
      "$coldcell" \
      "$bwall" "$wall" \
      "$(_fmt_int "$bet")" "$(_fmt_int "$et")" \
      "$(_fmt_usd "$busd")" "$(_fmt_usd "$usd")" \
      "$(_fmt_int "$bfind")" "$(_fmt_int "$find")" \
      "$(_fmt_int "$bfp")" "$(_fmt_int "$fp")" \
      "$quality"

    tot_bnav="$(awk -v a="$tot_bnav" -v b="$bnav" 'BEGIN{print a+b}')"
    tot_cnav="$(awk -v a="$tot_cnav" -v b="$nav"  'BEGIN{print a+b}')"
    tot_bet="$(awk  -v a="$tot_bet"  -v b="$bet"  'BEGIN{print a+b}')"
    tot_cet="$(awk  -v a="$tot_cet"  -v b="$et"   'BEGIN{print a+b}')"
    tot_busd="$(awk -v a="$tot_busd" -v b="$busd" 'BEGIN{print a+b}')"
    tot_cusd="$(awk -v a="$tot_cusd" -v b="$usd"  'BEGIN{print a+b}')"
    tot_bfind="$(awk -v a="$tot_bfind" -v b="$bfind" 'BEGIN{print a+b}')"
    tot_cfind="$(awk -v a="$tot_cfind" -v b="$find"  'BEGIN{print a+b}')"
    tot_bfp="$(awk -v a="$tot_bfp" -v b="$bfp" 'BEGIN{print a+b}')"
    tot_cfp="$(awk -v a="$tot_cfp" -v b="$fp"  'BEGIN{print a+b}')"
    if [ "$cold" != "NA" ]; then
      cold_sum="$(awk -v a="$cold_sum" -v b="$cold" 'BEGIN{print a+b}')"
      cold_n=$((cold_n + 1))
    fi
  done <<< "$cagg"

  local overall_ratio mean_cold
  overall_ratio="$(_lp_ratio "$tot_bnav" "$tot_cnav")"
  if [ "$cold_n" -gt 0 ]; then
    mean_cold="$(awk -v s="$cold_sum" -v n="$cold_n" 'BEGIN{printf "%.1fs", s/n}')"
  else
    mean_cold="N/A"
  fi

  printf '\n## Aggregate\n\n'
  printf -- '- **Navigation tool-call tokens:** %s (off) → %s (on) — **%s** reduction\n' \
    "$(_fmt_int "$tot_bnav")" "$(_fmt_int "$tot_cnav")" "$overall_ratio"
  printf -- '- **ET:** %s (off) → %s (on)\n' "$(_fmt_int "$tot_bet")" "$(_fmt_int "$tot_cet")"
  printf -- '- **USD:** %s (off) → %s (on)\n' "$(_fmt_usd "$tot_busd")" "$(_fmt_usd "$tot_cusd")"
  printf -- '- **Mean LSP-on cold start:** %s (baseline N/A — no server)\n' "$mean_cold"
  printf -- '- **Findings:** %s (off) → %s (on)\n' "$(_fmt_int "$tot_bfind")" "$(_fmt_int "$tot_cfind")"
  printf -- '- **False positives:** %s (off) → %s (on)\n' "$(_fmt_int "$tot_bfp")" "$(_fmt_int "$tot_cfp")"

  if [ "$any_regression" -eq 1 ]; then
    printf -- '- **Quality verdict:** ⚠️ **REGRESSION** — at least one PR has more false positives than the frozen baseline.\n'
  else
    printf -- '- **Quality verdict:** ✅ **PASS** — no PR exceeds the frozen baseline false-positive count.\n'
  fi

  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  if [ "$#" -lt 2 ]; then
    echo "usage: $0 <baseline.jsonl> <candidate.jsonl> [candidate-name]" >&2
    exit 2
  fi
  render_lsp_comparison "$@"
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
