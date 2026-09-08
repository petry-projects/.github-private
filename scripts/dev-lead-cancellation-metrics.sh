#!/usr/bin/env bash
set -euo pipefail
# dev-lead-cancellation-metrics.sh — measure the dev-lead cancelled-run share
# over a window (#1741 AC #5).
#
# The issue's headline number (42% of runs cancelled, 30 of them within 60s of
# creation, over 100 runs / 8 PRs on 2026-09-08 11:50Z) was gathered by a manual
# API sweep. AC #5 asks for the same measurement to be REPEATABLE so the
# post-change share can be recorded next to that baseline. This script makes it a
# one-command report instead of a hand-run jq sweep.
#
# A run whose conclusion is "cancelled" and whose lifetime (created_at →
# updated_at) is under NEVER_RAN_SEC seconds "never really ran" — it was a
# pending run dropped by the concurrency group before any job started, which is
# exactly the dropped-work class this issue is about.
#
# Env (optional):
#   REPO             — owner/repo to measure (default: petry-projects/.github-private)
#   WORKFLOW_FILE    — dev-lead caller stub file name (default: dev-lead.yml)
#   SINCE_ISO        — window start (ISO-8601 UTC). Default: 1h before now.
#   UNTIL_ISO        — window end   (ISO-8601 UTC). Default: now.
#   NEVER_RAN_SEC    — "never really ran" threshold in seconds (default: 60)
#   NOW_ISO          — override current time for deterministic default window
#
# Pure helpers (compute_cancellation_metrics / filter_runs_in_window) are sourced
# by tests; main() only runs when executed directly.

NEVER_RAN_SEC="${NEVER_RAN_SEC:-60}"

# filter_runs_in_window <runs_json> <since_iso> <until_iso>
# Keeps runs whose created_at is within [since, until] inclusive.
filter_runs_in_window() {
  local runs_json="$1" since="$2" until="$3"
  jq -c \
    --arg since "$since" \
    --arg until "$until" \
    '[ .[] | select(
        (.created_at | fromdateiso8601) >= ($since | fromdateiso8601) and
        (.created_at | fromdateiso8601) <= ($until | fromdateiso8601)
      ) ]' <<< "$runs_json"
}

# compute_cancellation_metrics <runs_json> [never_ran_sec]
# Emits a compact JSON summary: total, cancelled, cancelled_pct (rounded int),
# never_ran (cancelled with lifetime < threshold), never_ran_pct.
compute_cancellation_metrics() {
  local runs_json="$1" thr="${2:-$NEVER_RAN_SEC}"
  jq -n \
    --argjson runs "$runs_json" \
    --argjson thr "$thr" \
    '
    ($runs | length) as $total
    | [ $runs[] | select(.conclusion == "cancelled") ] as $canc
    | ($canc | length) as $cancelled
    | [ $canc[]
        | select(
            (((.updated_at // .created_at) | fromdateiso8601)
             - (.created_at | fromdateiso8601)) < $thr
          ) ] as $never
    | ($never | length) as $never_ran
    | {
        total: $total,
        cancelled: $cancelled,
        cancelled_pct: (if $total > 0 then (($cancelled * 100 / $total) | round) else 0 end),
        never_ran: $never_ran,
        never_ran_pct: (if $total > 0 then (($never_ran * 100 / $total) | round) else 0 end)
      }'
}

# fetch_dev_lead_runs <repo> <workflow_file> — all runs for the workflow (paged).
fetch_dev_lead_runs() {
  local repo="$1" wf="$2"
  gh api --paginate "repos/${repo}/actions/workflows/${wf}/runs?per_page=100" \
    --jq '[.workflow_runs[] | {conclusion, status, created_at, updated_at, run_started_at, event}]' \
    2>/dev/null | jq -s 'add // []'
}

main() {
  local repo="${REPO:-petry-projects/.github-private}"
  local wf="${WORKFLOW_FILE:-dev-lead.yml}"
  local now_iso="${NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local until_iso="${UNTIL_ISO:-$now_iso}"
  local since_iso="${SINCE_ISO:-}"
  if [ -z "$since_iso" ]; then
    since_iso=$(date -u -d "$until_iso - 1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$until_iso")
  fi

  echo "[metrics] dev-lead cancellation share for ${repo} (${wf})"
  echo "[metrics] window ${since_iso} .. ${until_iso}  never_ran_threshold=${NEVER_RAN_SEC}s"

  local runs windowed metrics
  runs=$(fetch_dev_lead_runs "$repo" "$wf")
  windowed=$(filter_runs_in_window "$runs" "$since_iso" "$until_iso")
  metrics=$(compute_cancellation_metrics "$windowed" "$NEVER_RAN_SEC")

  echo "$metrics" | jq .

  local total cancelled pct never never_pct
  total=$(jq -r '.total' <<< "$metrics")
  cancelled=$(jq -r '.cancelled' <<< "$metrics")
  pct=$(jq -r '.cancelled_pct' <<< "$metrics")
  never=$(jq -r '.never_ran' <<< "$metrics")
  never_pct=$(jq -r '.never_ran_pct' <<< "$metrics")

  {
    echo "### dev-lead cancellation share"
    echo ""
    echo "| metric | value |"
    echo "|---|---|"
    echo "| window | ${since_iso} .. ${until_iso} |"
    echo "| runs | ${total} |"
    echo "| cancelled | ${cancelled} (${pct}%) |"
    echo "| never really ran (<${NEVER_RAN_SEC}s) | ${never} (${never_pct}%) |"
    echo ""
    echo "Baseline (2026-09-08 11:50Z, 8 PRs): 100 runs, 42 cancelled (42%), 30 never ran."
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
