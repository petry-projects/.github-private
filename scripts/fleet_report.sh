#!/usr/bin/env bash
# fleet_report.sh — visualization and report generation for the Actions Fleet Monitor.
# Sourced by fleet_monitor.sh. All functions are pure (accept args / stdin; write stdout).
#
# Metrics TSV format (12 fields, tab-separated):
#   1:sort_key  2:repo  3:wf_file  4:total  5:success  6:failed
#   7:cancelled  8:rate_display  9:p50(s)  10:p95(s)  11:label  12:rate_int

# Gate workflows: their `failure` conclusion is intentional policy enforcement
# (e.g. blocking a PR that violates a rule), not flakiness or breakage. A high
# "failure rate" for these is the guard doing its job, so they are excluded from
# high-failure issue tracking to avoid false-positive Fleet Monitor trackers
# (#941). Matched by workflow file basename. See AGENTS.md "Exception:
# test-deletion-guard.yml". Override via env with the full space-separated
# gate list for testing; add permanent gates to the default below.
FLEET_GATE_WORKFLOWS="${FLEET_GATE_WORKFLOWS:-test-deletion-guard.yml holdout-guard.yml}"

# Dev-Lead status-marker prefix (#1019, story C of #901). Mirrors
# ISSUE_MARKER_PREFIX in dev-lead-fix-issue.sh / dev-lead-retry.sh: every
# dev-lead failure/retry/escalation posts an HTML-comment marker of the form
#   <!-- dev-lead-issue <N> status=<s> attempt=<k> reason=<r> run=<id> [reset=...] -->
# GitHub search cannot index HTML comments, so callers pass the repo's windowed
# issue comments (issues/comments?since=) and summarize_dev_lead_timeouts tallies
# the markers by their reason= field. Kept in one place so a rename in the
# dev-lead scripts is a one-line fix here.
DEV_LEAD_ISSUE_MARKER="${DEV_LEAD_ISSUE_MARKER:-<!-- dev-lead-issue }"

# label_to_icon <label>
# Returns the health icon matching the scorecard legend.
label_to_icon() {
  case "$1" in
    CRITICAL) printf '🔴' ;;
    DEGRADED) printf '🟠' ;;
    WARNING)  printf '🟡' ;;
    HEALTHY)  printf '✅' ;;
    ERROR)    printf '⚫' ;;
    LOW-CONF) printf '🟡' ;;
    *)        printf '⬜' ;;
  esac
}

# fmt_dur <seconds>
# Formats an integer number of seconds as "XmYs" or "Zs".
fmt_dur() {
  local s="${1:-0}"
  if [ "$s" -ge 60 ]; then
    printf '%dm%ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%ds' "$s"
  fi
}

# generate_scorecard <metrics_file>
# Prints a one-line fleet health summary with counts per status.
generate_scorecard() {
  local f="$1"
  local critical degraded warning healthy
  critical=$(awk -F'\t' '$11 == "CRITICAL"' "$f" | wc -l | tr -d ' ')
  degraded=$(awk -F'\t' '$11 == "DEGRADED"' "$f" | wc -l | tr -d ' ')
  warning=$(awk -F'\t'  '$11 == "WARNING"'  "$f" | wc -l | tr -d ' ')
  healthy=$(awk -F'\t'  '$11 == "HEALTHY"'  "$f" | wc -l | tr -d ' ')
  printf '🔴 CRITICAL: %s  🟠 DEGRADED: %s  🟡 WARNING: %s  ✅ HEALTHY: %s\n' \
    "$critical" "$degraded" "$warning" "$healthy"
}

# apply_confidence_filter
# Reads metrics rows from stdin; re-labels CRITICAL rows with < 5 total runs
# as LOW-CONF and moves them to sort_key 5 (sorted after HEALTHY).
apply_confidence_filter() {
  awk 'BEGIN { FS=OFS="\t" } {
    if ($11 == "CRITICAL" && $4 + 0 < 5) { $1 = 5; $11 = "LOW-CONF" }
    print
  }'
}

