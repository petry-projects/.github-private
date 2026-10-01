#!/usr/bin/env bash
# delayed-rate-limit-retry.sh — deterministic near-reset retry for a PR whose
# review was withheld because an advisory reviewer was rate-limited (issue #1994).
#
# WHY this exists. When pr-review defers a PR it stamps
#   <!-- pr-review-agent rate-limited v1 sha=<HEAD> status=rate-limited reset=<ISO> -->
# and the ONLY thing that re-dispatches the review after <reset> is the scheduled
# pr-review-sweep.yml cron — which GitHub drops under load (observed 3-7 h instead
# of every 15 min, #1952). This script is ARMED by the sweep's defer branch (via a
# pr-review-delayed-retry.yml workflow_dispatch) when <reset> is near. It sleeps
# until <reset> (+ a small buffer), confirms the marker still applies at the SAME
# head, then DELEGATES to the sweep scoped to this one PR — i.e. re-dispatches the
# review through exactly the path the sweep uses, never force-reviewing.
#
# Idempotency and cross-PR isolation are the retry workflow's concern (a per-(PR,
# head) concurrency group). This script adds the two guards that must hold at
# wake time:
#   • supersession — if the current head SHA no longer equals the armed HEAD_SHA,
#     a newer push has taken over (its push event drives a fresh review), so the
#     stale retry is a clean no-op.
#   • delegation with ARM_DELAYED_RETRY=false — the sweep re-validates the marker,
#     standing verdict, CI and exclusions and decides whether to re-dispatch, and
#     cannot re-arm another retry (no loop).
#
# The sweep remains the ultimate backstop: if this retry no-ops or is cancelled,
# the next cron sweep still catches the PR. This path only makes the common
# near-reset case fast.
#
# Env / inputs:
#   PR_URL                     (required) the deferred PR's html_url
#   HEAD_SHA                   (required) the head the rate-limit marker was armed on
#   NOT_BEFORE                 ISO-8601 reset time to wait for (the marker's reset=)
#   DELAYED_RETRY_BUFFER_SEC   seconds added after NOT_BEFORE before retrying (default 120)
#   DELAYED_RETRY_MAX_SLEEP_SEC safety ceiling on the sleep (default 3720)
#   AGENT_REPO                 owner/repo hosting the trigger workflow (passed to the sweep)
#   SWEEP_SCRIPT               path to sweep-stuck-reviews.sh (default: sibling script)
#   DRY_RUN                    "true"/"1" → delegate in dry-run (log, never dispatch)
#   GH_TOKEN                   a PAT with workflow scope (required for the real dispatch)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR_URL="${PR_URL:-}"
HEAD_SHA="${HEAD_SHA:-}"
NOT_BEFORE="${NOT_BEFORE:-}"
AGENT_REPO="${AGENT_REPO:-petry-projects/.github-private}"
SWEEP_SCRIPT="${SWEEP_SCRIPT:-$SCRIPT_DIR/sweep-stuck-reviews.sh}"
DELAYED_RETRY_BUFFER_SEC="${DELAYED_RETRY_BUFFER_SEC:-120}"
DELAYED_RETRY_MAX_SLEEP_SEC="${DELAYED_RETRY_MAX_SLEEP_SEC:-3720}"

case "$DELAYED_RETRY_BUFFER_SEC" in ''|*[!0-9]*) DELAYED_RETRY_BUFFER_SEC=120 ;; esac
case "$DELAYED_RETRY_MAX_SLEEP_SEC" in ''|*[!0-9]*) DELAYED_RETRY_MAX_SLEEP_SEC=3720 ;; esac

if [ -z "$PR_URL" ] || [ -z "$HEAD_SHA" ]; then
  echo "::error::delayed-rate-limit-retry: PR_URL and HEAD_SHA are required"
  exit 2
fi

echo "=== Delayed rate-limit retry ==="
echo "  PR:         $PR_URL"
echo "  Armed head: ${HEAD_SHA:0:8}"
echo "  Not before: ${NOT_BEFORE:-<none>}"

# ---------------------------------------------------------------------------
# 1. Sleep until NOT_BEFORE + buffer (bounded by the safety ceiling).
# ---------------------------------------------------------------------------
now_epoch=$(date -u +%s)
nb_epoch=$(date -u -d "$NOT_BEFORE" +%s 2>/dev/null \
  || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$NOT_BEFORE" +%s 2>/dev/null \
  || echo "")

if [ -n "$nb_epoch" ]; then
  target=$(( nb_epoch + DELAYED_RETRY_BUFFER_SEC ))
  sleep_secs=$(( target - now_epoch ))
  if [ "$sleep_secs" -gt "$DELAYED_RETRY_MAX_SLEEP_SEC" ]; then
    # A malformed/far reset must never sleep unbounded; cap and let the re-check
    # (and the cron backstop) govern correctness.
    echo "  sleep:      capping $sleep_secs s at ${DELAYED_RETRY_MAX_SLEEP_SEC}s ceiling"
    sleep_secs="$DELAYED_RETRY_MAX_SLEEP_SEC"
  fi
  if [ "$sleep_secs" -gt 0 ]; then
    echo "  sleep:      ${sleep_secs}s until reset+buffer"
    sleep "$sleep_secs"
  else
    echo "  sleep:      reset already elapsed — proceeding immediately"
  fi
else
  # An unparseable NOT_BEFORE fails open: proceed now and let the marker re-check
  # and the sweep's own reset gate decide, rather than stranding the PR.
  echo "  sleep:      NOT_BEFORE unparseable — proceeding immediately"
fi

# ---------------------------------------------------------------------------
# 2. Supersession guard — the armed head must still be the current head.
# ---------------------------------------------------------------------------
if ! snapshot=$(gh pr view "$PR_URL" --json headRefOid 2>/dev/null); then
  echo "  no-op: could not fetch $PR_URL (deleted, no access, or rate-limited) — leaving to the cron sweep"
  exit 0
fi
current_head=$(jq -r '.headRefOid // ""' <<< "$snapshot")
if [ -z "$current_head" ]; then
  echo "  no-op: current head SHA empty for $PR_URL — leaving to the cron sweep"
  exit 0
fi
if [ "$current_head" != "$HEAD_SHA" ]; then
  echo "  no-op: head advanced ${HEAD_SHA:0:8} -> ${current_head:0:8} — superseded by a newer push; its event drives a fresh review"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Delegate to the sweep scoped to this one PR. The sweep re-validates the
#    rate-limit marker, standing verdict, CI and exclusions and re-dispatches
#    through the normal trigger (never force). ARM_DELAYED_RETRY=false so it
#    cannot re-arm another retry, and the event name is unset so the #1408
#    scheduled-narrowing does not apply to this targeted retry.
# ---------------------------------------------------------------------------
one_pr_file="$(mktemp)"
trap 'rm -f "$one_pr_file"' EXIT
printf '%s\n' "$PR_URL" > "$one_pr_file"

echo "  retry: delegating to the sweep for $PR_URL (head ${HEAD_SHA:0:8})"
SWEEP_PRS_FILE="$one_pr_file" \
ARM_DELAYED_RETRY=false \
AGENT_REPO="$AGENT_REPO" \
DRY_RUN="${DRY_RUN:-false}" \
GITHUB_EVENT_NAME="" \
  bash "$SWEEP_SCRIPT"
