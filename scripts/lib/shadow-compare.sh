#!/usr/bin/env bash
# shadow-compare.sh (lib) — pure comparison core for the shadow-mode dual-run
# canary validation (issue #605; prerequisite for the #587 skill-proposer, part
# of the Safe Release Strategy #495 / health-gated promotion #501).
#
# Shadow-mode runs the `next`-channel agent in parallel with `stable` on the
# same PR, posts ONLY stable's output, and compares next's shadow output against
# stable's to detect a quality regression before `next` is ever promoted. This
# module is the side-effect-free (source-able) decision core: no gh/git/network
# calls, so the comparison can be unit-tested deterministically. The orchestrator
# scripts/agent-shadow-run.sh sources this and feeds it real verdict files.
#
# Quality model — a "regression" is the NEXT candidate being strictly LESS
# cautious than stable on the same PR. Cautiousness is a scrutiny score:
#   score = decision_rank*3 + risk_rank   (decision dominates; risk breaks ties)
#   decision_rank: approve=0, escalate=1
#   risk_rank:     LOW=0, MEDIUM=1, HIGH=2
# next_score < stable_score → REGRESSION (next would let through what stable
# caught, or under-rates the risk). next_score > stable_score → DIVERGENCE_BENIGN
# (next is merely noisier/more cautious). Equal → MATCH. A `skip` (or any
# unrankable decision) on either side → SKIPPED (inconclusive, never a
# regression). False positives only delay a promotion; false negatives would let
# a degraded agent graduate, so the less-cautious direction is the fail signal.

# ── ranking primitives ───────────────────────────────────────────────────────

# shadow_decision_rank <decision> — echo 0 (approve) or 1 (escalate).
# Any other decision (skip/unknown) is unrankable: echo nothing, return 1.
shadow_decision_rank() {
  case "${1:-}" in
    approve)  echo 0 ;;
    escalate) echo 1 ;;
    *)        return 1 ;;
  esac
}

# shadow_risk_rank <risk> — echo 0 (LOW), 1 (MEDIUM), 2 (HIGH).
# Any other value is unrankable: echo nothing, return 1.
shadow_risk_rank() {
  case "${1:-}" in
    LOW)    echo 0 ;;
    MEDIUM) echo 1 ;;
    HIGH)   echo 2 ;;
    *)      return 1 ;;
  esac
}

# _shadow_score <decision> <risk> — echo the scrutiny score, or return 1 if
# either component is unrankable.
_shadow_score() {
  local drank rrank
  drank=$(shadow_decision_rank "${1:-}") || return 1
  rrank=$(shadow_risk_rank "${2:-}")     || return 1
  echo $(( drank * 3 + rrank ))
}

# ── classification ────────────────────────────────────────────────────────────

# shadow_classify <stable_decision> <stable_risk> <next_decision> <next_risk>
# Echo exactly one of MATCH / DIVERGENCE_BENIGN / REGRESSION / SKIPPED.
shadow_classify() {
  local s_dec="${1:-}" s_risk="${2:-}" n_dec="${3:-}" n_risk="${4:-}"
  local s_score n_score
  # An unrankable verdict on either side (e.g. skip) makes the comparison
  # inconclusive — never a regression.
  s_score=$(_shadow_score "$s_dec" "$s_risk") || { echo "SKIPPED"; return 0; }
  n_score=$(_shadow_score "$n_dec" "$n_risk") || { echo "SKIPPED"; return 0; }
  if [ "$n_score" -lt "$s_score" ]; then
    echo "REGRESSION"
  elif [ "$n_score" -gt "$s_score" ]; then
    echo "DIVERGENCE_BENIGN"
  else
    echo "MATCH"
  fi
}

