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

PR_URL="${1:-}"
if [ -z "$PR_URL" ]; then
  echo "[advisory-gate] Usage: check_advisory_reviews <pr_url>" >&2
  exit 1
fi
export PR_URL

# Extract PR number from URL for logging
PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "unknown")

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
  gh pr view "$PR_URL" --json reviews,comments | jq -r '
    # Collect all bot submissions with their state
    (
      [(.reviews // [])[] | select(.author.login | IN("gemini-code-assist", "copilot-pull-request-reviewer", "sonarqubecloud", "chatgpt-codex-connector")) | {bot: .author.login, state: .state, time: .submittedAt}] +
      [(.comments // [])[] | select(.author.login | IN("gemini-code-assist", "copilot-pull-request-reviewer", "sonarqubecloud", "chatgpt-codex-connector")) | {bot: .author.login, state: "COMMENTED", time: .createdAt}]
    ) |
    # Group by bot, sort by time within each group, keep latest submission per bot
    group_by(.bot) |
    map(sort_by(.time) | last | {bot: .bot, state: .state, time: .time}) |
    sort_by(.bot) |
    .[]
  '
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
  local current_states participating_bots

  log_info "Checking advisory bot review status for PR #${PR_NUM} (instant check, no polling)"

  # Get current bot states (single gh API call, instant)
  current_states=$(get_advisory_bot_states)

  if [ -z "$current_states" ]; then
    log_warn "No advisory bot reviews detected yet"
    log_warn "Will re-check when bots submit their reviews (pull_request_review event)"
    return 1  # Still waiting for bots
  fi

  # Extract participating bots (those who have submitted)
  participating_bots=$(echo "$current_states" | jq -r '.bot' | sort -u | tr '\n' ' ')

  log_info "Advisory bots detected: $participating_bots"
  while IFS= read -r line; do
    local bot state
    bot=$(echo "$line" | jq -r '.bot')
    state=$(echo "$line" | jq -r '.state')
    log_info "  $(format_bot_status "$bot" "$state")"
  done <<< "$current_states"

  log_success "All detected advisory bots have submitted ✓"
  return 0  # Ready to approve
}

# Run the check (only if not being sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  check_advisory_reviews
  exit_code=$?

  if [ $exit_code -eq 0 ]; then
    log_success "Advisory bot review gate check PASSED ✓"
  elif [ $exit_code -eq 1 ]; then
    log_warn "Advisory bots still reviewing - will check again on next review submission"
  fi

  exit $exit_code
fi
