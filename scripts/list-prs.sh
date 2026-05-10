#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Searches across two namespaces:
#   1. All open PRs in repos owned by $BOT_USER (the bot's personal account)
#   2. All open PRs in repos owned by $TARGET_ORG (organization)
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
# Self-authored PRs (PRs whose author is $BOT_USER) are excluded here, because
# GitHub's GraphQL API rejects self-approval unconditionally — including such a
# PR in the queue previously triggered a fatal session abort that starved every
# subsequent candidate (see issue #96).
#
# Output: one PR URL per line on stdout.

set -euo pipefail

# Configurable via environment / repo variables. BOT_USER is the GitHub
# identity the workflow PAT authenticates as — both the queue scope (which
# repos to scan) and the self-approval filter use it.
BOT_USER="${BOT_USER:-don-petry-bot}"
TARGET_ORG="${TARGET_ORG:-petry-projects}"

# Reject BOT_USER values that aren't valid GitHub usernames before
# interpolating into a jq program. GitHub usernames are 1–39 chars of
# [A-Za-z0-9-] and may not start or end with a hyphen. Anything else is
# either a misconfiguration or an injection attempt — fail loud rather
# than silently dropping PRs.
if ! [[ "$BOT_USER" =~ ^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$ ]]; then
  echo "::error::BOT_USER='$BOT_USER' is not a valid GitHub username" >&2
  exit 1
fi

all_prs=""

JQ_NOT_SELF=".[] | select(.author.login != \"$BOT_USER\") | .url"

# Get all repos in bot's personal account and search each
while IFS= read -r repo; do
  prs=$(gh search prs \
    --state open \
    --repo "$repo" \
    --draft=false \
    --limit 100 \
    --json url,author \
    --jq "$JQ_NOT_SELF" 2>/dev/null || true)
  all_prs="${all_prs}${prs}"$'\n'
done < <(gh repo list "$BOT_USER" --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

# Get all repos in org and search each (require passing checks)
while IFS= read -r repo; do
  prs=$(gh search prs \
    --state open \
    --repo "$repo" \
    --draft=false \
    --checks success \
    --limit 100 \
    --json url,author \
    --jq "$JQ_NOT_SELF" 2>/dev/null || true)
  all_prs="${all_prs}${prs}"$'\n'
done < <(gh repo list "$TARGET_ORG" --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

printf '%s\n' "$all_prs" | sort -u | grep -v '^$' || true