# shadow_compare_verdicts <stable_json> <next_json> — file-driven classify.
# Reads .decision/.risk from each verdict JSON and classifies. Returns non-zero
# (without echoing a classification) if either file is missing or unparseable;
# graceful handling of an absent shadow verdict is the orchestrator's job.
shadow_compare_verdicts() {
  local stable="${1:-}" next="${2:-}"
  [ -f "$stable" ] || { echo "shadow_compare_verdicts: stable verdict not found: $stable" >&2; return 1; }
  [ -f "$next" ]   || { echo "shadow_compare_verdicts: next verdict not found: $next" >&2; return 1; }
  local s_dec s_risk n_dec n_risk
  s_dec=$(jq -r '.decision // ""' "$stable") || return 1
  s_risk=$(jq -r '.risk // ""' "$stable")    || return 1
  n_dec=$(jq -r '.decision // ""' "$next")   || return 1
  n_risk=$(jq -r '.risk // ""' "$next")      || return 1
  shadow_classify "$s_dec" "$s_risk" "$n_dec" "$n_risk"
}

# ── promotion signal ──────────────────────────────────────────────────────────

# shadow_signal <classification> — echo the required promotion signal:
# FAIL only for REGRESSION; PASS otherwise.
shadow_signal() {
  case "${1:-}" in
    REGRESSION) echo "FAIL" ;;
    *)          echo "PASS" ;;
  esac
}

# shadow_aggregate <classification...> — window-level signal: FAIL if ANY
# observation is a REGRESSION, else PASS (an empty window is PASS: no evidence
# of a regression to block on).
shadow_aggregate() {
  local c
  for c in "$@"; do
    [ "$c" = "REGRESSION" ] && { echo "FAIL"; return 0; }
  done
  echo "PASS"
}

# shadow_gate <graduated_state> <shadow_signal> — compose the shadow result onto
# the health-gated promotion decision (decide_graduated in canary-rollout.sh) as
# a REQUIRED signal. A FAIL forces BLOCKED (a shadow regression is a
# quality-regression hold, triaged like a health breach); a PASS leaves the
# graduated state untouched.
shadow_gate() {
  local state="${1:-}" signal="${2:-PASS}"
  if [ "$signal" = "FAIL" ]; then
    echo "BLOCKED"
  else
    echo "$state"
  fi
}

# ── reporting ─────────────────────────────────────────────────────────────────

# shadow_report <classification> <s_decision> <s_risk> <n_decision> <n_risk> [pr_url] [today]
# Markdown audit line for the shadow comparison. Pure: no network.
shadow_report() {
  local cls="${1:-}" s_dec="${2:-}" s_risk="${3:-}" n_dec="${4:-}" n_risk="${5:-}"
  local pr_url="${6:-}" today="${7:-}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local icon headline
  case "$cls" in
    MATCH)             icon='✅'; headline='shadow agrees with stable' ;;
    DIVERGENCE_BENIGN) icon='🟡'; headline='shadow diverged (more cautious) — benign' ;;
    REGRESSION)        icon='🔴'; headline='REGRESSION — shadow is less cautious than stable' ;;
    SKIPPED)           icon='⚪'; headline='inconclusive — no comparable verdict' ;;
    *)                 icon='⚪'; headline='unknown classification' ;;
  esac

  local pr_ref=""
  if [ -n "$pr_url" ]; then
    pr_ref="#${pr_url##*/}"
  fi

  printf '# %s Shadow-mode dual-run — %s\n\n' "$icon" "$today"
  [ -n "$pr_ref" ] && printf '_PR %s · `next` (shadow) vs `stable`_\n\n' "$pr_ref"
  printf -- '- **Result:** %s — %s\n' "$cls" "$headline"
  printf -- '- **stable:** decision=`%s` risk=`%s`\n' "$s_dec" "$s_risk"
  printf -- '- **next (shadow):** decision=`%s` risk=`%s`\n' "$n_dec" "$n_risk"
  printf -- '- **promotion signal:** %s\n' "$(shadow_signal "$cls")"
  printf '\n'
  if [ "$cls" = "REGRESSION" ]; then
    printf '> The `next` candidate produced a less-cautious verdict than `stable` on the same PR. '
    printf 'This is a required promotion signal — health-gated promotion (#501) must HOLD `next` '
    printf 'until the divergence is triaged (`shadow_gate` → BLOCKED).\n'
  fi
}
