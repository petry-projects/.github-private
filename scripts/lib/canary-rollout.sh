#!/usr/bin/env bash
# canary-rollout.sh (lib) — pure decision core for the ring-staged, health-gated
# promotion of agent releases (initiative #495, issue #501; rollback/observability #502).
#
# This file is side-effect-free and `source`-able: it defines pure functions only
# (no I/O, no gh/git calls) so the gate logic can be unit-tested deterministically.
# The orchestrator scripts/canary-rollout.sh sources this and feeds it real numbers
# gathered from `gh`.
#
# Gate model (from #501 design):
#   A ring's channel advances to a candidate vX.Y.Z only once the rings ALREADY on
#   the candidate have produced, over a trailing 7-day window:
#     - Volume:  healthy_runs >= min_healthy_runs = ceil(baseline_runs / 7)
#     - Quality: candidate failure-rate <= baseline failure-rate
#   No synthetic floor: a ring with no healthy candidate volume simply never advances
#   (the candidate parks at the frontier). States: PROMOTE / SOAKING / INVESTIGATE.
#   RESET (roll all rings back to last known-good) is a human/override outcome of a
#   confirmed regression, not an automatic gate state.

# ceil_div <numerator> <denominator> — integer ceiling of numerator/denominator.
# Denominator must be > 0. Pure arithmetic, no bc.
ceil_div() {
  local n="$1" d="$2"
  if [ "${d:-0}" -le 0 ]; then echo 0; return 1; fi
  echo $(( (n + d - 1) / d ))
}

# min_healthy_runs <baseline_runs> — minimum healthy candidate runs a soaking ring
# must accumulate before it can gate forward: ceil(baseline_runs / 7), i.e. roughly
# one trailing day's worth of the prior version's volume. baseline_runs == 0 -> 0
# (an unused reusable has no floor; it just never advances on volume == 0 below).
SOAK_WINDOW_DAYS="${SOAK_WINDOW_DAYS:-7}"
min_healthy_runs() {
  local baseline_runs="${1:-0}"
  ceil_div "$baseline_runs" "$SOAK_WINDOW_DAYS"
}

# failure_rate_permille <failures> <total> — integer failure rate in per-mille
# (parts per 1000) to keep comparisons in pure bash arithmetic. total == 0 -> 0.
failure_rate_permille() {
  local failures="${1:-0}" total="${2:-0}"
  if [ "$total" -le 0 ]; then echo 0; return 0; fi
  echo $(( failures * 1000 / total ))
}

# decide_gate <healthy_runs> <min_healthy> <cand_fail_permille> <base_fail_permille>
# Pure gate decision for one frontier ring. Echoes exactly one of:
#   INVESTIGATE — candidate failure-rate exceeds baseline (possible regression; a
#                 human classifies it: pre-existing -> log + continue, or regression
#                 -> fix + new vX.Y.Z which RESETs the rollout).
#   PROMOTE     — quality holds AND volume threshold met -> advance the next ring.
#   SOAKING     — quality holds but not enough healthy candidate runs yet -> wait.
# Quality is checked first: a quality breach is never masked by low volume.
decide_gate() {
  local healthy_runs="${1:-0}" min_healthy="${2:-0}"
  local cand_fail="${3:-0}" base_fail="${4:-0}"
  if [ "$cand_fail" -gt "$base_fail" ]; then
    echo "INVESTIGATE"; return 0
  fi
  if [ "$healthy_runs" -ge "$min_healthy" ] && [ "$healthy_runs" -gt 0 ]; then
    echo "PROMOTE"; return 0
  fi
  echo "SOAKING"
}

# next_channel_in_order <current_channel> <ordered_channels_csv>
# Given the frontier channel and the ordered channel list (e.g. "next,ring0,ring1,stable"),
# echo the channel that a PROMOTE advances next, or empty if already at the last ring.
next_channel_in_order() {
  local current="$1" csv="$2"
  local prev="" ch found=""
  local IFS=,
  for ch in $csv; do
    if [ "$prev" = "$current" ]; then found="$ch"; break; fi
    prev="$ch"
  done
  echo "$found"
}

# gate_summary_line <ring> <state> <healthy> <min_healthy> <cand_fail_permille> <base_fail_permille>
# One-line human/observability row (used by `evaluate`, doubling as the #502 report).
gate_summary_line() {
  printf '%-8s %-12s healthy=%s/%s  fail=%s‰ vs base %s‰\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
