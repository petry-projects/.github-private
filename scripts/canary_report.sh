#!/usr/bin/env bash
# canary_report.sh — deep-tier model canary go/no-go report (#1951, epic #1895).
#
# Turns a directory of pr-review token-usage JSONL artifacts into a mechanical
# PASS / FAIL / INSUFFICIENT table comparing a CANDIDATE model against an
# INCUMBENT model on the three bars #1899's go/no-go depends on:
#
#   • cost per invocation   — candidate must be ≥ 20% lower
#   • cache-read cost        — candidate must be ≥ 50% lower
#   • latency (duration_ms)  — candidate must be ≥ 20% better
#
# The overall verdict is PASS only when all three PASS. Exit codes encode it so a
# workflow can gate on it: 0 = PASS, 1 = FAIL, 2 = INSUFFICIENT. Missing data
# never reads as PASS — a metric with too small a sample (or no latency signal)
# is INSUFFICIENT, not PASS.
#
# Layout mirrors token_report.sh:
#   * canary_annotate / render_canary_report are PURE — they read a directory of
#     JSONL files and write Markdown to stdout (unit-tested in
#     tests/canary_report.bats, no network).
#   * main() does the network I/O: it downloads this repo's token-usage-*
#     artifacts over a window, REUSING token_report.sh's collection helpers
#     (_gh_timeout / _extract_zip / _collect_one_artifact), or reads a local
#     directory (--dir) — so it can also score a model-ab-tokens-* snapshot.
#
# Pricing is delegated to price_for <model> <record-date> from
# scripts/lib/model-pricing.sh (the same effective-dated model-pricing.tsv source
# token_report.sh uses). Records whose model has no price on their date are
# COUNTED and REPORTED as unpriced — never silently dropped, never treated as $0.
#
# ── Sample selection (maintainer defaults, #1951 comment 2026-09-26) ──────────
#   Candidate (canary): distinct pr-review PRs on pr-review/v1-next whose deep-tier
#   record carries model=<candidate>. First --candidate-max-prs (10) distinct PRs
#   in time order at/after --since (the canary window start). A deep-tier call that
#   fell back to another model is listed separately and counts toward neither arm.
#
#   Incumbent (baseline): tier=deep, model=<incumbent> records from the 14 days
#   before the canary cut — --baseline-since 2026-09-11T14:07Z /
#   --baseline-until 2026-09-25T14:07Z by default.
#
#   Latency is only scored on records inside these windows (candidate at/after
#   --since; incumbent inside the baseline window), so pre-#1949 records with no
#   duration_ms surface as INSUFFICIENT latency rather than a false PASS.
#
# ── Baseline expiry — snapshot before it is gone ──────────────────────────────
#   token-usage artifacts are retained 30 days (pr-review.yml upload step). The
#   last Opus 4.8 deep-tier records predate the 2026-09-25 14:07Z canary cut and
#   EXPIRE around 2026-10-25. Snapshot a baseline directory BEFORE then:
#
#     GH_TOKEN=<pat> bash scripts/canary_report.sh \
#       --collect-only --dir ./canary-baseline \
#       --since 2026-09-11T14:07Z --until 2026-09-25T14:07Z
#
#   then score offline any time later with --dir ./canary-baseline.
#
# ── Controlled comparison (model-ab, identical inputs, #1950) ─────────────────
#   Point --model-ab-dir at a model-ab-tokens-* artifact directory to render a
#   SEPARATE section that scores both arms from that directory (both ran on
#   identical inputs). It is reported beside — never merged with — the real-PR
#   section.
#
# COST CAP: read-only over existing artifacts. It makes NO model calls.
#
# Usage:
#   GH_TOKEN=<pat> bash scripts/canary_report.sh --since 2026-09-25T14:07Z
#   bash scripts/canary_report.sh --dir ./canary-baseline
#   bash scripts/canary_report.sh --model-ab-dir ./model-ab-tokens

set -euo pipefail

# Reuse token_report.sh's pricing (price_for), formatters (_fmt_usd/_fmt_int) and
# artifact-collection helpers (_gh_timeout / _extract_zip / _collect_one_artifact).
# Sourcing does not run its main() (guarded by BASH_SOURCE == $0 there).
_CANARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/token_report.sh
source "${_CANARY_DIR}/token_report.sh"

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# _fmt_pct <fraction>  → "NN%" (fraction 0.225 → "23%"). Negative preserved
# (e.g. -0.2 → "-20%") so a regression is never rendered as a reduction. Uses
# printf "%.0f" (not "%d") to avoid integer overflow/truncation on older awks.
_fmt_pct() {
  awk -v v="${1:-0}" 'BEGIN { printf "%.0f%%", int(v * 100 + (v < 0 ? -0.5 : 0.5)) }'
}

