#!/usr/bin/env bash
# pr_stall_scan.sh — daily stall-PR detection net (issue #1410, epic #1402).
#
# Scans every OPEN PR in the target repo and flags any that is STALLED: stuck
# CI-green + REVIEW_REQUIRED, not yet reviewed at head, with no agent activity and
# no pending triggering event past a configurable threshold — and NOT human-gated.
# That is the exact silent failure mode the narrowed Class-2 timers (#1407/#1408)
# could introduce; this is the pushed signal that catches it (the #860 lesson:
# detection must be pushed, not pulled). Detection ONLY: this script never
# comments on, labels, or otherwise mutates a PR. It writes a markdown report and
# sets HAS_STALL / STALL_COUNT for the daily health-check workflow to surface
# through the existing health-check / automated-report issue mechanism — NO new
# scheduled workload (AC#4).
#
# Thresholds are env-overridable (see scripts/lib/pr-stall-detect.sh).
#
# Env vars consumed:
#   GH_TOKEN        — must have repo read on REPO (PR list/detail, comments)
#   GH_PAT_FALLBACK — optional secondary token if the primary can't read REPO
#   REPO / AGENT_REPO — target repo (default: petry-projects/.github-private)
#   GITHUB_ENV      — written by the Actions runner (HAS_STALL / STALL_COUNT)
#   GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ci-status.sh: compute_ci_status filters the cascade's own checks before
# classifying, exactly as review-one-pr.sh / sweep-stuck-reviews.sh do (#469).
# shellcheck source=scripts/lib/ci-status.sh
source "${SCRIPT_DIR}/lib/ci-status.sh"
# pr-stall-detect.sh sources pr-automation-budget.sh, giving us the canonical
# human-gate check (pr_has_escalation_label), the exhaustion marker constant, and
# gather_pr_automation_events for the last-activity (idle) computation.
# shellcheck source=scripts/lib/pr-stall-detect.sh
source "${SCRIPT_DIR}/lib/pr-stall-detect.sh"

REPO="${REPO:-${AGENT_REPO:-petry-projects/.github-private}}"
REPORT_FILE="${REPORT_FILE:-pr_stall_report.md}"
TODAY=$(date -u +%Y-%m-%d)

echo "=== Stall-PR Detection — Daily Scan ==="
echo "  Repo:   $REPO"
echo "  Date:   $TODAY"
echo "  Threshold: green + REVIEW_REQUIRED idle > ${STALL_MIN_AGE_MINUTES}m (not human-gated)"
echo ""

# ---------------------------------------------------------------------------
# 0. Token selection — fall back to GH_PAT_FALLBACK if REPO is unreachable
# ---------------------------------------------------------------------------
if ! gh api "repos/${REPO}" >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access ${REPO} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
    if ! gh api "repos/${REPO}" >/dev/null 2>&1; then
      echo "::error::GH_PAT_FALLBACK also cannot access ${REPO}."
      exit 1
    fi
  else
    echo "::error::GH_TOKEN cannot access ${REPO} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Enumerate open PRs
# ---------------------------------------------------------------------------
open_prs=$(gh api --paginate "repos/${REPO}/pulls?state=open&per_page=100" \
  --jq '.[].number' 2>/dev/null) || {
  echo "::error::Failed to fetch open PRs from GitHub API." >&2
  exit 1
}

if [ -z "$open_prs" ]; then
  echo "No open PRs in ${REPO}."
fi

# ---------------------------------------------------------------------------
# 2. Per-PR state -> detection (detection only, no mutation)
# ---------------------------------------------------------------------------
candidates_file=$(mktemp) || {
  echo "Failed to create temp file" >&2
  exit 1
}
trap 'rm -f "$candidates_file"' EXIT
now_epoch=$(date -u +%s)
scanned=0

