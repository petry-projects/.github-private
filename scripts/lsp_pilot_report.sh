#!/usr/bin/env bash
# lsp_pilot_report.sh — LSP-pilot comparative report renderer (#844, epic #839).
#
# Phase 3 of the LSP pilot. It does NOT introduce any new review-engine behaviour:
# it CONSUMES the story-2 comparison harness (scripts/lsp_pilot_compare.sh) and
# renders ONE report across every candidate LSP server against the FROZEN LSP-off
# baseline (evals/lsp-pilot/holdout/baseline-lsp-off.jsonl). The baseline is read,
# never re-derived or mutated — re-deriving it would void the overfitting guard.
#
# On top of the per-candidate harness (which gives per-PR + aggregate nav tokens,
# tool calls, ET, USD, findings, false-positives and a quality verdict) this layer
# adds the three things the epic success metric needs that the harness alone does
# not produce:
#
#   * cold-start P50/P95 vs the 30s P95 SLA, per candidate (AC2);
#   * a per-candidate success-metric GO/NO-GO verdict — a candidate is a GO only
#     when it delivers a >=2x navigation-token reduction AND no review-quality
#     (false-positive) regression AND a cold-start P95 within the 30s SLA. A token
#     win that costs precision, or that breaches the SLA, is a no-go (AC3). The
#     data-favored candidate is named ONLY when >=2 candidates are competitive
#     (both GO) — never on a token win alone (AC3);
#   * honest annotation of SLA auto-skipped / degraded-MCP runs and a corpus
#     coverage smoke check, so a partial corpus can never read as a clean sweep
#     ("No silent caps" — AC4).
#
# Candidate-run record shape: a story-2 pilot record (see scripts/lsp_pilot_compare.sh)
# with two OPTIONAL honesty fields a run may carry:
#   lsp_skipped   true when the SLA auto-skip fired for this run (cold-start > SLA;
#                 the review fell back to base navigation, so nav_tokens ~ baseline)
#   mcp_degraded  true when the MCP/LSP server failed to connect/init for this run
#                 (the existing "Fail Loud, Never Fake" degradation path)
#   skip_reason   human-readable reason carried alongside either flag
#
# Layout (mirrors scripts/lsp_pilot_compare.sh): the lpr_* / render_* functions are
# PURE (no network) and unit-tested in tests/lsp_pilot_report.bats; main() only
# resolves paths and prints.
#
# Usage:
#   bash scripts/lsp_pilot_report.sh <baseline.jsonl> <corpus-cases.jsonl> \
#       <name=run.jsonl> [<name=run.jsonl> ...]

set -euo pipefail

# Reuse the story-2 harness (render_lsp_comparison, _lp_aggregate, _lp_prs) and,
# transitively, the dated pricing helpers and USD/int formatters. Sourcing it does
# not run its main() (guarded by the BASH_SOURCE check at its foot).
_LPR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lsp_pilot_compare.sh
source "${_LPR_DIR}/lsp_pilot_compare.sh"

# The cold-start P95 SLA in seconds (docs/lsp-pilot.md §3). Overridable for tests.
LSP_SLA_SECONDS="${LSP_SLA_SECONDS:-30}"
# The success-metric navigation-token reduction target (docs/lsp-pilot.md §4).
LSP_TOKEN_TARGET="${LSP_TOKEN_TARGET:-2.0}"

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# lpr_coldstart_stats <candidate_jsonl>
# Emits one TSV line "p50<TAB>p95<TAB>max<TAB>n" over the non-null cold_start_s
# values in a candidate run (nearest-rank percentiles, one decimal). When there is
# no cold-start data (e.g. the LSP-off baseline) it emits "NA<TAB>NA<TAB>NA<TAB>0".
# Pure: reads only the JSONL.
lpr_coldstart_stats() {
  local jsonl="$1"
  if [ ! -f "$jsonl" ]; then
    printf 'NA\tNA\tNA\t0\n'
    return 0
  fi
  jq -r 'select(type=="object") | select((.kind // "token_usage") == "token_usage")
      | .cold_start_s | select(. != null)' "$jsonl" 2>/dev/null \
    | sort -n \
    | awk '
        { v[NR] = $1 }
        END {
          n = NR
          if (n == 0) { printf "NA\tNA\tNA\t0\n"; exit 0 }
          # Nearest-rank: rank = ceil(p * n), 1-based, clamped to [1, n].
          p50 = int(0.50 * n); if (p50 < 0.50 * n) p50++
          p95 = int(0.95 * n); if (p95 < 0.95 * n) p95++
          if (p50 < 1) p50 = 1; if (p50 > n) p50 = n
          if (p95 < 1) p95 = 1; if (p95 > n) p95 = n
          printf "%.1f\t%.1f\t%.1f\t%d\n", v[p50], v[p95], v[n], n
        }'
}

