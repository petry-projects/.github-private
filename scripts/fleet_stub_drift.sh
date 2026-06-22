#!/usr/bin/env bash
# fleet_stub_drift.sh — initiative-planner stub coverage & drift detection for
# the Actions Fleet Monitor (#822, AC#2 + AC#3). Sourced by fleet_monitor.sh.
#
# The initiative-planner is adopted by fleet repos via a per-repo thin-caller
# stub at .github/workflows/initiative-planner.yml (#820), deployed verbatim
# from the canonical org template standards/workflows/initiative-planner.yml.
# This module compares each enrolled repo's stub blob SHA against the canonical
# template SHA and classifies coverage so the monitor can alert on drift — the
# silent-revert class of failure #822 exists to catch (cf. #655).
#
# All functions are PURE: they take a canonical SHA + a per-repo stub blob SHA
# (or a drift TSV) and write to stdout. No network. The blob SHAs are the values
# GitHub's contents API returns in `.sha` (git blob object IDs), so equal SHAs
# mean byte-identical files. Network fetching lives in fleet_monitor.sh.
#
# Drift TSV format (4 fields, tab-separated):
#   1:repo  2:status  3:repo_sha  4:canonical_sha
# status ∈ { ALIGNED, DRIFTED, MISSING }
#   ALIGNED — stub present and byte-identical to the canonical template
#   DRIFTED — stub present but its blob SHA differs (the alertable set)
#   MISSING — no stub in the repo (not enrolled) — informational, not alerted

# classify_stub_drift <canonical_sha> <repo_sha>
# Classifies one repo's stub against the canonical template SHA.
classify_stub_drift() {
  local canonical="${1:-}" repo_sha="${2:-}"
  if [ -z "$repo_sha" ] || [ "$repo_sha" = "null" ]; then
    echo "MISSING"
  elif [ "$repo_sha" = "$canonical" ]; then
    echo "ALIGNED"
  else
    echo "DRIFTED"
  fi
}

# stub_drift_row <repo> <canonical_sha> <repo_sha>
# Emits one classified TSV row: repo<TAB>status<TAB>repo_sha<TAB>canonical_sha.
stub_drift_row() {
  local repo="${1:-}" canonical="${2:-}" repo_sha="${3:-}"
  local status
  status="$(classify_stub_drift "$canonical" "$repo_sha")"
  printf '%s\t%s\t%s\t%s\n' "$repo" "$status" "$repo_sha" "$canonical"
}

# count_stub_drift <tsv_file> <status>
# Counts rows whose status column (field 2) equals <status>. 0 if file absent.
count_stub_drift() {
  local f="${1:-}" want="${2:-}"
  [ -n "$f" ] && [ -f "$f" ] || { echo 0; return 0; }
  awk -F'\t' -v w="$want" '$2 == w { n++ } END { print n + 0 }' "$f"
}

# stub_drift_alert_json <tsv_file> [stub_label] [stub_file]
# Emits a JSON array of the DRIFTED rows (the alertable set — enrolled repos
# whose stub no longer matches canon). Empty/absent file → "[]".
# When <stub_label>/<stub_file> are given, each row is tagged with `stub` and
# `stub_file` so a multi-stub alert step can group/route per stub kind.
stub_drift_alert_json() {
  local f="${1:-}" stub_label="${2:-}" stub_file="${3:-}"
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    echo "[]"
    return 0
  fi
  jq -Rn --arg stub "$stub_label" --arg stub_file "$stub_file" '
    [ inputs
      | select(length > 0)
      | split("\t")
      | select(length >= 4 and .[1] == "DRIFTED")
      | { repo: .[0], status: .[1], repo_sha: .[2], canonical_sha: .[3] }
      | if $stub != "" then . + { stub: $stub } else . end
      | if $stub_file != "" then . + { stub_file: $stub_file } else . end
    ]' < "$f"
}

# generate_stub_drift_report <tsv_file> <canonical_sha> [stub_label]
# Prints a Markdown section: coverage counts plus a table of every non-ALIGNED
# repo. Pure: reads the TSV, writes stdout. <stub_label> headlines the section
# (default "Initiative-planner" preserves the #822 single-stub heading).
generate_stub_drift_report() {
  local f="${1:-}" canonical="${2:-}" stub_label="${3:-Initiative-planner}"
  local short_canon="${canonical:0:7}"
  local aligned drifted missing total
  aligned="$(count_stub_drift "$f" "ALIGNED")"
  drifted="$(count_stub_drift "$f" "DRIFTED")"
  missing="$(count_stub_drift "$f" "MISSING")"
  total=$(( aligned + drifted ))  # enrolled = repos that have the stub

  printf '## %s stub coverage & drift\n\n' "$stub_label"
  printf 'Canonical template SHA: `%s` · enrolled repos (stub present): **%s**\n\n' \
    "$short_canon" "$total"
  printf '✅ ALIGNED: %s  🔴 DRIFTED: %s  ⬜ MISSING (not enrolled): %s\n\n' \
    "$aligned" "$drifted" "$missing"

  if [ "$drifted" -eq 0 ]; then
    printf '_No stub drift detected — every enrolled repo matches the canonical template._\n'
    return 0
  fi

  printf 'These enrolled repos have drifted from the canonical stub — re-sync them:\n\n'
  printf '| Repo | Status | Stub SHA | Canonical SHA |\n'
  printf '|---|---|---|---|\n'
  awk -F'\t' '$2 == "DRIFTED" {
    printf "| `%s` | 🔴 %s | `%s` | `%s` |\n", $1, $2, substr($3,1,7), substr($4,1,7)
  }' "$f"
}