# filter_high_failure <metrics_file>
# Reads a metrics TSV and prints fleet_high_failure JSON — the array of workflows
# worth tracking as a per-workflow issue:
#   * ERROR rows (the monitor could not read runs — always noteworthy)
#   * WARNING/DEGRADED/CRITICAL with exact failure rate > 10%
# CRITICAL rows with < 5 total runs are downgraded to LOW-CONF and dropped.
# Gate workflows (FLEET_GATE_WORKFLOWS, matched by basename) are excluded from
# the rate-based path — their failures are intentional policy enforcement (#941) —
# but a gate's ERROR row still surfaces (a read failure is not the gate's doing).
filter_high_failure() {
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "Error: metrics file '${f}' does not exist or is not specified" >&2
    return 1
  fi
  jq -Rn --arg gates "$FLEET_GATE_WORKFLOWS" '
    ($gates | split(" ") | map(select(length > 0))) as $gate |
    [inputs | select(length > 0) | split("\t") | select(length >= 12) |
     {
       sort_key:  .[0],
       repo:      .[1],
       workflow:  .[2],
       total:    (.[3]  | tonumber? // 0),
       success:  (.[4]  | tonumber? // 0),
       failed:   (.[5]  | tonumber? // 0),
       cancelled:(.[6]  | tonumber? // 0),
       rate:      .[7],
       p50:      (.[8]  | tonumber? // 0),
       p95:      (.[9]  | tonumber? // 0),
       label:     .[10],
       rate_int: (.[11] | tonumber? // 0)
     }] |
    # Apply confidence filter: CRITICAL rows with < 5 total runs become LOW-CONF
    map(if .label == "CRITICAL" and .total < 5 then .label = "LOW-CONF" else . end) |
    # Keep trackable items:
    #   ERROR rows (monitor could not read runs — always noteworthy regardless of rate)
    #   non-gate WARNING/DEGRADED/CRITICAL with exact failure rate > 10%
    #   (uses .failed/.total directly to avoid integer-truncation false negatives)
    map(select(
      .label == "ERROR" or
      (
        ((.workflow | split("/") | last | IN($gate[])) | not) and
        .label != "LOW-CONF" and
        (.label | IN("WARNING","DEGRADED","CRITICAL")) and
        .total > 0 and
        (.failed * 100.0 / .total > 10)
      )
    )) |
    sort_by(.failed * 100.0 / (if .total > 0 then .total else 1 end)) | reverse
  ' < "$f"
}

# summarize_dev_lead_timeouts <comments_json>
# Reads a JSON array of issue-comment objects ({body,...}) and tallies dev-lead
# status markers by failure reason. A stage timeout ("wall") is reason=timeout
# (Story B, #1018); generic engine failures are reason=engine-error. Emits TSV:
#   timeout <TAB> engine_error <TAB> total
# `total` is every dev-lead-issue marker in the window (all reasons; there is no
# success marker, so total == dev-lead failure/retry/escalation markers).
# Comments that merely mention `reason=` without the marker prefix are ignored.
# Absent/empty JSON → "0\t0\t0".
summarize_dev_lead_timeouts() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq -r --arg p "$DEV_LEAD_ISSUE_MARKER" '
    [ .[]? | (.body // "") | select(contains($p))
      | (try (capture("reason=(?<r>[a-z]+(?:-[a-z]+)*)").r) catch "unknown") ] as $reasons
    | [ ([ $reasons[] | select(. == "timeout") ]      | length),
        ([ $reasons[] | select(. == "engine-error") ] | length),
        ($reasons | length) ]
    | @tsv'
}

# generate_dev_lead_timeout_report <reason_tsv_file>
# Renders the Dev-Lead timeout ("wall") observability section (#1019, story C of
# #901; prevalence rate #1030). Input is a TSV file with one row per repo that
# had >=1 dev-lead marker in the window:
#   `repo <TAB> timeout <TAB> engine_error <TAB> markers <TAB> total_runs`
# where `markers` is the count of all dev-lead failure/retry/escalation markers
# (the composition breakdown) and `total_runs` is the repo's total dev-lead.yml
# runs in the window (the prevalence denominator, from the fleet monitor's
# per-workflow metrics). Prints a per-repo table (raw timeout + engine-error
# counts retained), fleet totals, and the timeout **prevalence** rate
# (`reason=timeout` / total dev-lead runs — over ALL runs, not just failures) —
# the "wall rate" Story A/B aim to drive down. When total_runs is missing,
# non-numeric (e.g. an ERROR sentinel), or zero for a repo it is shown as `n/a`
# and contributes 0 to the denominator (no divide-by-zero). An empty or missing
# file prints nothing, so the section is omitted when there was no dev-lead
# activity in the window.
generate_dev_lead_timeout_report() {
  local f="${1:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0

  local repo t e tot runs runs_disp
  local sum_t=0 sum_e=0 sum_tot=0 sum_runs=0

  printf '## Dev-Lead Timeouts (walls)\n\n'
  printf 'Stage timeouts (`reason=timeout`) that escalate to a human, broken out from generic `engine-error`, over the window.\n\n'
  printf '| Repo | Timeouts | Engine-errors | Failure markers | Total runs |\n'
  printf '|---|---|---|---|---|\n'
  while IFS=$'\t' read -r repo t e tot runs; do
    [ -n "$repo" ] || continue
    # Sanitize total_runs: empty / non-numeric (ERROR sentinel '?') → 0 → n/a.
    case "${runs:-}" in
      ''|*[!0-9]*) runs=0 ;;
    esac
    runs_disp="n/a"
    [ "$runs" -gt 0 ] && runs_disp="$runs"
    printf '| `%s` | %s | %s | %s | %s |\n' "$repo" "$t" "$e" "$tot" "$runs_disp"
    sum_t=$(( sum_t + ${t:-0} ))
    sum_e=$(( sum_e + ${e:-0} ))
    sum_tot=$(( sum_tot + ${tot:-0} ))
    sum_runs=$(( sum_runs + runs ))
  done < "$f"
  local runs_total_disp="n/a"
  [ "$sum_runs" -gt 0 ] && runs_total_disp="$sum_runs"
  printf '| **Fleet total** | **%s** | **%s** | **%s** | **%s** |\n\n' \
    "$sum_t" "$sum_e" "$sum_tot" "$runs_total_disp"

  local rate
  rate=$(awk -v t="$sum_t" -v n="$sum_runs" 'BEGIN {
    if (n <= 0) { print "n/a"; exit }
    pct = t * 100 / n
    printf (pct == int(pct)) ? "%d%%" : "%.1f%%", pct
  }')
  printf '**Timeout rate** (`reason=timeout` / total dev-lead runs — prevalence over all runs, not just failures): %s (%s / %s)\n' \
    "$rate" "$sum_t" "$runs_total_disp"
}

# detect_systemic_failures <metrics_file>
# Prints the name of each workflow file that has failures in 3 or more repos.
detect_systemic_failures() {
  local f="$1"
  awk -F'\t' '$6 > 0 { print $3 }' "$f" \
    | sort | uniq -c \
    | awk '$1 >= 3 { print $2 }'
}

# flag_duration_variance <p50> <p95>
# Prints ⚠️ when p95 > 5 × p50 and p50 >= 30s; otherwise prints nothing.
flag_duration_variance() {
  local p50="${1:-0}" p95="${2:-0}"
  if [ "$p50" -ge 30 ] && [ "$p95" -gt $(( p50 * 5 )) ]; then
    printf '⚠️'
  fi
}

# generate_ascii_bar <rate_int>
# Prints a 10-character block bar (0–100 → 0–10 filled blocks).
generate_ascii_bar() {
  local rate="${1:-0}"
  local filled=$(( rate / 10 ))
  local bar="" i
  for (( i = 0; i < filled; i++ ));        do bar="${bar}█"; done
  for (( i = 0; i < 10 - filled; i++ )); do bar="${bar}░"; done
  printf '%s' "$bar"
}

# generate_repo_rollup <metrics_file> [issues_file]
# Prints a markdown table with one row per repo: workflow count, total runs,
# total failures, open issue links, and worst status with health icon.
# Repos with no runs in the lookback window are omitted.
generate_repo_rollup() {
  local f="$1"
  local issues_file="${2:-}"
  printf '| Repo | Workflows | Total Runs | Failures | Issues | Worst Status |\n'
  printf '|---|---|---|---|---|---|\n'
  awk 'BEGIN { FS=OFS="\t" } {
    repo = $2
    seen[repo] = 1
    runs[repo]    += $4
    failed[repo]  += $6
    wf_ct[repo]++
    # Lower sort_key = worse status; track minimum
    if (!(repo in best_key) || $1 + 0 < best_key[repo] + 0) {
      best_key[repo]    = $1
      best_label[repo]  = $11
    }
  }
  END {
    for (repo in seen)
      if (runs[repo] + 0 > 0)
        printf "%s\t%s\t%s\t%s\t%s\n",
          repo, wf_ct[repo], runs[repo], failed[repo], best_label[repo]
  }' "$f" | sort -t$'\t' -k1,1 | \
  while IFS=$'\t' read -r repo wf_ct total_runs failed label; do
    local icon issues_links
    icon=$(label_to_icon "$label")
    issues_links=" "
    if [ -n "$issues_file" ] && [ -f "$issues_file" ] && [ -s "$issues_file" ]; then
      issues_links=$(awk -F'\t' -v r="$repo" \
        '$1 == r { printf "[#%s](%s) ", $4, $3 }' "$issues_file")
      issues_links="${issues_links% }"
    fi
    [ -z "$issues_links" ] && issues_links=" "
    printf '| `%s` %s | %s | %s | %s | %s | %s %s |\n' \
      "$repo" "$icon" "$wf_ct" "$total_runs" "$failed" "$issues_links" "$icon" "$label"
  done
}

# generate_mermaid_pie <metrics_file>
# Prints a Mermaid pie chart of workflow status distribution.
generate_mermaid_pie() {
  local f="$1"
  local critical degraded warning healthy
  critical=$(awk -F'\t' '$11 == "CRITICAL"' "$f" | wc -l | tr -d ' ')
  degraded=$(awk -F'\t' '$11 == "DEGRADED"' "$f" | wc -l | tr -d ' ')
  warning=$(awk -F'\t'  '$11 == "WARNING"'  "$f" | wc -l | tr -d ' ')
  healthy=$(awk -F'\t'  '$11 == "HEALTHY"'  "$f" | wc -l | tr -d ' ')
  printf '```mermaid\n'
  printf 'pie title Workflow Status Distribution\n'
  [ "$critical" -gt 0 ] && printf '  "CRITICAL" : %s\n' "$critical"
  [ "$degraded" -gt 0 ] && printf '  "DEGRADED" : %s\n' "$degraded"
  [ "$warning"  -gt 0 ] && printf '  "WARNING" : %s\n'  "$warning"
  [ "$healthy"  -gt 0 ] && printf '  "HEALTHY" : %s\n'  "$healthy"
  printf '```\n'
}

# generate_mermaid_bar <metrics_file>
# Prints a Mermaid xychart-beta bar chart for the top 10 failing workflows
# with at least 5 runs (excludes low-confidence single-run entries).
generate_mermaid_bar() {
  local f="$1"
  local min_runs=5
  local top10
  top10=$(awk -F'\t' -v min="$min_runs" '
    $11 != "HEALTHY" && $11 != "—" && $6 > 0 && $4 + 0 >= min {
      rate = $12 + 0
      # Strip org prefix for label brevity
      label = $2 "/" $3
      sub(/^[^/]+\//, "", label)
      printf "%s\t%s\n", rate, label
    }
  ' "$f" | sort -t$'\t' -k1,1rn | head -10)

  if [ -z "$top10" ]; then
    return
  fi

  local labels="" values=""
  while IFS=$'\t' read -r rate label; do
    labels="${labels}\"${label}\","
    values="${values}${rate},"
  done <<< "$top10"
  labels="${labels%,}"
  values="${values%,}"

  printf '```mermaid\n'
  printf 'xychart-beta\n'
  printf '  title "Top Failing Workflows (≥%s runs)"\n' "$min_runs"
  printf '  x-axis [%s]\n' "$labels"
  printf '  y-axis "Failure Rate %%" 0 --> 100\n'
  printf '  bar [%s]\n' "$values"
  printf '```\n'
}

# generate_report <metrics_file> <failed_file> <with_mermaid> [issues_file]
# Generates the complete fleet report. with_mermaid="true" includes Mermaid
# charts (suitable for GitHub Issues); "false" omits them (for Step Summary).
generate_report() {
  local metrics_file="$1"
  local failed_file="$2"
  local with_mermaid="${3:-false}"
  local issues_file="${4:-}"

  # Apply confidence filter and sort by severity
  local filtered
  filtered=$(mktemp)
  apply_confidence_filter < "$metrics_file" | sort -t$'\t' -k1,1n > "$filtered"

  # --- Scorecard ---
  printf '## Fleet Health\n\n'
  generate_scorecard "$filtered"
  printf '\n'

  # --- Mermaid pie (Issues only) ---
  if [ "$with_mermaid" = "true" ]; then
    generate_mermaid_pie "$filtered"
    printf '\n'
  fi

  # --- Systemic failures ---
  local systemic
  systemic=$(detect_systemic_failures "$filtered")
  if [ -n "$systemic" ]; then
    printf '## ⚠️ Systemic Issues\n\n'
    printf 'These workflow files are failing across multiple repos — fix the shared definition:\n\n'
    while IFS= read -r wf; do
      local count
      count=$(awk -F'\t' -v w="$wf" '$3 == w && $6 > 0' "$filtered" | wc -l | tr -d ' ')
      printf -- '- `%s` — failing in **%s** repos\n' "$wf" "$count"
    done <<< "$systemic"
    printf '\n'
  fi

  # --- Mermaid bar (Issues only) ---
  if [ "$with_mermaid" = "true" ]; then
    printf '## Top Failing Workflows\n\n'
    generate_mermaid_bar "$filtered"
    printf '\n'
  fi

  # --- Per-repo rollup ---
  printf '## Per-Repo Summary\n\n'
  generate_repo_rollup "$filtered" "$issues_file"
  printf '\n'

  # --- Fleet detail table ---
  printf '## Fleet Detail\n\n'
  printf '| Repo | Workflow | Issues | Total | ✅ | ❌ | ⚪ | Failure Rate | | p50 | p95 | Status |\n'
  printf '|---|---|---|---|---|---|---|---|---|---|---|---|\n'

  while IFS=$'\t' read -r _key repo wf_file total success failed cancelled \
                              rate_display p50 p95 label rate_int; do
    [ "$total" = "0" ] && continue
    local bar vflag icon issues_link
    bar=$(generate_ascii_bar "$rate_int")
    vflag=$(flag_duration_variance "$p50" "$p95")
    icon=$(label_to_icon "$label")
    issues_link=" "
    if [ -n "$issues_file" ] && [ -f "$issues_file" ] && [ -s "$issues_file" ]; then
      issues_link=$(awk -F'\t' -v r="$repo" -v w="$wf_file" \
        '$1 == r && $2 == w { printf "[#%s](%s)", $4, $3; exit }' "$issues_file")
    fi
    [ -z "$issues_link" ] && issues_link=" "
    printf '| `%s` %s | `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s%s | %s %s |\n' \
      "$repo" "$icon" "$wf_file" "$issues_link" "$total" "$success" "$failed" "$cancelled" \
      "$rate_display" "$bar" \
      "$(fmt_dur "$p50")" "$(fmt_dur "$p95")" "$vflag" "$icon" "$label"
  done < "$filtered"

  # --- Failed runs ---
  if [ -s "$failed_file" ]; then
    printf '\n## Failed Runs\n'
    cat "$failed_file"
  fi

  rm -f "$filtered"
}