# lpr_within_sla <candidate_jsonl> [sla_seconds]
# Returns 0 when the cold-start P95 is within the SLA, 1 when it breaches the SLA,
# and 2 when there is no cold-start data to judge (a coverage gap, not a pass).
lpr_within_sla() {
  local jsonl="$1" sla="${2:-$LSP_SLA_SECONDS}" stats p95 n
  stats="$(lpr_coldstart_stats "$jsonl")"
  p95="$(printf '%s' "$stats" | cut -f2)"
  n="$(printf '%s' "$stats" | cut -f4)"
  [ "${n:-0}" -gt 0 ] || return 2
  awk -v p="$p95" -v s="$sla" 'BEGIN { exit !(p <= s) }'
}

# lpr_skip_annotations <candidate_jsonl>
# Emits "pr<TAB>type<TAB>reason" for every run that auto-skipped the LSP step
# (SLA breach) or ran with a degraded MCP server, so a coverage gap is never
# silently dropped (AC4). type is "sla-skip" or "mcp-degraded". Pure.
lpr_skip_annotations() {
  local jsonl="$1"
  [ -f "$jsonl" ] || return 0
  jq -r 'select(type=="object") | select((.kind // "token_usage") == "token_usage")
      | select((.lsp_skipped == true) or (.mcp_degraded == true))
      | [ (.pr // "unknown"),
          (if (.lsp_skipped == true) then "sla-skip" else "mcp-degraded" end),
          (.skip_reason // "(no reason given)") ] | @tsv' "$jsonl" 2>/dev/null \
    | sort -u
}

# lpr_coverage <corpus_cases_jsonl> <candidate_jsonl>
# Smoke check (AC4): for every PR in the frozen corpus, emit "pr<TAB>status" where
# status is COVERED, "SKIPPED:<reason>" (an SLA-skip / degraded run — present but
# without LSP enrichment), or MISSING (no run captured at all). Returns 1 if any
# corpus PR is MISSING, so a partial corpus is loud rather than silent.
lpr_coverage() {
  local corpus="$1" candidate="$2"
  [ -f "$corpus" ] || { echo "[lsp-pilot] ERROR: corpus cases file not found: $corpus" >&2; return 2; }

  local annotations corpus_prs cand_prs pr status missing=0
  annotations="$(lpr_skip_annotations "$candidate")"
  corpus_prs="$(jq -r 'select(type=="object")
      | "\(.repo)#\(.pr_number)@\(.head_sha)"' "$corpus" 2>/dev/null | sort -u)"
  cand_prs="$(_lp_prs "$candidate")"

  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    if ! printf '%s\n' "$cand_prs" | grep -Fxq "$pr"; then
      printf '%s\tMISSING\n' "$pr"
      missing=1
      continue
    fi
    local ann
    ann="$(printf '%s\n' "$annotations" | awk -F'\t' -v p="$pr" '$1 == p { print $2": "$3; exit }')"
    if [ -n "$ann" ]; then
      status="SKIPPED:${ann}"
    else
      status="COVERED"
    fi
    printf '%s\t%s\n' "$pr" "$status"
  done <<< "$corpus_prs"

  return "$missing"
}

# _lpr_total_nav <baseline_jsonl> <candidate_jsonl>
# Prints "baseline_nav<TAB>candidate_nav" summed over the PRs the candidate covers
# (reusing the harness aggregate so the numbers match render_lsp_comparison). Pure.
_lpr_total_nav() {
  local baseline="$1" candidate="$2" bagg cagg
  bagg="$(_lp_aggregate "$baseline")"
  cagg="$(_lp_aggregate "$candidate")"
  awk -F'\t' '
    NR == FNR { bnav[$1] = $2; next }
    { pr = $1; if (pr in bnav) { tb += bnav[pr]; tc += $2 } }
    END { printf "%.1f\t%.1f\n", tb + 0, tc + 0 }
  ' <(printf '%s\n' "$bagg") <(printf '%s\n' "$cagg")
}

# lpr_token_ratio <baseline_jsonl> <candidate_jsonl>
# Prints the aggregate navigation-token reduction ratio baseline/candidate to two
# decimals (0.00 when the candidate's nav total is 0). Pure.
lpr_token_ratio() {
  local nav; nav="$(_lpr_total_nav "$1" "$2")"
  awk -F'\t' '{ if ($2 > 0) printf "%.2f\n", $1 / $2; else printf "0.00\n" }' <<< "$nav"
}

# lpr_quality_regressed <baseline_jsonl> <candidate_jsonl>
# Returns 1 when the candidate regresses review quality on any covered PR (its
# mean false-positive count exceeds the frozen baseline's — precision dropped),
# else 0. This is the same precision proxy the story-2 harness enforces. Pure.
lpr_quality_regressed() {
  local baseline="$1" candidate="$2" bagg cagg
  bagg="$(_lp_aggregate "$baseline")"
  cagg="$(_lp_aggregate "$candidate")"
  # _lp_aggregate column 5 is mean false_positives.
  awk -F'\t' '
    NR == FNR { bfp[$1] = $5; next }
    { pr = $1; if ((pr in bfp) && ($5 > bfp[pr] + 1e-9)) regressed = 1 }
    END { exit (regressed ? 1 : 0) }
  ' <(printf '%s\n' "$bagg") <(printf '%s\n' "$cagg")
}

# lpr_candidate_verdict <baseline_jsonl> <candidate_jsonl> [name] [sla_seconds]
# Prints the success-metric verdict on its first word — "GO" or "NO-GO" — followed
# by the deciding reasons, and returns 0 for GO / 1 for NO-GO (AC3). A GO requires
# ALL of: nav-token reduction >= the target, no quality regression, cold-start P95
# within the SLA. Pure.
lpr_candidate_verdict() {
  local baseline="$1" candidate="$2" name="${3:-candidate}" sla="${4:-$LSP_SLA_SECONDS}"
  local ratio target="$LSP_TOKEN_TARGET" reasons=() go=1

  ratio="$(lpr_token_ratio "$baseline" "$candidate")"
  if awk -v r="$ratio" -v t="$target" 'BEGIN { exit !(r + 0 >= t + 0) }'; then
    reasons+=("token reduction ${ratio}x ≥ ${target}x target")
  else
    go=0
    reasons+=("token reduction ${ratio}x below ${target}x target")
  fi

  if lpr_quality_regressed "$baseline" "$candidate"; then
    reasons+=("no quality regression (false positives ≤ baseline)")
  else
    go=0
    reasons+=("quality REGRESSION (more false positives than baseline)")
  fi

  local stats p95 n
  stats="$(lpr_coldstart_stats "$candidate")"
  p95="$(printf '%s' "$stats" | cut -f2)"
  n="$(printf '%s' "$stats" | cut -f4)"
  if [ "${n:-0}" -le 0 ]; then
    go=0
    reasons+=("no cold-start data to verify the ${sla}s P95 SLA")
  elif awk -v p="$p95" -v s="$sla" 'BEGIN { exit !(p + 0 <= s + 0) }'; then
    reasons+=("cold-start P95 ${p95}s within the ${sla}s SLA")
  else
    go=0
    reasons+=("cold-start P95 ${p95}s breaches the ${sla}s SLA")
  fi

  local verdict joined="" r
  verdict=$([ "$go" -eq 1 ] && echo "GO" || echo "NO-GO")
  for r in "${reasons[@]}"; do
    if [ -n "$joined" ]; then joined="$joined; $r"; else joined="$r"; fi
  done
  printf '%s — %s\n' "$verdict" "$joined"
  return $((1 - go))
}

# ---------------------------------------------------------------------------
# render_pilot_report — the single multi-candidate comparison report
# ---------------------------------------------------------------------------

# render_pilot_report <baseline_jsonl> <corpus_cases_jsonl> <name=run.jsonl> [...]
# Writes the full Markdown report to stdout. Pure (no network). Returns 0.
render_pilot_report() {
  local baseline="$1" corpus="$2"; shift 2
  if [ "$#" -lt 1 ]; then
    echo "[lsp-pilot] ERROR: at least one <name=run.jsonl> candidate is required" >&2
    return 2
  fi

  printf '# 🔬 LSP pilot — comparative speed / quality / cost report\n\n'
  printf '_Each candidate LSP-on run scored against the **immutable LSP-off baseline** '
  printf '(`evals/lsp-pilot/holdout/baseline-lsp-off.jsonl`) over the frozen corpus '
  printf '(`evals/lsp-pilot/holdout/cases.jsonl`). The baseline is consumed, never '
  printf 're-derived._\n\n'

  printf '## Success metric (verbatim, epic #839)\n\n'
  printf '> Go = on the frozen pilot PR corpus, LSP-on deep-tier review delivers a '
  printf 'measurable navigation-token reduction (**target ≥2x fewer navigation '
  printf 'tool-call tokens** vs the LSP-off control) AND **no regression in review '
  printf 'quality** (false-positive / precision no worse than the frozen LSP-off '
  printf 'baseline), achieved **within the cold-start SLA (≤30s P95)**. A win on '
  printf 'tokens that costs precision is a *no-go*, not a win.\n\n'

  # Accumulate per-candidate verdict facts for the cross-candidate summary.
  local names=() ratios=() verdicts=() p95s=() go_names=()
  local spec name run

  for spec in "$@"; do
    name="${spec%%=*}"
    run="${spec#*=}"
    names+=("$name")

    printf '## Candidate: `%s`\n\n' "$name"

    if [ ! -f "$run" ]; then
      printf '⚠️ **No run artifact found** at `%s` — candidate not scored.\n\n' "$run"
      ratios+=("0.00"); p95s+=("NA"); verdicts+=("NO-GO")
      continue
    fi

    # 1) Speed / cost / quality deltas — straight from the story-2 harness.
    local cmp rc=0
    cmp="$(render_lsp_comparison "$baseline" "$run" "$name")" || rc=$?
    printf '%s\n\n' "$cmp"
    if [ "$rc" -ne 0 ]; then
      # The harness already printed an INCOMPLETE banner; record a NO-GO and move on.
      ratios+=("0.00"); p95s+=("NA"); verdicts+=("NO-GO")
      continue
    fi

    # 2) Cold-start vs the SLA (AC2).
    local stats p50 p95 cmax cn
    stats="$(lpr_coldstart_stats "$run")"
    IFS=$'\t' read -r p50 p95 cmax cn <<< "$stats"
    printf '### Cold start vs the %ss P95 SLA\n\n' "$LSP_SLA_SECONDS"
    if [ "${cn:-0}" -le 0 ]; then
      printf -- '- No cold-start samples captured (no server launched on any run).\n\n'
    else
      local sla_word
      if lpr_within_sla "$run"; then sla_word="✅ within SLA"; else sla_word="❌ SLA breach"; fi
      printf -- '- **P50:** %ss · **P95:** %ss · **max:** %ss over %s sample(s) — %s (SLA %ss)\n\n' \
        "$p50" "$p95" "$cmax" "$cn" "$sla_word" "$LSP_SLA_SECONDS"
    fi

    # 3) Coverage + skipped/degraded honesty (AC4).
    printf '### Coverage & skipped / degraded runs\n\n'
    local cov cov_rc=0
    cov="$(lpr_coverage "$corpus" "$run")" || cov_rc=$?
    printf '| Corpus PR | Status |\n|---|---|\n'
    while IFS=$'\t' read -r pr status; do
      [ -n "$pr" ] || continue
      printf '| `%s` | %s |\n' "$pr" "$status"
    done <<< "$cov"
    printf '\n'
    if [ "$cov_rc" -ne 0 ]; then
      printf -- '- ⚠️ **Coverage gap:** at least one corpus PR has no captured run (MISSING above). '
      printf 'A partial corpus is not a clean sweep.\n\n'
    fi
    local skips
    skips="$(lpr_skip_annotations "$run")"
    if [ -n "$skips" ]; then
      printf -- '- Annotated skipped / degraded runs (not dropped):\n'
      while IFS=$'\t' read -r pr typ reason; do
        [ -n "$pr" ] || continue
        printf -- '  - `%s` — **%s**: %s\n' "$pr" "$typ" "$reason"
      done <<< "$skips"
      printf '\n'
    else
      printf -- '- No SLA auto-skip or MCP degradation on this candidate.\n\n'
    fi

    # 4) Success-metric verdict (AC3).
    local verdict vrc=0 ratio
    verdict="$(lpr_candidate_verdict "$baseline" "$run" "$name")" || vrc=$?
    ratio="$(lpr_token_ratio "$baseline" "$run")"
    printf '### Success-metric verdict\n\n'
    printf -- '- %s\n\n' "$verdict"

    ratios+=("$ratio"); p95s+=("$p95")
    if [ "$vrc" -eq 0 ]; then
      verdicts+=("GO"); go_names+=("$name")
    else
      verdicts+=("NO-GO")
    fi
  done

  # Cross-candidate summary + data-favored pick (only when >=2 candidates are GO).
  printf '## Cross-candidate summary\n\n'
  printf '| Candidate | Nav reduction | Cold-start P95 | Verdict |\n|---|---:|---:|:--|\n'
  local i
  for i in "${!names[@]}"; do
    local p95cell="${p95s[$i]}"
    [ "$p95cell" = "NA" ] || p95cell="${p95cell}s"
    printf '| `%s` | %sx | %s | %s |\n' \
      "${names[$i]}" "${ratios[$i]}" "$p95cell" "${verdicts[$i]}"
  done
  printf '\n'

  if [ "${#go_names[@]}" -eq 0 ]; then
    printf -- '- **No candidate meets the success metric** — no go on token reduction, quality, and SLA together.\n'
  elif [ "${#go_names[@]}" -eq 1 ]; then
    printf -- '- **%s** is the only candidate meeting the success metric; no head-to-head pick is needed.\n' \
      "${go_names[0]}"
  else
    # Two or more are genuinely competitive — name the data-favored one by the
    # largest nav-token reduction (tie-break: lower cold-start P95).
    local fav="" fav_ratio="-1" fav_p95="999999" idx
    for idx in "${!names[@]}"; do
      [ "${verdicts[$idx]}" = "GO" ] || continue
      local r="${ratios[$idx]}" p="${p95s[$idx]}"
      [ "$p" = "NA" ] && p="999999"
      if awk -v r="$r" -v fr="$fav_ratio" -v p="$p" -v fp="$fav_p95" \
          'BEGIN { exit !(r > fr + 1e-9 || (r > fr - 1e-9 && p < fp)) }'; then
        fav="${names[$idx]}"; fav_ratio="$r"; fav_p95="$p"
      fi
    done
    printf -- '- %s candidates are competitive (both meet the metric). **Data favored: %s** — largest navigation-token reduction (%sx), tie-broken on cold-start P95.\n' \
      "${#go_names[@]}" "$fav" "$fav_ratio"
  fi
  printf '\n'

  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  if [ "$#" -lt 3 ]; then
    echo "usage: $0 <baseline.jsonl> <corpus-cases.jsonl> <name=run.jsonl> [<name=run.jsonl> ...]" >&2
    exit 2
  fi
  render_pilot_report "$@"
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