# _fmt_ms <ms>  → integer milliseconds, or "n/a" for the -1 sentinel.
_fmt_ms() {
  awk -v v="${1:-0}" 'BEGIN { if (v < 0) printf "n/a"; else printf "%d ms", int(v + 0.5) }'
}

# _norm_iso <iso8601>  → the same instant at seconds precision, so a minute-precision
# window bound (…THH:MMZ) compares correctly (lexically) against seconds-precision
# record timestamps (…THH:MM:SSZ). Without this, "…14:07:30Z" sorts BEFORE the
# "…14:07Z" bound (':' < 'Z'), excluding candidate artifacts created in the cutoff
# minute while including them in the baseline (#1953). Empty stays empty.
_norm_iso() {
  local t="${1-}"
  case "$t" in
    "")                            printf '' ;;
    *T[0-9][0-9]:[0-9][0-9]Z)      printf '%s:00Z' "${t%Z}" ;;
    *T[0-9][0-9]:[0-9][0-9])       printf '%s:00'  "$t" ;;
    *)                             printf '%s' "$t" ;;
  esac
}

# _combine_verdict <rc1> <rc2>  → the worse go/no-go exit code of the two report
# sections: any FAIL (1) wins over any INSUFFICIENT (2), which wins over PASS (0).
# So a controlled-comparison FAIL is never masked by a real-PR PASS (#1953).
_combine_verdict() {
  if [ "$1" = 1 ] || [ "$2" = 1 ]; then printf 1
  elif [ "$1" = 2 ] || [ "$2" = 2 ]; then printf 2
  else printf 0; fi
}

# _fmt_usd_or_na <dollars>  → the org 2-decimal USD formatter (_fmt_usd), or "n/a"
# for the -1 sentinel. Surfaced USD must go through the shared cents formatter per
# AGENTS.md "Cost reporting"; the reduction % column and the USD/1M-token row are
# the fine-grained comparators when cent precision is too coarse.
_fmt_usd_or_na() {
  local v="${1:-0}"
  if awk -v v="$v" 'BEGIN { exit !(v < 0) }'; then
    printf 'n/a'
  else
    _fmt_usd "$v"
  fi
}

