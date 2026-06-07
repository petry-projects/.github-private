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
# shellcheck disable=SC2034
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

PR_URL="${1:-}"
if [ -z "$PR_URL" ]; then
  echo "[advisory-gate] Usage: wait_for_advisory_reviews <pr_url>" >&2
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
    map({bot: .[0].bot, state: .[-1].state, time: .[-1].time, count: length}) |
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

# Check if all participating bots have submitted (early-exit condition)
all_bots_submitted() {
  local states="$1"

  # If no states, return false
  [ -z "$states" ] && return 1

  # Extract participating bots
  local submitted_bots
  submitted_bots=$(echo "$states" | jq -r '.bot' | sort)

  # If any bot is in the latest states, we have at least one participating bot
  [ -n "$submitted_bots" ] && return 0 || return 1
}

# Main wait logic with proper early-exit conditions
wait_for_advisory_reviews() {
  local start_time elapsed current_states participating_bots

  start_time=$(date +%s)

  log_info "Starting advisory bot review gate for PR #${PR_NUM}"

  # Phase 1: Detect which bots are participating (with early detection)
  log_info "Detecting participating bots (polling for up to 30 seconds)..."
  local detection_deadline=$((start_time + 30))

  while true; do
    current_states=$(get_advisory_bot_states)
    [ -n "$current_states" ] && break  # Got at least one submission

    elapsed=$(($(date +%s) - start_time))
    [ $(($(date +%s))) -ge $detection_deadline ] && break  # 30s detection timeout

    sleep 2
  done

  if [ -z "$current_states" ]; then
    log_warn "No advisory bot reviews detected yet (may be slow PR)"
    participating_bots=""
  else
    participating_bots=$(echo "$current_states" | jq -r '.bot' | sort -u | tr '\n' ' ')
    log_info "Participating bots detected: $participating_bots"
    while IFS= read -r line; do
      local bot state
      bot=$(echo "$line" | jq -r '.bot')
      state=$(echo "$line" | jq -r '.state')
      log_info "  $(format_bot_status "$bot" "$state")"
    done <<< "$current_states"
  fi

  # Tier 1: Wait up to 15 minutes with early exit
  log_info "Tier 1 wait: up to 900s (15 min) - waiting for advisory bots..."
  while true; do
    elapsed=$(($(date +%s) - start_time))

    if [ $elapsed -ge $TIER1_WAIT ]; then
      log_info "Tier 1 timeout reached ($TIER1_WAIT seconds)"
      break
    fi

    current_states=$(get_advisory_bot_states)

    # Check if all participating bots have submitted
    if [ -n "$current_states" ] && [ -n "$participating_bots" ]; then
      local all_present=true
      for bot in $participating_bots; do
        if ! echo "$current_states" | jq -r '.bot' | grep -q "^${bot}$"; then
          all_present=false
          break
        fi
      done

      if [ "$all_present" = true ]; then
        log_success "All participating bots have submitted - early exit from Tier 1 ✓"
        log_info "Final advisory bot status:"
        while IFS= read -r line; do
          local bot state
          bot=$(echo "$line" | jq -r '.bot')
          state=$(echo "$line" | jq -r '.state')
          log_info "  $(format_bot_status "$bot" "$state")"
        done <<< "$current_states"
        return 0
      fi
    fi

    sleep "${POLL_INTERVAL:-10}"
  done

  # Tier 2: Wait up to 20 minutes total with early exit
  log_info "Tier 2 wait: up to 1200s (20 min total) - extended wait for slow bots..."
  while true; do
    elapsed=$(($(date +%s) - start_time))

    if [ $elapsed -ge $TIER2_WAIT ]; then
      log_info "Tier 2 timeout reached ($TIER2_WAIT seconds)"
      break
    fi

    current_states=$(get_advisory_bot_states)

    # Check if all participating bots have submitted
    if [ -n "$current_states" ] && [ -n "$participating_bots" ]; then
      local all_present=true
      for bot in $participating_bots; do
        if ! echo "$current_states" | jq -r '.bot' | grep -q "^${bot}$"; then
          all_present=false
          break
        fi
      done

      if [ "$all_present" = true ]; then
        log_success "All participating bots have submitted - early exit from Tier 2 ✓"
        log_info "Final advisory bot status:"
        while IFS= read -r line; do
          local bot state
          bot=$(echo "$line" | jq -r '.bot')
          state=$(echo "$line" | jq -r '.state')
          log_info "  $(format_bot_status "$bot" "$state")"
        done <<< "$current_states"
        return 0
      fi
    fi

    sleep "${POLL_INTERVAL:-10}"
  done

  # Tier 3: Hard timeout (60 minutes)
  log_info "Tier 3 wait: Hard timeout at 3600s (60 min)..."
  log_info "Final advisory bot status:"
  current_states=$(get_advisory_bot_states)

  if [ -n "$current_states" ]; then
    while IFS= read -r line; do
      local bot state
      bot=$(echo "$line" | jq -r '.bot')
      state=$(echo "$line" | jq -r '.state')
      log_info "  $(format_bot_status "$bot" "$state")"
    done <<< "$current_states"
  else
    log_warn "No advisory bots have submitted by Tier 2 timeout"
  fi

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

    sleep "${TIER3_POLL_INTERVAL:-30}"
  done
}

# Run the wait gate (only if not being sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  wait_for_advisory_reviews
  exit_code=$?

  if [ $exit_code -eq 0 ]; then
    log_success "Advisory bot review gate passed ✓"
  elif [ $exit_code -eq 2 ]; then
    log_warn "Advisory bot review gate timed out, but proceeding with approval"
  fi

  exit $exit_code
fi
