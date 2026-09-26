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

# _fmt_pct <fraction>  → "NN%" (fraction 0.225 → "22%"). Negative allowed.
_fmt_pct() {
  awk -v v="${1:-0}" 'BEGIN { printf "%d%%", (v < 0 ? -1 : 1) * int((v < 0 ? -v : v) * 100 + 0.5) * (v < 0 ? -1 : 1) }'
}

# _fmt_ms <ms>  → integer milliseconds, or "n/a" for the -1 sentinel.
_fmt_ms() {
  awk -v v="${1:-0}" 'BEGIN { if (v < 0) printf "n/a"; else printf "%d ms", int(v + 0.5) }'
}

# _fmt_usd6 <dollars>  → 6-decimal USD (per-invocation figures are sub-cent, so
# the 2dp org formatter would collapse them to $0.00). Uses "n/a" for -1.
_fmt_usd6() {
  awk -v v="${1:-0}" 'BEGIN { if (v < 0) printf "n/a"; else printf "$%.6f", v }'
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

  jq -r 'select(type == "object")
    | select((.kind // "token_usage") == "token_usage")
    | [ (.ts // "-"), (.workflow // "-"), (.tier // "-"), (.model // "-"),
        (.input_tokens // 0), (.cache_read_tokens // 0), (.cache_creation_tokens // 0),
        (.output_tokens // 0), (.context // ""),
        (if (.duration_ms == null) then "" else (.duration_ms | tostring) end)
      ] | @tsv' "${files[@]}" 2>/dev/null \
  | while IFS=$'\t' read -r ts wf tier model inp cr cw out ctx dur; do
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
    function median(a, n,   i, j, t, b) {
      if (n <= 0) return -1
      for (i = 1; i <= n; i++) b[i] = a[i]
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
        if (b[j] < b[i]) { t = b[i]; b[i] = b[j]; b[j] = t }
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

  local enriched; enriched="$(mktemp)"
  canary_annotate "$dir" > "$enriched"

  # Split into candidate / incumbent / fallback arms, applying the sample windows.
  # In controlled mode both arms come from identical inputs, so windows + cap are
  # inert (empty windows) — the arms are split by model alone.
  local cand_file inc_file fb_file
  cand_file="$(mktemp)"; inc_file="$(mktemp)"; fb_file="$(mktemp)"

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

  awk -F'\t' -v wf="$workflow" -v tier="$tier" -v c="$candidate" -v i="$incumbent" \
    '$2 == wf && $3 == tier && $4 != c && $4 != i { print }' "$enriched" > "$fb_file"

  # Candidate cap: keep only the first max_prs distinct PR contexts in time order
  # (earliest ts per context). Real mode only; a non-positive cap disables it.
  if [ "$mode" = "real" ] && [ "$max_prs" -gt 0 ]; then
    local allowed capped
    allowed="$(awk -F'\t' '$9 != "" { if (!($9 in first) || $1 < first[$9]) first[$9] = $1 }
                 END { for (k in first) printf "%s\t%s\n", first[k], k }' "$cand_file" \
               | sort -t$'\t' -k1,1 | awk -F'\t' -v n="$max_prs" 'NR <= n { print $2 }')"
    capped="$(mktemp)"
    awk -F'\t' -v allow="$allowed" 'BEGIN { n = split(allow, a, "\n"); for (k = 1; k <= n; k++) keep[a[k]] = 1 }
      $9 in keep { print }' "$cand_file" > "$capped"
    mv "$capped" "$cand_file"
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
  local base_insuff=0
  [ "$c_prs" -lt "$min_prs" ] && base_insuff=1
  [ "$i_inv" -lt "$min_inv" ] && base_insuff=1

  local cost_status cache_status latency_status
  if [ "$base_insuff" -eq 1 ] || [ "$c_priced" -eq 0 ] || [ "$i_priced" -eq 0 ]; then
    cost_status="INSUFFICIENT"; cache_status="INSUFFICIENT"
  else
    cost_status="$(_bar_status "$c_mcost" "$i_mcost" "$cost_bar")"
    cache_status="$(_bar_status "$c_mcr" "$i_mcr" "$cache_bar")"
  fi
  if [ "$base_insuff" -eq 1 ] || [ "$c_durc" -eq 0 ] || [ "$i_durc" -eq 0 ]; then
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
  printf '| Mean USD / invocation | %s | %s |\n' "$(_fmt_usd6 "$c_mcost")" "$(_fmt_usd6 "$i_mcost")"
  printf '| p50 USD / invocation | %s | %s |\n' "$(_fmt_usd6 "$c_pcost")" "$(_fmt_usd6 "$i_pcost")"
  printf '| Mean cache-read USD / invocation | %s | %s |\n' "$(_fmt_usd6 "$c_mcr")" "$(_fmt_usd6 "$i_mcr")"
  printf '| Mean duration | %s | %s |\n' "$(_fmt_ms "$c_mdur")" "$(_fmt_ms "$i_mdur")"
  printf '| p50 duration | %s | %s |\n' "$(_fmt_ms "$c_pdur")" "$(_fmt_ms "$i_pdur")"
  printf '| USD / 1M input-equivalent tokens (context only) | %s | %s |\n\n' \
    "$(_fmt_usd6 "$c_perm")" "$(_fmt_usd6 "$i_perm")"

  printf '### Verdict per bar\n\n'
  printf '| Bar | Candidate | Incumbent | Reduction | Result |\n|---|---:|---:|---:|:--|\n'
  printf '| Cost per invocation (≥ %s lower) | %s | %s | %s | %s |\n' \
    "$(_fmt_pct "$cost_bar")" "$(_fmt_usd6 "$c_mcost")" "$(_fmt_usd6 "$i_mcost")" \
    "$( [ "$cost_red" = "-999" ] && printf 'n/a' || _fmt_pct "$cost_red" )" "$cost_status"
  printf '| Cache-read cost per invocation (≥ %s lower) | %s | %s | %s | %s |\n' \
    "$(_fmt_pct "$cache_bar")" "$(_fmt_usd6 "$c_mcr")" "$(_fmt_usd6 "$i_mcr")" \
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
# silently-empty download as data.
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

  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _collect_one_artifact "$repo" "$id"
  done <<< "$ids"

  find "$COLLECT_MARKER_DIR" -type f | wc -l | tr -d ' '
}

_usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

  export CANARY_CANDIDATE="$candidate" CANARY_INCUMBENT="$incumbent"
  export CANARY_WORKFLOW="$workflow" CANARY_TIER="$tier"
  export CANARY_SINCE="$since" CANARY_UNTIL="$until"
  export CANARY_BASELINE_SINCE="$b_since" CANARY_BASELINE_UNTIL="$b_until"
  export CANARY_MAX_PRS="$max_prs"

  # Resolve the real-PR section's directory: a local snapshot (--dir) or a fresh
  # windowed download. The download spans the union of the candidate and baseline
  # windows so a single collection feeds both arms.
  local scored_dir="" own_tmp=""
  if [ -n "$dir" ]; then
    scored_dir="$dir"
  else
    own_tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$own_tmp'" EXIT
    local col_since col_until count
    col_since="$b_since"; [ -n "$since" ] && [ "$since" \< "$b_since" ] && col_since="$since"
    col_until="$until"
    echo "Collecting token-usage artifacts for ${repo} (${col_since} → ${col_until:-now})..." >&2
    count="$(collect_repo_jsonl "$repo" "$col_since" "$col_until" "$own_tmp")"
    echo "Collected ${count} artifact(s)." >&2
    scored_dir="$own_tmp"
    if [ "$collect_only" = "true" ]; then
      echo "collect-only: artifacts extracted to ${own_tmp} (copy them out before EXIT)." >&2
      return 0
    fi
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
    # When there is no real-PR section, the controlled verdict drives the exit code.
    [ -z "$scored_dir" ] && rc="$ab_rc"
  fi

  return "$rc"
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
