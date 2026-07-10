#!/usr/bin/env bash
# agent-shadow-run.sh — shadow-mode dual-run orchestrator (issue #605;
# prerequisite for the #587 skill-proposer, part of Safe Release Strategy #495).
#
# Shadow-mode runs the `next`-channel agent in parallel with `stable` on the SAME
# PR. This orchestrator takes the two already-produced verdict JSONs (stable +
# next/shadow — the parallel engine invocation at each channel is the caller
# workflow's job) and:
#   1. posts ONLY stable's verdict (via post-pr-review.sh) — next never touches
#      the PR;
#   2. logs the shadow (next) verdict for audit — never posted;
#   3. compares the two for a quality regression (scripts/lib/shadow-compare.sh);
#   4. emits the PASS/FAIL promotion signal to GITHUB_ENV / the step summary so
#      health-gated promotion (#501) can consume it as a REQUIRED signal.
#
# A broken or missing shadow verdict must NEVER block the stable review: the
# comparison degrades to SKIPPED (PASS) and the PR is still reviewed.
#
# Layout mirrors scripts/initiative_canary.sh: pure logic lives in the sourced
# lib and is unit-tested; main() does the I/O (posting, logging, env emission).
#
# Env vars consumed:
#   PR_URL          the pull request URL (required)
#   STABLE_VERDICT  path to stable's verdict JSON (required) — the ONLY one posted
#   SHADOW_VERDICT  path to next's shadow verdict JSON — logged + compared, never posted
#   DRY_RUN         true/false, forwarded to post-pr-review.sh (default false)
#   PR_HEAD_SHA     head SHA (required by post-pr-review.sh)
#   SHADOW_LOG      path to append the shadow verdict audit entry (default a temp file)
#   SHADOW_OUT      optional path; the comparison report is written there too
#   GITHUB_ENV      written by the Actions runner (SHADOW_CLASSIFICATION / _SIGNAL / _REGRESSION)
#   GITHUB_STEP_SUMMARY  the comparison report is appended when set

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/shadow-compare.sh
source "$SCRIPT_DIR/lib/shadow-compare.sh"

main() {
  local pr_url="${PR_URL:-}"
  local stable="${STABLE_VERDICT:-}"
  local shadow="${SHADOW_VERDICT:-}"
  local dry_run="${DRY_RUN:-false}"

  if [ -z "$pr_url" ]; then
    echo "::error::PR_URL is required" >&2
    exit 1
  fi
  if [ -z "$stable" ] || [ ! -f "$stable" ]; then
    echo "::error::STABLE_VERDICT must point to an existing verdict JSON (got: '$stable')" >&2
    exit 1
  fi

  # 1. Post ONLY stable's verdict. The shadow verdict is never handed to
  #    post-pr-review.sh (or gh), so `next` output can never reach the PR.
  #    post-pr-review.sh exits 100 for an intentional no-op (skip / self-approve);
  #    that is not a shadow-run failure.
  local post_rc=0
  bash "$SCRIPT_DIR/post-pr-review.sh" "$pr_url" "$stable" "$dry_run" || post_rc=$?
  if [ "$post_rc" -ne 0 ] && [ "$post_rc" -ne 100 ]; then
    echo "::error::posting stable review failed (exit $post_rc)" >&2
    exit "$post_rc"
  fi

  # 2 + 3. Log the shadow verdict and compare it against stable. A missing or
  #        unparseable shadow verdict degrades to SKIPPED — never blocks.
  local today classification
  today="$(date -u +%Y-%m-%d)"
  local s_dec s_risk n_dec n_risk
  s_dec=$(jq -r '.decision // ""' "$stable" 2>/dev/null || echo "")
  s_risk=$(jq -r '.risk // ""' "$stable" 2>/dev/null || echo "")

  local shadow_log="${SHADOW_LOG:-$(mktemp)}"
  if [ -n "$shadow" ] && [ -f "$shadow" ]; then
    n_dec=$(jq -r '.decision // ""' "$shadow" 2>/dev/null || echo "")
    n_risk=$(jq -r '.risk // ""' "$shadow" 2>/dev/null || echo "")
    classification=$(shadow_compare_verdicts "$stable" "$shadow" 2>/dev/null || echo "SKIPPED")
    {
      printf '=== shadow verdict (NOT posted) — %s — %s ===\n' "$today" "$pr_url"
      printf 'classification: %s | stable: %s/%s | next: %s/%s\n' \
        "$classification" "$s_dec" "$s_risk" "$n_dec" "$n_risk"
      cat "$shadow"
      printf '\n'
    } >> "$shadow_log"
  else
    n_dec=""
    n_risk=""
    classification="SKIPPED"
    echo "::warning::shadow verdict missing or unreadable ('$shadow') — shadow comparison SKIPPED (stable review unaffected)" >&2
  fi

  local signal report
  signal=$(shadow_signal "$classification")
  report=$(shadow_report "$classification" "$s_dec" "$s_risk" "$n_dec" "$n_risk" "$pr_url" "$today")

  printf '%s\n' "$report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "${SHADOW_OUT:-}" ]; then
    printf '%s\n' "$report" > "$SHADOW_OUT"
  fi

  # 4. Emit the required promotion signal.
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "SHADOW_CLASSIFICATION=${classification}"
      echo "SHADOW_SIGNAL=${signal}"
      [ "$signal" = "FAIL" ] && echo "SHADOW_REGRESSION=true"
    } >> "$GITHUB_ENV"
  fi

  if [ "$signal" = "FAIL" ]; then
    # Shadow is non-blocking on the PR itself (stable was already posted); the
    # signal is what health-gated promotion consumes. Surface a warning, exit 0.
    echo "::warning::shadow regression detected on $pr_url — next-channel promotion must HOLD (signal=FAIL)" >&2
  else
    echo "::notice::shadow comparison ${classification} (signal=${signal}) for $pr_url" >&2
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
