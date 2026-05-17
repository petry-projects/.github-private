#!/usr/bin/env bash
# Org-wide Actions Fleet Monitor.
#
# Dynamically discovers all non-archived repos in an org, all active
# workflows per repo, and fetches run telemetry for each over the lookback
# window. Writes a fleet summary to GITHUB_STEP_SUMMARY and
# fleet_monitor_report.md. Sets HAS_FAILURES=true in GITHUB_ENV when any
# workflow has failed runs.
#
# Env vars consumed:
#   GH_TOKEN        — PAT with actions:read across the org, consumed by gh CLI;
#                     intentionally a PAT (not GITHUB_TOKEN) because the default
#                     Actions token lacks cross-org actions:read
#   GH_PAT_FALLBACK — optional secondary token if primary lacks org-level access
#   ORG             — GitHub org to scan (default: petry-projects)
#   LOOKBACK_DAYS   — days of history to consider (default: 1)
#   GITHUB_ENV      — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner (1 MB hard limit per job)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/fleet_report.sh
source "${SCRIPT_DIR}/fleet_report.sh"

ORG="${ORG:-petry-projects}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
REPORT_FILE="fleet_monitor_report.md"
TODAY=$(date -u +%Y-%m-%d)

echo "=== Actions Fleet Monitor ==="
echo "  Org:      $ORG"
echo "  Lookback: ${LOOKBACK_DAYS} day(s)"
echo "  Date:     $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token check — fall back to GH_PAT_FALLBACK if org is not reachable
# ---------------------------------------------------------------------------
if ! gh api "orgs/${ORG}" >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access org ${ORG} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
    if ! gh api "orgs/${ORG}" >/dev/null 2>&1; then
      echo "::error::GH_PAT_FALLBACK also cannot access org ${ORG}."
      exit 1
    fi
  else
    echo "::error::GH_TOKEN cannot access org ${ORG} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Discover repos
# ---------------------------------------------------------------------------
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

echo "Discovering repos in ${ORG}..."
repos_raw=$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
  --jq '.[] | select(.archived == false) | .full_name' 2>/dev/null || true)

if [ -z "$repos_raw" ]; then
  echo "::error::No repos returned — check token has read:org and repo access."
  exit 1
fi

mapfile -t repos < <(echo "$repos_raw" | sort)
repo_count="${#repos[@]}"
echo "Found ${repo_count} non-archived repos — window: since ${CUTOFF}"
echo ""

# ---------------------------------------------------------------------------
# 2. Collect metrics per repo → per workflow
# ---------------------------------------------------------------------------
metrics_file=$(mktemp)
failed_file=$(mktemp)
any_failures=0
total_workflows=0

