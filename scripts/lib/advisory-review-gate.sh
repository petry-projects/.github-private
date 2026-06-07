#!/usr/bin/env bash
# Advisory Bot Review Gate
#
# Instant check (non-blocking) for advisory bot reviews.
# Instead of polling for 60 minutes, this script checks the current state
# of bot reviews and returns immediately. The pr-review workflow will be
# re-triggered when bots submit their reviews (pull_request_review event).
#
# This design avoids GitHub Actions billing for long-running workflow blocks.
# Cost: $0.008/min × 1-2 min checks vs. $0.008/min × 60 min blocks
#
# This gate ensures valid code reviews are incorporated before approval, addressing:
# - Issue #457: Advisory bots finishing after pr-review approval
# - PR #453 incident: Copilot review arriving 43 seconds too late
#
# Usage:
#   check_advisory_reviews "$PR_URL"
#
# Returns:
#   0 = All detected advisory bots have submitted (ready to approve)
#   1 = Waiting for bots (defer approval, will re-check on next bot review)
#
# Environment:
#   GH_TOKEN (set by calling workflow)
#   PR_URL (passed as argument)

set -euo pipefail

# Define advisory bots we monitor
# Ordered by typical response time (fastest first)
# shellcheck disable=SC2034
declare -A ADVISORY_BOTS=(
  [gemini-code-assist]="Gemini Code Assist (advisory)"
  [copilot-pull-request-reviewer]="Copilot PR Reviewer (advisory)"
  [sonarqubecloud]="SonarCloud (advisory)"
  [chatgpt-codex-connector]="Codex (advisory, newer bot)"
)

# Color codes for output
# shellcheck disable=SC2034
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info() {
  echo "[advisory-gate] $*" >&2
}

log_warn() {
  echo -e "${YELLOW}[advisory-gate] WARNING: $*${NC}" >&2
}

log_success() {
  echo -e "${GREEN}[advisory-gate] $*${NC}" >&2
}

# Query which advisory bots have reviewed/commented on this PR
get_advisory_bot_states() {
  # Build JSON array of bot names from ADVISORY_BOTS keys — single source of truth
  local bot_array
  bot_array=$(printf '%s\n' "${!ADVISORY_BOTS[@]}" | jq -R . | jq -s .)

  local gh_output
  gh_output=$(gh pr view "$PR_URL" --json reviews,comments 2>&1) || {
    log_warn "gh pr view failed: $gh_output"
    return 1
  }

  echo "$gh_output" | jq -c --argjson bots "$bot_array" '
    # Collect all bot submissions with their state
    (
      [(.reviews // [])[] | select([.author.login] | inside($bots)) | {bot: .author.login, state: .state, time: .submittedAt}] +
      [(.comments // [])[] | select([.author.login] | inside($bots)) | {bot: .author.login, state: "COMMENTED", time: .createdAt}]
    ) |
    # Group by bot, sort by time within each group, keep latest submission per bot
    group_by(.bot) |
    map(sort_by(.time) | last | {bot: .bot, state: .state, time: .time}) |
    sort_by(.bot) |
    .[]
  ' || {
    log_warn "jq processing failed"
    return 1
  }
}

# Format bot states for display
format_bot_status() {
  local bot="$1" state="$2"
  case "$state" in
    APPROVED) echo "✓ ${bot} → APPROVED" ;;
    COMMENTED) echo "✓ ${bot} → COMMENTED (advisory)" ;;
    CHANGES_REQUESTED) echo "⚠ ${bot} → CHANGES_REQUESTED" ;;
    DISMISSED) echo "✓ ${bot} → DISMISSED (no issues)" ;;
    UNSUPPORTED) echo "⊘ ${bot} → UNSUPPORTED (file type)" ;;
    RATE_LIMITED) echo "✗ ${bot} → RATE_LIMITED" ;;
    *) echo "? ${bot} → ${state}" ;;
  esac
}