# canary_annotate <jsonl_dir>
# One enriched TSV row per token_usage record, priced via price_for at the
# record's own date. Columns:
#   1 ts  2 workflow  3 tier  4 model  5 input  6 cache_read  7 cache_write
#   8 output  9 context  10 duration_ms (empty when null)
#   11 cost_usd (-1 when unpriced)  12 cache_read_cost_usd (-1 when unpriced)
#   13 known (1 priced / 0 unpriced)
canary_annotate() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [ -e "${files[0]}" ] || return 0   # no JSONL files → no rows

  # Join with the ASCII unit separator (0x1F), NOT a tab: bash `read` treats tab
  # as IFS whitespace and collapses runs of it, so a record with an empty context
  # and a populated duration_ms would shift duration into ctx and lose it. A
  # non-whitespace delimiter preserves every field, empty ones included (#1953).
  jq -r 'select(type == "object")
    | select((.kind // "token_usage") == "token_usage")
    | [ (.ts // "-"), (.workflow // "-"), (.tier // "-"), (.model // "-"),
        (.input_tokens // 0 | tostring), (.cache_read_tokens // 0 | tostring),
        (.cache_creation_tokens // 0 | tostring), (.output_tokens // 0 | tostring),
        (.context // ""),
        (if (.duration_ms == null) then "" else (.duration_ms | tostring) end)
      ] | join("\u001f")' "${files[@]}" 2>/dev/null \
  | while IFS=$'\037' read -r ts wf tier model inp cr cw out ctx dur; do
      local date price cost crcost known
      date="${ts:0:10}"
      price="$(price_for "$model" "$date")"
      if [ -n "$price" ]; then
        local pin pcr pcw pout
        read -r pin pcr pcw pout <<< "$price"
        cost="$(awk -v i="$inp" -v c="$cr" -v w="$cw" -v o="$out" \
          -v pin="$pin" -v pcr="$pcr" -v pcw="$pcw" -v pout="$pout" \
          'BEGIN { printf "%.6f", (i * pin + c * pcr + w * pcw + o * pout) / 1000000 }')"
        crcost="$(awk -v c="$cr" -v pcr="$pcr" 'BEGIN { printf "%.6f", c * pcr / 1000000 }')"
        known=1
      else
        cost="-1"; crcost="-1"; known=0
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$wf" "$tier" "$model" "$inp" "$cr" "$cw" "$out" "$ctx" "$dur" \
        "$cost" "$crcost" "$known"
    done
}

# _canary_arm_metrics <enriched_arm_file>  (stdout: one TSV metrics row)
# Columns: inv prs priced unpriced mean_cost p50_cost mean_cr p50_cr
#          mean_dur p50_dur durc total_cost usd_per_minput
# -1 marks an undefined mean/median (no priced rows / no durations).
_canary_arm_metrics() {
  awk -F'\t' '
    function qsort(a, lo, hi,   i, j, p, t) {
      # In-place quicksort — O(n log n) average, so the incumbent arm (which can
      # collect thousands of records over the 14-day baseline) does not hit the
      # O(n^2) wall the old bubble sort did.
      if (lo >= hi) return
      i = lo; j = hi; p = a[int((lo + hi) / 2)]
      while (i <= j) {
        while (a[i] < p) i++
        while (a[j] > p) j--
        if (i <= j) { t = a[i]; a[i] = a[j]; a[j] = t; i++; j-- }
      }
      qsort(a, lo, j)
      qsort(a, i, hi)
    }
    function median(a, n,   i, b) {
      if (n <= 0) return -1
      for (i = 1; i <= n; i++) b[i] = a[i]
      qsort(b, 1, n)
      if (n % 2 == 1) return b[(n + 1) / 2]
      return (b[n / 2] + b[n / 2 + 1]) / 2
    }
    {
      inv++
      ctx = $9
      if (ctx != "" && !(ctx in seen)) { seen[ctx] = 1; prs++ }
      if ($13 == 1) {
        priced++
        costs[priced] = $11 + 0; total_cost += $11 + 0
        crs[priced]   = $12 + 0; cr_total   += $12 + 0
        input_equiv  += ($5 + 0) + ($6 + 0)
      } else { unpriced++ }
      if ($10 != "") { durc++; durs[durc] = $10 + 0; dur_total += $10 + 0 }
    }
    END {
      mean_cost = (priced > 0) ? total_cost / priced : -1
      mean_cr   = (priced > 0) ? cr_total   / priced : -1
      mean_dur  = (durc   > 0) ? dur_total  / durc   : -1
      usd_per_m = (input_equiv > 0) ? total_cost / input_equiv * 1000000 : -1
      printf "%d\t%d\t%d\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.3f\t%.3f\t%d\t%.6f\t%.6f\n",
        inv + 0, prs + 0, priced + 0, unpriced + 0,
        mean_cost, median(costs, priced), mean_cr, median(crs, priced),
        mean_dur, median(durs, durc), durc + 0, total_cost + 0, usd_per_m
    }'
}

# _bar_status <candidate_mean> <incumbent_mean> <bar_fraction>
# PASS when candidate is at least (bar) lower/better: cand <= inc * (1 - bar).
# INSUFFICIENT when the incumbent figure is not a positive number (no basis).
_bar_status() {
  awk -v c="$1" -v i="$2" -v bar="$3" 'BEGIN {
    if (i <= 0 || c < 0) { print "INSUFFICIENT"; exit }
    if (c <= i * (1 - bar)) print "PASS"; else print "FAIL"
  }'
}

# render_canary_report <jsonl_dir>
# Pure: filters by workflow/tier, splits arms by model, applies the sample
# windows + candidate cap, scores the three bars and prints the Markdown report.
# Returns 0 (PASS) / 1 (FAIL) / 2 (INSUFFICIENT). Configured via CANARY_* env
# (main() sets these from CLI flags; tests set them directly):
#   CANARY_CANDIDATE CANARY_INCUMBENT CANARY_WORKFLOW CANARY_TIER
#   CANARY_SINCE CANARY_UNTIL CANARY_BASELINE_SINCE CANARY_BASELINE_UNTIL
#   CANARY_MAX_PRS CANARY_MIN_PRS CANARY_MIN_INVOCATIONS
#   CANARY_COST_BAR CANARY_CACHE_BAR CANARY_LATENCY_BAR
#   CANARY_LABEL CANARY_MODE (real|controlled)
render_canary_report() {
  local dir="$1"
  local candidate incumbent workflow tier since until b_since b_until
  local max_prs min_prs min_inv cost_bar cache_bar latency_bar label mode
  candidate="${CANARY_CANDIDATE:-claude-opus-5-5}"
  incumbent="${CANARY_INCUMBENT:-claude-opus-4-8}"
  workflow="${CANARY_WORKFLOW:-pr-review}"
  tier="${CANARY_TIER:-deep}"
  since="${CANARY_SINCE-}"
  until="${CANARY_UNTIL-}"
  b_since="${CANARY_BASELINE_SINCE-2026-09-11T14:07Z}"
  b_until="${CANARY_BASELINE_UNTIL-2026-09-25T14:07Z}"
  max_prs="${CANARY_MAX_PRS-10}"
  min_prs="${CANARY_MIN_PRS-5}"
  min_inv="${CANARY_MIN_INVOCATIONS-5}"
  cost_bar="${CANARY_COST_BAR-0.20}"
  cache_bar="${CANARY_CACHE_BAR-0.50}"
  latency_bar="${CANARY_LATENCY_BAR-0.20}"
  label="${CANARY_LABEL-Canary go/no-go — real PRs}"
  mode="${CANARY_MODE-real}"

  local enriched; enriched="$(mktemp)" || { echo "ERROR: failed to create temporary file" >&2; return 1; }
  canary_annotate "$dir" > "$enriched"

  # Split into candidate / incumbent / fallback arms, applying the sample windows.
  # In controlled mode both arms come from identical inputs, so windows + cap are
  # inert (empty windows) — the arms are split by model alone.
  local cand_file inc_file fb_file
  cand_file="$(mktemp)" || { echo "ERROR: failed to create temporary file" >&2; return 1; }
  inc_file="$(mktemp)"  || { echo "ERROR: failed to create temporary file" >&2; return 1; }
  fb_file="$(mktemp)"   || { echo "ERROR: failed to create temporary file" >&2; return 1; }

  local c_since c_until
  if [ "$mode" = "real" ]; then c_since="$since"; c_until="$until"; else c_since=""; c_until=""; fi
  awk -F'\t' -v wf="$workflow" -v tier="$tier" -v m="$candidate" \
      -v s="$c_since" -v u="$c_until" \
    '$2 == wf && $3 == tier && $4 == m {
       if (s != "" && $1 < s) next
       if (u != "" && $1 > u) next
       print
     }' "$enriched" > "$cand_file"

  local i_since i_until
  if [ "$mode" = "real" ]; then i_since="$b_since"; i_until="$b_until"; else i_since=""; i_until=""; fi
  awk -F'\t' -v wf="$workflow" -v tier="$tier" -v m="$incumbent" \
      -v s="$i_since" -v u="$i_until" \
    '$2 == wf && $3 == tier && $4 == m {
       if (s != "" && $1 < s) next
       if (u != "" && $1 > u) next
       print
     }' "$enriched" > "$inc_file"

  # Fallback = deep-tier calls in the CANDIDATE (canary) window that fell back to a
  # non-candidate/non-incumbent model. Apply the candidate window so historical
  # fallback records outside the canary period are not reported as part of the
  # comparison (inert in controlled mode, where the window is empty).
  awk -F'\t' -v wf="$workflow" -v tier="$tier" -v c="$candidate" -v i="$incumbent" \
      -v s="$c_since" -v u="$c_until" \
    '$2 == wf && $3 == tier && $4 != c && $4 != i {
       if (s != "" && $1 < s) next
       if (u != "" && $1 > u) next
       print
     }' "$enriched" > "$fb_file"

  # Candidate cap: keep only the first max_prs distinct PR contexts in time order
  # (earliest ts per context). Real mode only; a non-positive cap disables it.
  if [ "$mode" = "real" ] && [ "$max_prs" -gt 0 ]; then
    local allowed capped
    allowed="$(awk -F'\t' '$9 != "" { if (!($9 in first) || $1 < first[$9]) first[$9] = $1 }
                 END { for (k in first) printf "%s\t%s\n", first[k], k }' "$cand_file" \
               | sort -t$'\t' -k1,1 | awk -F'\t' -v n="$max_prs" 'NR <= n { print $2 }')"
    # Only apply the cap when at least one candidate record carries a context to
    # cap on. If every candidate record has an empty context, "allowed" is empty
    # and the awk filter would match nothing — mv'ing that empty file over
    # cand_file would silently drop all candidate data (→ a bogus INSUFFICIENT).
    # Leaving cand_file untouched lets the distinct-PR guard report the real state.
    if [ -n "$allowed" ]; then
      capped="$(mktemp)" || { echo "ERROR: failed to create temporary file" >&2; return 1; }
      awk -F'\t' -v allow="$allowed" 'BEGIN { n = split(allow, a, "\n"); for (k = 1; k <= n; k++) keep[a[k]] = 1 }
        $9 in keep { print }' "$cand_file" > "$capped"
      mv "$capped" "$cand_file"
    fi
  fi

  # Per-arm metrics.
  local cm im
  cm="$(_canary_arm_metrics < "$cand_file")"
  im="$(_canary_arm_metrics < "$inc_file")"
  [ -n "$cm" ] || cm=$'0\t0\t0\t0\t-1\t-1\t-1\t-1\t-1\t-1\t0\t0\t-1'
  [ -n "$im" ] || im=$'0\t0\t0\t0\t-1\t-1\t-1\t-1\t-1\t-1\t0\t0\t-1'

  local c_inv c_prs c_priced c_unpr c_mcost c_pcost c_mcr c_mdur c_pdur c_durc c_perm
  local i_inv i_prs i_priced i_unpr i_mcost i_pcost i_mcr i_mdur i_pdur i_durc i_perm
  # _pcr (p50 cache-read) and _tcost (arm total) are computed but not surfaced.
  IFS=$'\t' read -r c_inv c_prs c_priced c_unpr c_mcost c_pcost c_mcr _ c_mdur c_pdur c_durc _ c_perm <<< "$cm"
  IFS=$'\t' read -r i_inv i_prs i_priced i_unpr i_mcost i_pcost i_mcr _ i_mdur i_pdur i_durc _ i_perm <<< "$im"

  # Sample-size guard shared by every metric (never let a thin sample read as PASS).
  # Real mode counts DISTINCT candidate PRs (min_prs) because each real PR is one
  # independent observation. Controlled mode (model-ab) runs held-out cases without
  # a PR_URL context, so it has zero distinct PRs by construction — there the guard
  # is per-arm INVOCATIONS (min_inv), or every controlled run would be INSUFFICIENT.
  local base_insuff=0
  if [ "$mode" = "controlled" ]; then
    [ "$c_inv" -lt "$min_inv" ] && base_insuff=1
    [ "$i_inv" -lt "$min_inv" ] && base_insuff=1
  else
    [ "$c_prs" -lt "$min_prs" ] && base_insuff=1
    [ "$i_inv" -lt "$min_inv" ] && base_insuff=1
  fi

  # Any unpriced candidate record has an UNKNOWN cost, so it is excluded from the
  # mean-cost denominator — a candidate with costly unpriced calls could otherwise
  # show a cheap mean over its priced subset and earn a misleading cost PASS. When
  # the candidate arm has unpriced records we cannot certify a genuine cost/cache
  # win, so both bars are INSUFFICIENT (never PASS on partial pricing).
  local cost_status cache_status latency_status
  if [ "$base_insuff" -eq 1 ] || [ "$c_priced" -eq 0 ] || [ "$i_priced" -eq 0 ] || [ "$c_unpr" -gt 0 ]; then
    cost_status="INSUFFICIENT"; cache_status="INSUFFICIENT"
  else
    cost_status="$(_bar_status "$c_mcost" "$i_mcost" "$cost_bar")"
    cache_status="$(_bar_status "$c_mcr" "$i_mcr" "$cache_bar")"
  fi
  # Latency needs the SAME sample floor as the other bars: it is not enough for each
  # arm to carry a single non-null duration. Require at least min_inv durations per
  # arm, so a five-invocation comparison with duration on only one call each stays
  # INSUFFICIENT instead of scoring a bogus one-pair PASS.
  if [ "$base_insuff" -eq 1 ] || [ "$c_durc" -lt "$min_inv" ] || [ "$i_durc" -lt "$min_inv" ]; then
    latency_status="INSUFFICIENT"
  else
    latency_status="$(_bar_status "$c_mdur" "$i_mdur" "$latency_bar")"
  fi

  # Overall: a definite FAIL is a no-go; else any INSUFFICIENT is a no-go; else PASS.
  local overall rc
  if [ "$cost_status" = "FAIL" ] || [ "$cache_status" = "FAIL" ] || [ "$latency_status" = "FAIL" ]; then
    overall="FAIL"; rc=1
  elif [ "$cost_status" = "INSUFFICIENT" ] || [ "$cache_status" = "INSUFFICIENT" ] || [ "$latency_status" = "INSUFFICIENT" ]; then
    overall="INSUFFICIENT"; rc=2
  else
    overall="PASS"; rc=0
  fi

  # Reductions (candidate vs incumbent), for display.
  local cost_red cache_red lat_red
  cost_red="$(awk -v c="$c_mcost" -v i="$i_mcost" 'BEGIN { print (i > 0 && c >= 0) ? (i - c) / i : -999 }')"
  cache_red="$(awk -v c="$c_mcr" -v i="$i_mcr" 'BEGIN { print (i > 0 && c >= 0) ? (i - c) / i : -999 }')"
  lat_red="$(awk -v c="$c_mdur" -v i="$i_mdur" 'BEGIN { print (i > 0 && c >= 0) ? (i - c) / i : -999 }')"

  # ── Render ─────────────────────────────────────────────────────────────────
  printf '## %s\n\n' "$label"
  printf '_Candidate `%s` vs incumbent `%s` · workflow `%s` · tier `%s`_\n\n' \
    "$candidate" "$incumbent" "$workflow" "$tier"
  printf 'Priced per `scripts/lib/model-pricing.tsv` at each record'"'"'s date. '
  printf 'Bars: cost/inv ≥ %s lower · cache-read ≥ %s lower · latency ≥ %s better.\n\n' \
    "$(_fmt_pct "$cost_bar")" "$(_fmt_pct "$cache_bar")" "$(_fmt_pct "$latency_bar")"

  printf '### Per-arm figures\n\n'
  printf '| Metric | Candidate | Incumbent |\n|---|---:|---:|\n'
  printf '| Invocations | %s | %s |\n' "$(_fmt_int "$c_inv")" "$(_fmt_int "$i_inv")"
  printf '| Distinct PRs | %s | %s |\n' "$(_fmt_int "$c_prs")" "$(_fmt_int "$i_prs")"
  printf '| Unpriced records | %s | %s |\n' "$(_fmt_int "$c_unpr")" "$(_fmt_int "$i_unpr")"
  printf '| Mean USD / invocation | %s | %s |\n' "$(_fmt_usd_or_na "$c_mcost")" "$(_fmt_usd_or_na "$i_mcost")"
  printf '| p50 USD / invocation | %s | %s |\n' "$(_fmt_usd_or_na "$c_pcost")" "$(_fmt_usd_or_na "$i_pcost")"
  printf '| Mean cache-read USD / invocation | %s | %s |\n' "$(_fmt_usd_or_na "$c_mcr")" "$(_fmt_usd_or_na "$i_mcr")"
  printf '| Mean duration | %s | %s |\n' "$(_fmt_ms "$c_mdur")" "$(_fmt_ms "$i_mdur")"
  printf '| p50 duration | %s | %s |\n' "$(_fmt_ms "$c_pdur")" "$(_fmt_ms "$i_pdur")"
  printf '| USD / 1M input-equivalent tokens (context only) | %s | %s |\n\n' \
    "$(_fmt_usd_or_na "$c_perm")" "$(_fmt_usd_or_na "$i_perm")"

  printf '### Verdict per bar\n\n'
  printf '| Bar | Candidate | Incumbent | Reduction | Result |\n|---|---:|---:|---:|:--|\n'
  printf '| Cost per invocation (≥ %s lower) | %s | %s | %s | %s |\n' \
    "$(_fmt_pct "$cost_bar")" "$(_fmt_usd_or_na "$c_mcost")" "$(_fmt_usd_or_na "$i_mcost")" \
    "$( [ "$cost_red" = "-999" ] && printf 'n/a' || _fmt_pct "$cost_red" )" "$cost_status"
  printf '| Cache-read cost per invocation (≥ %s lower) | %s | %s | %s | %s |\n' \
    "$(_fmt_pct "$cache_bar")" "$(_fmt_usd_or_na "$c_mcr")" "$(_fmt_usd_or_na "$i_mcr")" \
    "$( [ "$cache_red" = "-999" ] && printf 'n/a' || _fmt_pct "$cache_red" )" "$cache_status"
  printf '| Latency / duration_ms (≥ %s better) | %s | %s | %s | %s |\n\n' \
    "$(_fmt_pct "$latency_bar")" "$(_fmt_ms "$c_mdur")" "$(_fmt_ms "$i_mdur")" \
    "$( [ "$lat_red" = "-999" ] && printf 'n/a' || _fmt_pct "$lat_red" )" "$latency_status"

  # Fallback deep-tier calls (excluded from both arms) — listed, never merged.
  local fb_rows
  fb_rows="$(awk -F'\t' '{ c[$4]++ } END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$fb_file" | sort)"
  if [ -n "$fb_rows" ]; then
    printf '### Deep-tier fallback calls (excluded from both arms)\n\n'
    printf '| Model | Calls |\n|---|---:|\n'
    while IFS=$'\t' read -r fbm fbc; do
      [ -n "$fbm" ] || continue
      printf '| `%s` | %s |\n' "$fbm" "$(_fmt_int "$fbc")"
    done <<< "$fb_rows"
    printf '\n'
  fi

  # Machine-readable verdict block (stable tokens for scripting / tests).
  printf '### Machine-readable verdict\n\n'
  printf '```\n'
  printf -- '- candidate invocations: %s\n' "$c_inv"
  printf -- '- candidate distinct PRs: %s\n' "$c_prs"
  printf -- '- candidate unpriced records: %s\n' "$c_unpr"
  printf -- '- incumbent invocations: %s\n' "$i_inv"
  printf -- '- incumbent distinct PRs: %s\n' "$i_prs"
  printf -- '- incumbent unpriced records: %s\n' "$i_unpr"
  printf -- '- cost: %s\n' "$cost_status"
  printf -- '- cache_read: %s\n' "$cache_status"
  printf -- '- latency: %s\n' "$latency_status"
  printf '```\n\n'
  printf '**Overall verdict:** %s (exit %s)\n\n' "$overall" "$rc"

  rm -f "$enriched" "$cand_file" "$inc_file" "$fb_file"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

ARTIFACT_OP_TIMEOUT="${ARTIFACT_OP_TIMEOUT:-60}"

# collect_repo_jsonl <repo> <since> <until> <jsonl_dir>  (stdout: artifact_count)
# Lists <repo>'s token-usage-* artifacts created within [since, until] and
# downloads/extracts them into jsonl_dir, REUSING token_report.sh's per-artifact
# helpers. A failed listing is fatal (returns 1) — a canary must never score a
# silently-empty download as data. A PARTIAL download is fatal too (returns 1): if
# any selected artifact yields no records (download/extract failure — the shared
# helper only warns), the sample is incomplete and scoring it could report a PASS
# on missing evidence, so we refuse rather than score partial data.
collect_repo_jsonl() {
  local repo="$1" since="$2" until="$3" jsonl_dir="$4"
  mkdir -p "$jsonl_dir"

  local workdir; workdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" RETURN
  export ARTIFACT_OP_TIMEOUT
  export COLLECT_JSONL_DIR="$jsonl_dir" COLLECT_WORKDIR="$workdir"
  export COLLECT_MARKER_DIR="$workdir/markers"
  mkdir -p "$COLLECT_MARKER_DIR"

  local ids
  if ! ids="$(_gh_timeout api "repos/${repo}/actions/artifacts" --paginate 2>/dev/null \
      | jq -r --arg s "$since" --arg u "$until" \
        '.artifacts[]
         | select(.name | startswith("token-usage-"))
         | select(.expired == false)
         | select(.created_at >= $s and (($u == "") or (.created_at <= $u)))
         | .id | tostring')"; then
    echo "ERROR: could not list token-usage artifacts for ${repo} — verify GH_TOKEN has actions:read." >&2
    return 1
  fi

  local id requested=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    requested=$((requested + 1))
    _collect_one_artifact "$repo" "$id"
  done <<< "$ids"

  local collected
  collected="$(find "$COLLECT_MARKER_DIR" -type f | wc -l | tr -d ' ')"
  if [ "$collected" -lt "$requested" ]; then
    echo "ERROR: only ${collected}/${requested} selected token-usage artifacts for ${repo} yielded records — download/extract failures make the sample partial; refusing to score incomplete evidence." >&2
    return 1
  fi
  printf '%s\n' "$collected"
}

_usage() {
  # Print the leading comment block dynamically: drop the shebang (line 1), stop at
  # the first non-comment line, and strip the leading "# ". Hardcoding a line range
  # (e.g. 2,60p) truncates the header — the Usage examples live past line 60 — and
  # rots whenever the comment length changes.
  sed -e '1d' -e '/^[^#]/,$d' -e 's/^# \{0,1\}//' "${BASH_SOURCE[0]}"
}

main() {
  local repo="petry-projects/.github-private"
  local candidate="claude-opus-5-5" incumbent="claude-opus-4-8"
  local workflow="pr-review" tier="deep"
  local since="" until=""
  local b_since="2026-09-11T14:07Z" b_until="2026-09-25T14:07Z"
  local max_prs="10"
  local dir="" model_ab_dir="" collect_only="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)            repo="$2"; shift 2 ;;
      --candidate)       candidate="$2"; shift 2 ;;
      --incumbent)       incumbent="$2"; shift 2 ;;
      --workflow)        workflow="$2"; shift 2 ;;
      --tier)            tier="$2"; shift 2 ;;
      --since)           since="$2"; shift 2 ;;
      --until)           until="$2"; shift 2 ;;
      --baseline-since)  b_since="$2"; shift 2 ;;
      --baseline-until)  b_until="$2"; shift 2 ;;
      --candidate-max-prs) max_prs="$2"; shift 2 ;;
      --dir)             dir="$2"; shift 2 ;;
      --model-ab-dir)    model_ab_dir="$2"; shift 2 ;;
      --collect-only)    collect_only="true"; shift ;;
      -h|--help)         _usage; return 0 ;;
      *) echo "ERROR: unknown argument: $1" >&2; return 64 ;;
    esac
  done

  # Normalize every ISO bound to seconds precision up front so the collector (jq)
  # and the renderer (awk) compare bounds and record timestamps consistently — a
  # minute-precision bound would otherwise mis-window records in the cutoff minute.
  since="$(_norm_iso "$since")"; until="$(_norm_iso "$until")"
  b_since="$(_norm_iso "$b_since")"; b_until="$(_norm_iso "$b_until")"

  # The canary window starts at the cut (== the baseline end). When --since is
  # omitted, default the candidate lower bound to it so pre-canary candidate
  # records never enter the candidate arm, even though collection still spans the
  # full baseline window below (an empty lower bound would admit them — #1953).
  [ -z "$since" ] && since="$b_until"

  # An explicitly supplied local input directory must exist and be readable. A
  # misspelled/unreadable path would otherwise glob to zero rows and render an
  # ordinary INSUFFICIENT, making a bad path indistinguishable from empty evidence.
  # (--collect-only creates --dir, so this check is scoped to the scoring paths.)
  if [ "$collect_only" != "true" ] && [ -n "$dir" ] && [ ! -d "$dir" ]; then
    echo "ERROR: --dir path does not exist or is not a readable directory: $dir" >&2
    return 66
  fi
  if [ -n "$model_ab_dir" ] && [ ! -d "$model_ab_dir" ]; then
    echo "ERROR: --model-ab-dir path does not exist or is not a readable directory: $model_ab_dir" >&2
    return 66
  fi

  export CANARY_CANDIDATE="$candidate" CANARY_INCUMBENT="$incumbent"
  export CANARY_WORKFLOW="$workflow" CANARY_TIER="$tier"
  export CANARY_SINCE="$since" CANARY_UNTIL="$until"
  export CANARY_BASELINE_SINCE="$b_since" CANARY_BASELINE_UNTIL="$b_until"
  export CANARY_MAX_PRS="$max_prs"

  # Collection window: the download spans the union of the candidate and baseline
  # windows so a single collection feeds both arms.
  local scored_dir="" own_tmp="" col_since col_until count
  col_since="$b_since"; [ -n "$since" ] && [ "$since" \< "$b_since" ] && col_since="$since"
  col_until="$until"

  # --collect-only snapshots artifacts to a persistent directory and exits without
  # scoring; it REQUIRES --dir. A temp dir would be wiped by the EXIT trap before
  # the advertised snapshot could be reused, so refuse rather than silently lose it.
  if [ "$collect_only" = "true" ]; then
    if [ -z "$dir" ]; then
      echo "ERROR: --collect-only requires --dir <path> to persist the snapshot." >&2
      return 64
    fi
    echo "Collecting token-usage artifacts for ${repo} (${col_since} → ${col_until:-now})..." >&2
    if ! count="$(collect_repo_jsonl "$repo" "$col_since" "$col_until" "$dir")"; then
      echo "ERROR: artifact collection failed for ${repo}." >&2
      return 3
    fi
    echo "Collected ${count} artifact(s) into ${dir}." >&2
    echo "collect-only: score later with --dir ${dir}." >&2
    return 0
  fi

  # Resolve the real-PR section's directory: a local snapshot (--dir) or a fresh
  # windowed download into a temp dir cleaned up on EXIT.
  if [ -n "$dir" ]; then
    scored_dir="$dir"
  else
    own_tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$own_tmp'" EXIT
    echo "Collecting token-usage artifacts for ${repo} (${col_since} → ${col_until:-now})..." >&2
    if ! count="$(collect_repo_jsonl "$repo" "$col_since" "$col_until" "$own_tmp")"; then
      echo "ERROR: artifact collection failed for ${repo}." >&2
      return 3
    fi
    echo "Collected ${count} artifact(s)." >&2
    scored_dir="$own_tmp"
  fi

  local rc=0
  if [ -n "$scored_dir" ]; then
    CANARY_MODE="real" CANARY_LABEL="Canary go/no-go — real PRs" \
      render_canary_report "$scored_dir" || rc="$?"
  fi

  # Controlled model-ab section — a separate report, never merged with the above.
  if [ -n "$model_ab_dir" ]; then
    local ab_rc=0
    CANARY_MODE="controlled" \
    CANARY_LABEL="Controlled comparison — model-ab (identical inputs)" \
      render_canary_report "$model_ab_dir" || ab_rc="$?"
    # Combine the two verdicts: a controlled FAIL is a no-go even when the real-PR
    # section passes. (scored_dir is always set, so the exit code must reflect BOTH
    # sections rather than the real-PR one alone.)
    rc="$(_combine_verdict "$rc" "$ab_rc")"
  fi

  return "$rc"
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