for repo in "${repos[@]}"; do
  printf '  %s\n' "$repo"

  if ! workflows_raw=$(gh api "repos/${repo}/actions/workflows?per_page=100" --paginate \
    --jq '[.workflows[] | select(.state == "active") | {id: (.id | tostring), file: (.path | split("/") | last)}]' \
    2>/dev/null); then
    echo "::warning::Cannot read workflows for ${repo} — check token has actions:read"
    continue
  fi
  workflows=$(echo "$workflows_raw" | jq -s 'add // []')

  wf_count=$(echo "$workflows" | jq 'length')
  [ "$wf_count" -eq 0 ] && continue
  total_workflows=$(( total_workflows + wf_count ))

  while IFS=$'\t' read -r wf_id wf_file; do
    # Note: GitHub caps created>= queries at 1,000 results even with --paginate.
    # At >1,000 runs/window (>143/day) older runs are silently omitted.
    if ! runs_raw=$(gh api \
      "repos/${repo}/actions/workflows/${wf_id}/runs?per_page=100&created=>=${CUTOFF}" \
      --paginate \
      --jq '.workflow_runs | map({
        run_number: .run_number,
        conclusion: .conclusion,
        created_at: .created_at,
        html_url: .html_url,
        duration_s: ((.updated_at | fromdate) - (.created_at | fromdate) | floor)
      })' 2>/dev/null); then
      echo "::warning::Cannot read runs for ${repo}/${wf_file} — recording as ERROR"
      # Record an ERROR sentinel so the report shows this workflow as unresolvable
      # rather than silently omitting it (which could produce a falsely clean result).
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "6" "$repo" "$wf_file" "?" "" "" "" "error" "0" "0" "ERROR" "0" \
        >> "$metrics_file"
      any_failures=1  # ERROR rows represent monitor failures that need attention
      continue
    fi
    # Exclude queued/in_progress runs — only completed conclusions give valid metrics.
    runs_json=$(echo "$runs_raw" | jq -s 'add // [] | [.[] | select(.conclusion != null)]')

    total=$(echo "$runs_json" | jq 'length')
    failed=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required")] | length')
    success=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "success")] | length')
    cancelled=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "cancelled")] | length')

    if [ "$total" -gt 0 ]; then
      rate_int=$(( failed * 100 / total ))
      rate_display=$(awk -v f="$failed" -v t="$total" \
        'BEGIN { pct = f * 100 / t; printf (pct == int(pct)) ? "%d%%" : "%.1f%%", pct }')
      # Use exact float comparison so 1/200 = 0.5% correctly classifies as WARNING,
      # not HEALTHY (which integer truncation would produce).
      read -r label sort_key < <(awk -v f="$failed" -v t="$total" 'BEGIN {
        pct = f * 100 / t
        if (f == 0)    { print "HEALTHY 3" }
        else if (pct > 50) { print "CRITICAL 0" }
        else if (pct > 20) { print "DEGRADED 1" }
        else               { print "WARNING 2"  }
      }')
    else
      rate_int=0
      rate_display="n/a"
      label="—"
      sort_key=4
    fi

    read -r p50 p95 < <(echo "$runs_json" | jq -r '
      [.[] | select(.conclusion != null and .duration_s > 0) | .duration_s] | sort |
      if length == 0 then "0 0"
      else . as $d | ($d | length) as $n |
        "\($d[$n * 50 / 100 | floor]) \($d[$n * 95 / 100 | floor])"
      end')

    # 12 fields: sort_key repo wf_file total success failed cancelled
    #            rate_display p50 p95 label rate_int
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sort_key" "$repo" "$wf_file" \
      "$total" "$success" "$failed" "$cancelled" \
      "$rate_display" "$p50" "$p95" "$label" "$rate_int" \
      >> "$metrics_file"

    if [ "$failed" -gt 0 ]; then
      any_failures=1
      {
        printf '\n### `%s` / `%s`\n\n' "$repo" "$wf_file"
        printf '| Run | Date | Duration | Link |\n|---|---|---|---|\n'
        while IFS=$'\t' read -r run_num created_at dur_s url; do
          printf '| #%s | %s | %s | [view](%s) |\n' \
            "$run_num" "${created_at%%T*}" "$(fmt_dur "$dur_s")" "$url"
        done < <(echo "$runs_json" | jq -r '
          [.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required")] | sort_by(.run_number) | reverse[] |
          [(.run_number | tostring), .created_at, (.duration_s | tostring), .html_url] | @tsv')
      } >> "$failed_file"
    fi
  done < <(echo "$workflows" | jq -r '.[] | [.id, .file] | @tsv')
done

# ---------------------------------------------------------------------------
# 3. Generate reports
# ---------------------------------------------------------------------------
report_header() {
  printf '# Actions Fleet Monitor — %s\n\n' "$TODAY"
  printf '**Org:** `%s` | **Lookback:** %s day(s) | **Repos:** %s | **Workflows:** %s\n\n' \
    "$ORG" "$LOOKBACK_DAYS" "$repo_count" "$total_workflows"
}

# Step Summary — Tier 1 visualizations only (Mermaid not rendered there)
# GitHub Step Summary has a 1 MB hard limit per job. At ~200 bytes per row
# this supports ~5 000 workflows before truncation.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { report_header; generate_report "$metrics_file" "$failed_file" "false"; } \
    >> "$GITHUB_STEP_SUMMARY"
fi

# Report file — full report with Mermaid charts (used as Issue body)
{ report_header; generate_report "$metrics_file" "$failed_file" "true"; } \
  > "$REPORT_FILE"

rm -f "$metrics_file" "$failed_file"

# ---------------------------------------------------------------------------
# 4. Export env flags
# ---------------------------------------------------------------------------
if [ "$any_failures" -eq 1 ]; then
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
fi

echo ""
echo "Report: $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Fleet monitor complete ==="
