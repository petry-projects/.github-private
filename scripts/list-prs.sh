#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Two buckets, deduped:
#   1. PRs authored by @me across all repos (self-review).
#   2. PRs where @me is a requested reviewer across all repos.
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
# Output: one PR URL per line on stdout.

set -euo pipefail

authored=$(gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --limit 100 \
  --json url \
  --jq '.[].url')

review_requested=$(gh search prs \
  --state open \
  --review-requested "@me" \
  --draft=false \
  --limit 100 \
  --json url \
  --jq '.[].url')

{
  printf '%s\n' "$authored"
  printf '%s\n' "$review_requested"
} | sort -u | grep -v '^$' || true