while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  scanned=$(( scanned + 1 ))

  # One snapshot gives CI rollup, review decision, head, review/comment bodies,
  # labels, title, and url — the same shape sweep-stuck-reviews.sh consumes.
  if ! snapshot=$(gh pr view "$pr" --repo "$REPO" \
        --json headRefOid,statusCheckRollup,reviewDecision,reviews,comments,labels,title,url,updatedAt 2>/dev/null); then
    echo "  skip PR #${pr} — could not fetch (deleted, no access, or rate-limited)"
    continue
  fi

  review_decision=$(jq -r '.reviewDecision // ""' <<< "$snapshot")
  head_sha=$(jq -r '.headRefOid // ""' <<< "$snapshot")
  title=$(jq -r '.title // ""' <<< "$snapshot")
  html_url=$(jq -r '.url // ""' <<< "$snapshot")
  updated_at=$(jq -r '.updatedAt // ""' <<< "$snapshot")

  ci_status=$(compute_ci_status "$(jq '.statusCheckRollup' <<< "$snapshot")")

  # Already reviewed at this exact head? The cascade stamps each review with
  # `<!-- pr-review-agent v1 sha=<HEAD> -->`; a marker at the current head means
  # the automated step ran, so the PR is not stalled. Match the sha followed by a
  # space so one sha is never treated as a prefix of another (same as the sweep).
  reviewed_at_head=$(jq -r --arg sha "$head_sha" '
    [ ((.reviews // []) + (.comments // []))[]
      | (.body // "")
      | select(test("<!-- pr-review-agent v1 sha=" + $sha + " ")) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0)

  # Human-gate exclusions (AC#2). Labels + the pr-automation-budget exhaustion
  # marker (a comment) are the intentional stops; pr_stall_is_gated owns the
  # canonical decision.
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$snapshot" 2>/dev/null || echo '[]')
  marker_present=$(jq -r --arg m "$PR_AUTOMATION_EXHAUSTION_MARKER" '
    [ ((.reviews // []) + (.comments // []))[] | (.body // "") ]
    | map(select(contains($m))) | (length > 0)' <<< "$snapshot" 2>/dev/null || echo false)
  gated=false
  if pr_stall_is_gated "$labels_json" "$marker_present"; then
    gated=true
  fi

  # Idle minutes = time since the last activity of ANY kind (commit / comment /
  # review) — reuse the #926 event gather so "activity" means the same thing the
  # budget breaker counts. Fall back to the PR's updated_at when there are none.
  events=$(gather_pr_automation_events "$pr" "$REPO")
  last_activity=$(jq -r '[ .[] | .when | select(. != null and . != "") ] | max // ""' <<< "$events" 2>/dev/null || echo "")
  [ -n "$last_activity" ] || last_activity="$updated_at"
  mins_idle=$(pr_minutes_since "$last_activity" "$now_epoch")

  reason=$(pr_stall_reasons "$ci_status" "$review_decision" "$reviewed_at_head" "$mins_idle" "$gated")
  if [ -n "$reason" ]; then
    # Sanitize the title for a single markdown table cell: strip newlines/tabs
    # (the TSV delimiter) and pipes (the markdown column delimiter).
    safe_title=$(printf '%s' "$title" | tr '\n\t|' '   ')
    printf '%s\t%s\t%s\t%s\n' "$pr" "$html_url" "$safe_title" "$reason" \
      >> "$candidates_file"
    echo "::warning::Stalled PR #${pr} — ${reason}"
  fi
done <<< "$open_prs"

# grep -c prints the count even at zero matches (exiting 1), so `|| true` swallows
# that exit without appending a second "0".
stall_count=$(grep -c . "$candidates_file" 2>/dev/null || true)
stall_count=${stall_count:-0}
echo "Scanned ${scanned} open PR(s); ${stall_count} stall candidate(s)."

# ---------------------------------------------------------------------------
# 3. Render report + export env flags
# ---------------------------------------------------------------------------
{
  printf '# Stalled PR Detection — %s\n\n' "$TODAY"
  printf '**Repo:** `%s` | **Open PRs scanned:** %s | **Candidates:** %s\n\n' \
    "$REPO" "$scanned" "$stall_count"
  generate_stall_report "$candidates_file"
} > "$REPORT_FILE"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "STALL_COUNT=${stall_count}" >> "$GITHUB_ENV"
  if [ "$stall_count" -gt 0 ]; then
    echo "HAS_STALL=true" >> "$GITHUB_ENV"
  else
    echo "HAS_STALL=false" >> "$GITHUB_ENV"
  fi
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Stall-PR scan complete ==="
