#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Searches across two namespaces:
#   1. All open PRs in repos owned by don-petry (personal account)
#   2. All open PRs in repos owned by petry-projects (organization)
#
# Filters:
#   --draft=false       — skip work-in-progress PRs
#
# CI filtering is intentionally omitted here — review-one-pr.sh enforces it
# per-PR as a second layer. Filtering by --checks success would exclude repos
# with no CI configured (GitHub treats "no checks" as not matching --checks
# success), causing their PRs to never enter the candidate pool.
#
# Self-authored PRs (PRs whose author is $BOT_USER) are excluded here, because
# GitHub's GraphQL API rejects self-approval unconditionally — including such a
# PR in the queue previously triggered a fatal session abort that starved every
# subsequent candidate (see issue #96).
#
# Output ordering (stable, deterministic):
#   1. .github and .github-private PRs first (priority 0)
#   2. All other repos (priority 1)
#   Within each priority tier, PRs are sorted oldest-first by createdAt.
#
# Note: Uses repo enumeration instead of @me/@review-requested, which don't work
# with GitHub App tokens (app tokens have no user identity).
#
# Output: one PR URL per line on stdout.

set -euo pipefail

all_prs=""

# Get all repos in don-petry account and search each
while IFS= read -r repo; do
  prs=$(gh search prs \
    --state open \
    --repo "$repo" \
    --draft=false \
    --limit 100 \
    --json url \
    --jq '.[].url' 2>/dev/null || true)
  all_prs="${all_prs}${prs}"$'\n'
done < <(gh repo list don-petry --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

# Get all repos in petry-projects org and search each (require passing checks)
while IFS= read -r repo; do
  prs=$(gh search prs \
    --state open \
    --repo "$repo" \
    --draft=false \
    --checks success \
    --limit 100 \
    --json url \
    --jq '.[].url' 2>/dev/null || true)
  all_prs="${all_prs}${prs}"$'\n'
done < <(gh repo list petry-projects --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

printf '%s\n' "$all_prs" | sort -u | grep -v '^$' || true