# Instant (non-blocking) check of advisory bot status
#
# DESIGN: This uses a re-trigger pattern instead of blocking waits:
# 1. On first pr-review trigger (check_suite completion): instant check
# 2. If return 0: bots ready → approve immediately
# 3. If return 1: bots not ready → skip (exit 100)
# 4. When bots submit: pull_request_review event fires
# 5. pr-review re-triggered → this check returns 0 → approve
#
# Returns:
#   0 = All detected participating bots have submitted (ready to approve)
#   1 = Waiting for bots (skip, will re-check on next review event)
#
check_advisory_reviews() {
  local pr_url="${1:-}"
  if [ -z "$pr_url" ]; then
    echo "[advisory-gate] Usage: check_advisory_reviews <pr_url>" >&2
    return 1
  fi
  export PR_URL="$pr_url"

  local pr_num
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "unknown")

  log_info "Checking advisory bot review status for PR #${pr_num} (instant check, no polling)"

  # Get current bot states (single gh API call, instant)
  local current_states
  current_states=$(get_advisory_bot_states) || {
    log_warn "Failed to query advisory bot states"
    return 1
  }

  if [ -z "$current_states" ]; then
    log_warn "No advisory bot reviews detected yet"
    log_warn "Will re-check when bots submit their reviews (pull_request_review event)"
    return 1  # Still waiting for bots
  fi

  # Extract participating bots (those who have submitted)
  local participating_bots num_submitted total_advisory_bots
  participating_bots=$(echo "$current_states" | jq -rs '[.[].bot] | unique | join(" ")')
  num_submitted=$(echo "$current_states" | jq -rs '[.[].bot] | unique | length')
  total_advisory_bots=${#ADVISORY_BOTS[@]}

  log_info "Advisory bots detected: $participating_bots"
  while IFS= read -r line; do
    local bot state
    bot=$(echo "$line" | jq -r '.bot')
    state=$(echo "$line" | jq -r '.state')
    log_info "  $(format_bot_status "$bot" "$state")"
  done <<< "$current_states"

  # Require all known advisory bots to submit before approving.
  # Two timeout fallbacks handle absent bots (e.g. Codex only reviews a subset of PRs):
  #   1. Head-push age > 20 min: use latest commit time, not PR creation time, so a new
  #      commit on an old PR doesn't immediately bypass the gate (thread PRRT_..ofWG).
  #   2. Quiescence > 10 min: if no new submissions have arrived in 10 min, assume the
  #      remaining bots won't participate — prevents indefinite stranding when there is
  #      no scheduled retry event to re-enter this branch (thread PRRT_..ofWI).
  if [ "$num_submitted" -lt "$total_advisory_bots" ]; then
    local now head_time head_time_raw head_age_sec latest_sub_at latest_sub_raw time_since_last_sub
    now=$(date -u +%s)

    head_age_sec=0
    # Use pushedDate (when the commit arrived on GitHub) not committedDate (author
    # timestamp) so that old cherry-picked commits don't bypass the gate immediately.
    # $url in the query string is a GraphQL variable, not a shell variable.
    # shellcheck disable=SC2016
    local _gql='query($url:URI!){resource(url:$url){...on PullRequest{commits(last:1){nodes{commit{pushedDate committedDate}}}}}}'
    head_time=$(gh api graphql -f query="$_gql" -f url="$PR_URL" \
      --jq '.data.resource.commits.nodes[0].commit | .pushedDate // .committedDate' \
      2>/dev/null) || head_time=""
    if [ -n "$head_time" ]; then
      head_time_raw=$(date -u -d "$head_time" +%s 2>/dev/null) || head_time_raw=""
      [ -n "$head_time_raw" ] && head_age_sec=$((now - head_time_raw))
    fi

    time_since_last_sub=0
    latest_sub_at=$(echo "$current_states" | jq -rs '[.[].time] | sort | last' 2>/dev/null) || latest_sub_at=""
    if [ -n "$latest_sub_at" ]; then
      latest_sub_raw=$(date -u -d "$latest_sub_at" +%s 2>/dev/null) || latest_sub_raw=""
      if [ -n "$latest_sub_raw" ]; then
        # Anchor quiescence to the later of head-push and latest submission so that
        # stale submissions from a previous HEAD don't satisfy the fallback for a
        # fresh commit (a new push resets the quiescence timer to the head-push time).
        local quiescence_anchor
        if [ -n "$head_time_raw" ] && [ "$head_time_raw" -gt "$latest_sub_raw" ]; then
          quiescence_anchor=$head_time_raw
        else
          quiescence_anchor=$latest_sub_raw
        fi
        time_since_last_sub=$((now - quiescence_anchor))
      fi
    fi

    if [ "$head_age_sec" -gt 1200 ]; then
      log_info "Only ${num_submitted}/${total_advisory_bots} bots submitted; head is ${head_age_sec}s old — timeout fallback, proceeding"
    elif [ "$time_since_last_sub" -gt 600 ]; then
      log_info "Only ${num_submitted}/${total_advisory_bots} bots submitted; no new submissions in ${time_since_last_sub}s — assuming absent bots won't participate, proceeding"
    else
      log_warn "Only ${num_submitted}/${total_advisory_bots} advisory bots submitted so far (head age: ${head_age_sec}s, last submission: ${time_since_last_sub}s ago)"
      log_warn "Will re-check when remaining bots submit their reviews"
      return 1
    fi
  fi

  log_success "All detected advisory bots have submitted ✓"
  return 0  # Ready to approve
}

# Run the check (only if not being sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if check_advisory_reviews "${1:-}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [ $exit_code -eq 0 ]; then
    log_success "Advisory bot review gate check PASSED ✓"
  elif [ $exit_code -eq 1 ]; then
    log_warn "Advisory bots still reviewing - will check again on next review submission"
  fi

  exit $exit_code
fi
