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

  local pr model inp ca out nav tool find fp cold wall
  while IFS=$'\t' read -r pr model inp ca out nav tool find fp cold wall; do
    [ -n "$pr" ] || continue
    local mult usd known=1
    mult="$(et_multiplier_for "$model")"
    [ -z "$mult" ] && mult=1.0
    usd="$(cost_usd "$model" "$inp" "$ca" "$out")"
    if [ -z "$usd" ]; then usd=0; known=0; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pr" "$nav" "$tool" "$find" "$fp" "$cold" "$wall" "$mult" "$inp" "$ca" "$out" "$usd" "$known"
  done < <(jq -r 'select(type=="object") | [
      (.pr // "unknown"), (.model // "-"),
      (.input_tokens // 0), (.cache_read_tokens // 0), (.output_tokens // 0),
      (.nav_tokens // 0), (.tool_calls // 0), (.findings // 0), (.false_positives // 0),
      (if (.cold_start_s == null) then "null" else (.cold_start_s|tostring) end),
      (.wall_time_s // 0)
    ] | @tsv' "$jsonl" 2>/dev/null) | awk -F'\t' '
    {
      pr = $1; n[pr]++
      nav[pr]  += $2; tool[pr] += $3; find[pr] += $4; fp[pr] += $5
      wall[pr] += $7
      mult = $8; inp = $9; ca = $10; out = $11; usd_val = $12; known_val = $13
      et_val = mult * (1.0 * inp + 0.1 * ca + 4.0 * out)
      et[pr]   += et_val; usd[pr]  += usd_val
      if (known_val == 0) unk[pr] = 1
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
    }' | sort
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

  printf '# 🔬 LSP pilot comparison — `%s` vs frozen LSP-off baseline\n\n' "$name"
  printf '_Speed (cold-start, wall-time) · cost (nav tokens, tool calls, ET, USD) · '
  printf 'quality (findings, false positives), LSP-on vs the immutable LSP-off control._\n\n'
  printf '**Quality proxy:** a PR regresses when its **false-positive** count exceeds the '
  printf "frozen baseline's (precision dropped). A navigation-token win that costs "
  printf 'precision is a no-go.\n\n'

  awk -F'\t' '
    function fmt_int(n,   neg, s, r) {
      n = int(n + 0.5); s = ""; if (n < 0) { neg = 1; n = -n }
      if (n == 0) s = "0"
      while (n > 0) {
        r = n % 1000; n = int(n / 1000);
        s = (n > 0) ? sprintf("%03d", r) (s == "" ? "" : "," s) : r (s == "" ? "" : "," s)
      }
      return (neg ? "-" : "") s
    }

    function fmt_usd(v) {
      return sprintf("$%.2f", v)
    }

    # First file: baseline aggregate
    NR == FNR {
      pr = $1
      b_nav[pr] = $2; b_tool[pr] = $3; b_find[pr] = $4; b_fp[pr] = $5
      b_cold[pr] = $6; b_wall[pr] = $7; b_et[pr] = $8; b_usd[pr] = $9
      next
    }

    # Print header on transition to candidate aggregate
    NR > FNR && !candidate_header_printed {
      print "## Per PR (off → on)\n"
      print "| PR | Nav tokens | Nav reduction | Tool calls | Cold start | Wall time | ET | USD | Findings | False positives | Quality |"
      print "|---|---|---:|---|---:|---|---:|---:|---|---:|:--|"
      candidate_header_printed = 1
    }

    # Second file: candidate aggregate
    {
      pr = $1
      nav = $2; tool = $3; find = $4; fp = $5; cold = $6; wall = $7; et = $8; usd = $9

      bnav = b_nav[pr]
      btool = b_tool[pr]
      bfind = b_find[pr]
      bfp = b_fp[pr]
      bwall = b_wall[pr]
      bet = b_et[pr]
      busd = b_usd[pr]

      if (nav > 0) ratio = sprintf("%.1fx", bnav / nav); else ratio = "—"

      if (fp > bfp) {
        quality = "⚠️ REGRESSION"
        any_regression = 1
      } else {
        quality = "ok"
      }

      if (cold == "NA") {
        coldcell = "N/A → N/A"
      } else {
        coldcell = "N/A → " cold "s"
        cold_sum += cold
        cold_n++
      }

      printf "| \`%s\` | %s → %s | %s | %s → %s | %s | %ss → %ss | %s → %s | %s → %s | %s → %s | %s → %s | %s |\n",
        pr,
        fmt_int(bnav), fmt_int(nav), ratio,
        fmt_int(btool), fmt_int(tool),
        coldcell,
        bwall, wall,
        fmt_int(bet), fmt_int(et),
        fmt_usd(busd), fmt_usd(usd),
        fmt_int(bfind), fmt_int(find),
        fmt_int(bfp), fmt_int(fp),
        quality

      tot_bnav += bnav; tot_cnav += nav
      tot_bet += bet; tot_cet += et
      tot_busd += busd; tot_cusd += usd
      tot_bfind += bfind; tot_cfind += find
      tot_bfp += bfp; tot_cfp += fp
    }

    END {
      if (tot_cnav > 0) overall_ratio = sprintf("%.1fx", tot_bnav / tot_cnav); else overall_ratio = "—"
      if (cold_n > 0) mean_cold = sprintf("%.1fs", cold_sum / cold_n); else mean_cold = "N/A"

      print "\n## Aggregate\n"
      printf "- **Navigation tool-call tokens:** %s (off) → %s (on) — **%s** reduction\n", fmt_int(tot_bnav), fmt_int(tot_cnav), overall_ratio
      printf "- **ET:** %s (off) → %s (on)\n", fmt_int(tot_bet), fmt_int(tot_cet)
      printf "- **USD:** %s (off) → %s (on)\n", fmt_usd(tot_busd), fmt_usd(tot_cusd)
      printf "- **Mean LSP-on cold start:** %s (baseline N/A — no server)\n", mean_cold
      printf "- **Findings:** %s (off) → %s (on)\n", fmt_int(tot_bfind), fmt_int(tot_cfind)
      printf "- **False positives:** %s (off) → %s (on)\n", fmt_int(tot_bfp), fmt_int(tot_cfp)

      if (any_regression == 1) {
        print "- **Quality verdict:** ⚠️ **REGRESSION** — at least one PR has more false positives than the frozen baseline."
      } else {
        print "- **Quality verdict:** ✅ **PASS** — no PR exceeds the frozen baseline false-positive count."
      }
    }
  ' <(echo "$bagg") <(echo "$cagg")

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
