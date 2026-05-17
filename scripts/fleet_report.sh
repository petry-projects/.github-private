#!/usr/bin/env bash
# fleet_report.sh — visualization and report generation for the Actions Fleet Monitor.
# Sourced by fleet_monitor.sh. All functions are pure (accept args / stdin; write stdout).
#
# Metrics TSV format (12 fields, tab-separated):
#   1:sort_key  2:repo  3:wf_file  4:total  5:success  6:failed
#   7:cancelled  8:rate_display  9:p50(s)  10:p95(s)  11:label  12:rate_int

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

# generate_repo_rollup <metrics_file>
# Prints a markdown table with one row per repo: workflow count, total runs,
# total failures, and worst status label.
generate_repo_rollup() {
  local f="$1"
  printf '| Repo | Workflows | Total Runs | Failures | Worst Status |\n'
  printf '|---|---|---|---|---|\n'
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
      printf "| `%s` | %s | %s | %s | %s |\n",
        repo, wf_ct[repo], runs[repo], failed[repo], best_label[repo]
  }' "$f" | sort -t'|' -k2
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

# generate_report <metrics_file> <failed_file> <with_mermaid>
# Generates the complete fleet report. with_mermaid="true" includes Mermaid
# charts (suitable for GitHub Issues); "false" omits them (for Step Summary).
generate_report() {
  local metrics_file="$1"
  local failed_file="$2"
  local with_mermaid="${3:-false}"

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
  generate_repo_rollup "$filtered"
  printf '\n'

  # --- Fleet detail table ---
  printf '## Fleet Detail\n\n'
  printf '| Repo | Workflow | Total | ✅ | ❌ | ⚪ | Failure Rate | | p50 | p95 | Status |\n'
  printf '|---|---|---|---|---|---|---|---|---|---|---|\n'

  while IFS=$'\t' read -r _key repo wf_file total success failed cancelled \
                              rate_display p50 p95 label rate_int; do
    local bar vflag
    bar=$(generate_ascii_bar "$rate_int")
    vflag=$(flag_duration_variance "$p50" "$p95")
    printf '| `%s` | `%s` | %s | %s | %s | %s | %s | %s | %s | %s%s | %s |\n' \
      "$repo" "$wf_file" "$total" "$success" "$failed" "$cancelled" \
      "$rate_display" "$bar" \
      "$(fmt_dur "$p50")" "$(fmt_dur "$p95")" "$vflag" "$label"
  done < "$filtered"

  # --- Failed runs ---
  if [ -s "$failed_file" ]; then
    printf '\n## Failed Runs\n'
    cat "$failed_file"
  fi

  rm -f "$filtered"
}
