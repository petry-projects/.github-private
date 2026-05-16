#!/usr/bin/env bash
# Daily telemetry check for the PR Review Agent workflow.
#
# Fetches recent pr-review.yml run data, computes health metrics, and
# writes a structured markdown report to both GITHUB_STEP_SUMMARY and
# pr_review_health_report.md. Sets HAS_FAILURES=true in GITHUB_ENV when
# failed runs are detected.
#
# Env vars consumed:
#   GH_TOKEN      — must have actions:read on WORKFLOW_REPO
#   LOOKBACK_DAYS — days of history to consider (default: 1)
#   GITHUB_ENV    — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner

set -euo pipefail

LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
WORKFLOW_REPO="${AGENT_REPO:-petry-projects/.github-private}"
WORKFLOW_FILE="pr-review.yml"
REPORT_FILE="pr_review_health_report.md"
TODAY=$(date -u +%Y-%m-%d)

echo "=== PR Review Agent — Daily Health Check ==="
echo "  Repo:         $WORKFLOW_REPO"
echo "  Workflow:     $WORKFLOW_FILE"
echo "  Lookback:     ${LOOKBACK_DAYS} day(s)"
echo "  Date:         $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token selection
# ---------------------------------------------------------------------------
if ! gh api "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=1" \
     >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access ${WORKFLOW_REPO} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
  else
    echo "::error::GH_TOKEN cannot access ${WORKFLOW_REPO} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Fetch run metadata
# ---------------------------------------------------------------------------
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

echo "Fetching runs since: $CUTOFF"

runs_json=$(gh api \
  "repos/${WORKFLOW_REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=100&created=>=${CUTOFF}" \
  --jq '.workflow_runs | map({
    id: .id,
    run_number: .run_number,
    status: .status,
    conclusion: .conclusion,
    created_at: .created_at,
    html_url: .html_url,
    duration_s: ((.updated_at | fromdate) - (.created_at | fromdate))
  })' 2>/dev/null || echo '[]')

# ---------------------------------------------------------------------------
# 2. Compute aggregate stats
# ---------------------------------------------------------------------------
read -r total_runs failed_runs success_runs cancelled_runs < <(echo "$runs_json" | jq -r '
  [
    length,
    ([.[] | select(.conclusion == "failure")] | length),
    ([.[] | select(.conclusion == "success")] | length),
    ([.[] | select(.conclusion == "cancelled")] | length)
  ] | @tsv')

echo "  Total:      $total_runs"
echo "  Success:    $success_runs"
echo "  Failed:     $failed_runs"
echo "  Cancelled:  $cancelled_runs"

if [ "$total_runs" -gt 0 ]; then
  failure_rate=$(echo "scale=1; $failed_runs * 100 / $total_runs" | bc)
else
  failure_rate="0.0"
fi

# Duration percentiles across all completed runs
read -r dur_min dur_p50 dur_p95 dur_max < <(echo "$runs_json" | jq -r '
  [.[] | select(.conclusion != null and .duration_s > 0) | .duration_s] | sort |
  if length == 0 then "0 0 0 0"
  else . as $d | ($d | length) as $n |
    "\($d | min) \($d[$n * 50 / 100 | floor]) \($d[$n * 95 / 100 | floor]) \($d | max)"
  end')

# ---------------------------------------------------------------------------
# 3. Helpers
# ---------------------------------------------------------------------------
fmt_dur() {
  local s=$1
  if [ "$s" -ge 60 ]; then
    printf '%dm%ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

conclusion_icon() {
  case "$1" in
    success)   echo "✅" ;;
    failure)   echo "❌" ;;
    cancelled) echo "⚪" ;;
    skipped)   echo "⏭️" ;;
    *)         echo "⏳" ;;
  esac
}

if [ "$failed_runs" -eq 0 ]; then
  overall="HEALTHY"
elif [ "$(echo "$failure_rate > 50" | bc)" -eq 1 ]; then
  overall="CRITICAL"
elif [ "$(echo "$failure_rate > 20" | bc)" -eq 1 ]; then
  overall="DEGRADED"
else
  overall="WARNING"
fi

# ---------------------------------------------------------------------------
# 4. Build report
# ---------------------------------------------------------------------------
{
  printf '# PR Review Agent Health — %s\n\n' "$TODAY"
  printf '**Status:** `%s` | **Lookback:** %s day(s) | **Workflow:** `%s`\n\n' \
    "$overall" "$LOOKBACK_DAYS" "$WORKFLOW_FILE"

  printf '## Summary\n\n'
  printf '| Metric | Value |\n|---|---|\n'
  printf '| Total runs | %s |\n' "$total_runs"
  printf '| Successful | %s |\n' "$success_runs"
  printf '| Failed | %s |\n' "$failed_runs"
  printf '| Cancelled | %s |\n' "$cancelled_runs"
  printf '| Failure rate | %s%% |\n' "$failure_rate"
  if [ "$total_runs" -gt 0 ]; then
    printf '| Duration min | %s |\n' "$(fmt_dur $dur_min)"
    printf '| Duration p50 | %s |\n' "$(fmt_dur $dur_p50)"
    printf '| Duration p95 | %s |\n' "$(fmt_dur $dur_p95)"
    printf '| Duration max | %s |\n' "$(fmt_dur $dur_max)"
  fi

  printf '\n## Runs\n\n'
  printf '| Run | Status | Date | Duration | Link |\n|---|---|---|---|---|\n'
  while IFS=$'\t' read -r run_num conclusion created_at dur_s url; do
    icon=$(conclusion_icon "$conclusion")
    date_short="${created_at%%T*}"
    printf '| #%s | %s %s | %s | %s | [view](%s) |\n' \
      "$run_num" "$icon" "$conclusion" "$date_short" "$(fmt_dur $dur_s)" "$url"
  done < <(echo "$runs_json" | jq -r '
    sort_by(.run_number) | reverse[] |
    [(.run_number | tostring), (.conclusion // .status), .created_at, (.duration_s | tostring), .html_url] | @tsv')
} > "$REPORT_FILE"

# ---------------------------------------------------------------------------
# 5. Emit step summary and export env flags
# ---------------------------------------------------------------------------
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

if [ "$failed_runs" -gt 0 ]; then
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
fi

echo ""
echo "Report written to $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Health check complete ==="