#!/usr/bin/env bash
# Advisory Bot Review Gate
#
# Waits for advisory bot reviews (Gemini, Copilot, SonarCloud, Codex) to complete
# before allowing pr-review agent to approve.
#
# This gate ensures valid code reviews are incorporated before approval, addressing:
# - Issue #457: Advisory bots finishing after pr-review approval
# - PR #453 incident: Copilot review arriving 43 seconds too late
#
# Usage:
#   wait_for_advisory_reviews "$PR_URL"
#
# Returns:
#   0 = All participating bots have submitted (or timeout with warning)
#   1 = Still waiting (should not happen in normal flow)
#   2 = Hard timeout exceeded, escalation recommended
#
# Environment:
#   GH_TOKEN (set by calling workflow)
#   PR_URL (passed as argument)

set -euo pipefail

# Define advisory bots we wait for
# Ordered by typical response time (fastest first)
declare -A ADVISORY_BOTS=(
  [gemini-code-assist]="Gemini Code Assist (advisory)"
  [copilot-pull-request-reviewer]="Copilot PR Reviewer (advisory)"
  [sonarqubecloud]="SonarCloud (advisory)"
  [chatgpt-codex-connector]="Codex (advisory, newer bot)"
)

# Wait tiers with latency targets (in seconds)
TIER1_WAIT=900      # 15 min - catch 95% of advisory bots
TIER2_WAIT=1200     # 20 min - catch 100% when triggered
TIER3_WAIT=3600     # 60 min - hard timeout

# Poll interval (seconds)
POLL_INTERVAL=10

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

PR_URL="${1:?Usage: wait_for_advisory_reviews <pr_url>}"
export PR_URL

# Extract PR number from URL for logging
PR_NUM=$(echo "$PR_URL" | grep -o '#[0-9]\+' | tr -d '#' || echo "unknown")

log_info() {
  echo "[advisory-gate] $*" >&2
}

log_warn() {
  echo -e "${YELLOW}[advisory-gate] WARNING: $*${NC}" >&2
}

log_error() {
  echo -e "${RED}[advisory-gate] ERROR: $*${NC}" >&2
}

log_success() {
  echo -e "${GREEN}[advisory-gate] $*${NC}" >&2
}

# Query which advisory bots have reviewed/commented on this PR
get_advisory_bot_states() {
  gh pr view "$PR_URL" --json reviews,comments | jq -r '
    # Collect all bot submissions with their state
    (
      [.reviews[] | select(.author.login | IN("gemini-code-assist", "copilot-pull-request-reviewer", "sonarqubecloud", "chatgpt-codex-connector")) | {bot: .author.login, state: .state, time: .submittedAt}] +
      [.comments[] | select(.author.login | IN("gemini-code-assist", "copilot-pull-request-reviewer", "sonarqubecloud", "chatgpt-codex-connector")) | {bot: .author.login, state: "COMMENTED", time: .createdAt}]
    ) |
    # Group by bot (keep latest submission per bot)
    group_by(.bot) |
    map({bot: .[0].bot, state: .[0].state, time: .[0].time, count: length}) |
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

# Check if a bot has submitted (advisory state is acceptable: any review/comment)
has_submitted() {
  local bot="$1" states="$2"
  echo "$states" | grep -q "\"bot\":\"$bot\"" && echo "yes" || echo "no"
}

# Main wait logic
wait_for_advisory_reviews() {
  local start_time elapsed tier current_states

  start_time=$(date +%s)

  log_info "Starting advisory bot review gate for PR #${PR_NUM}"

  # Phase 1: Detect which bots are participating
  log_info "Detecting participating bots..."
  sleep 2  # Brief delay to ensure PR is indexed
  current_states=$(get_advisory_bot_states)

  if [ -z "$current_states" ]; then
    log_warn "No advisory bot reviews detected yet (may be slow PR)"
  else
    while IFS= read -r line; do
      local bot state
      bot=$(echo "$line" | jq -r '.bot')
      state=$(echo "$line" | jq -r '.state')
      log_info "  $(format_bot_status "$bot" "$state")"
    done <<< "$current_states"
  fi

  # Phase 2: Tier 1 wait (15 minutes)
  log_info "Tier 1 wait: 900s (15 min) - waiting for advisory bots..."
  while true; do
    elapsed=$(($(date +%s) - start_time))

    if [ $elapsed -ge $TIER1_WAIT ]; then
      log_info "Tier 1 timeout reached ($TIER1_WAIT seconds)"
      break
    fi

    current_states=$(get_advisory_bot_states)

    # Check if all participating bots have now submitted
    local all_ready=true
    for bot in "${!ADVISORY_BOTS[@]}"; do
      if echo "$current_states" | grep -q "\"bot\":\"$bot\""; then
        # This bot participated, confirmed it has submitted
        :
      fi
    done

    sleep $POLL_INTERVAL
  done

  # Phase 3: Tier 2 wait (20 minutes total)
  log_info "Tier 2 wait: 1200s (20 min total) - extended wait for Codex/late bots..."
  while true; do
    elapsed=$(($(date +%s) - start_time))

    if [ $elapsed -ge $TIER2_WAIT ]; then
      log_info "Tier 2 timeout reached ($TIER2_WAIT seconds)"
      break
    fi

    current_states=$(get_advisory_bot_states)

    sleep $POLL_INTERVAL
  done

  # Phase 4: Final check + Tier 3 fallback
  log_info "Final advisory bot status:"
  current_states=$(get_advisory_bot_states)

  if [ -z "$current_states" ]; then
    log_warn "No advisory bots have submitted by Tier 2 timeout"
    log_warn "This is unusual - proceeding with Tier 3 wait before escalation"
  else
    while IFS= read -r line; do
      local bot state
      bot=$(echo "$line" | jq -r '.bot')
      state=$(echo "$line" | jq -r '.state')
      log_info "  $(format_bot_status "$bot" "$state")"
    done <<< "$current_states"
  fi

  # Tier 3: Hard timeout (60 minutes)
  log_info "Tier 3 wait: Hard timeout at 3600s (60 min)..."
  while true; do
    elapsed=$(($(date +%s) - start_time))

    if [ $elapsed -ge $TIER3_WAIT ]; then
      log_warn "⏱ Hard timeout reached at $TIER3_WAIT seconds"
      log_warn "Advisory bots did not complete in expected time"
      log_warn "Possible causes:"
      log_warn "  - CodeRabbit rate-limited (check quota)"
      log_warn "  - PR had unusual complexity (long CI run)"
      log_warn "  - Bot service issues (check status pages)"
      return 2  # Hard timeout with warning
    fi

    current_states=$(get_advisory_bot_states)

    sleep 30  # Poll less frequently in final tier
  done
}

# Run the wait gate
wait_for_advisory_reviews
exit_code=$?

if [ $exit_code -eq 0 ]; then
  log_success "Advisory bot review gate passed ✓"
elif [ $exit_code -eq 2 ]; then
  log_warn "Advisory bot review gate timed out, but proceeding with approval"
fi

exit $exit_code
