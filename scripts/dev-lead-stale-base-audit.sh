#!/usr/bin/env bash
set -euo pipefail
# dev-lead-stale-base-audit.sh — bounded, READ-ONLY audit for the #1607
# stale-base defect across dev-lead's open PRs.
#
# The #1604 incident (a maintainer steering commit discarded by a stale-base
# force-push) leaves a fingerprint on the branch: the discarded commit and the
# commit that replaced it share the SAME parent. This wrapper enumerates the
# PRs dev-lead touches and, for each, pulls the branch's commit graph and checks
# it for that fingerprint via detect_stale_base_siblings. It never writes to any
# branch, PR, or ref — it only reports, so an operator can inspect flagged PRs.
#
# Usage:
#   scripts/dev-lead-stale-base-audit.sh                 # audit every open PR
#   scripts/dev-lead-stale-base-audit.sh owner/repo 123  # audit one PR
#
# Env: REPO / PR_NUMBER may substitute for positional args. BOT_USER / TARGET_ORG
# scope the full sweep (same defaults as list-prs.sh).
#
# Exit status: 0 when no fingerprint is found in any audited PR; 1 when at least
# one PR shows the stale-base sibling fingerprint (for CI gating / alerting).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stale-base-siblings.sh"

# audit_one REPO PR — fetch the PR's commit graph and check it for the
# stale-base fingerprint. Prints a per-PR verdict; returns 1 if flagged.
audit_one() {
  local repo="$1" pr="$2"
  # `%H %P` — commit and its parent(s); detect_stale_base_siblings reads the
  # commit + its first parent from each line. The GitHub commits endpoint lists
  # the PR's commits with their parents in topological order.
  local graph
  graph=$(gh api --paginate "repos/${repo}/pulls/${pr}/commits" \
    --jq '.[] | .sha + " " + ((.parents // []) | map(.sha) | join(" "))' 2>/dev/null || true)
  if [ -z "$graph" ]; then
    echo "  [audit] ${repo}#${pr}: no commits returned — skipping"
    return 0
  fi
  local report
  if report=$(printf '%s\n' "$graph" | detect_stale_base_siblings); then
    echo "  [audit] ${repo}#${pr}: clean"
    return 0
  fi
  echo "::warning::stale-base fingerprint on ${repo}#${pr} — a discarded commit and its replacement share a parent (possible lost steering commit, #1607):"
  printf '%s\n' "$report"
  return 1
}

main() {
  local repo="${1:-${REPO:-}}" pr="${2:-${PR_NUMBER:-}}"
  local fail=0

  if [ -n "$repo" ] && [ -n "$pr" ]; then
    audit_one "$repo" "$pr" || fail=1
    return "$fail"
  fi

  # Full sweep: reuse list-prs.sh to enumerate the open PR queue, then audit each.
  local list_prs
  list_prs="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/list-prs.sh"
  local url
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    # url form: https://github.com/<owner>/<repo>/pull/<n>
    local slug num
    slug=$(printf '%s' "$url" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/[0-9]+#\1#')
    num=$(printf '%s' "$url" | sed -E 's#.*/pull/([0-9]+)$#\1#')
    [ -n "$slug" ] && [ -n "$num" ] || continue
    audit_one "$slug" "$num" || fail=1
  done < <(bash "$list_prs" 2>/dev/null || true)

  return "$fail"
}

main "$@"
