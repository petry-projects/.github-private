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
declare -Ar ADVISORY_BOTS=(
  [gemini-code-assist]="Gemini Code Assist (advisory)"
  [copilot-pull-request-reviewer]="Copilot PR Reviewer (advisory)"
  [sonarqubecloud]="SonarCloud (advisory)"
  [chatgpt-codex-connector]="Codex (advisory, newer bot)"
)

# Known rate-limit / usage-limit markers an advisory bot posts when it is out of
# quota and cannot submit a real review (issue #657). A comment from an advisory
# bot whose body matches any of these is classified RATE_LIMITED and treated as
# non-participating so a permanently out-of-quota bot can't hold the gate open.
#   - CodeRabbit: "Review limit reached" / "used up its prepaid credits"
#   - Codex:      "reached your Codex usage limits"
# shellcheck disable=SC2034
readonly RATE_LIMIT_MARKERS='Review limit reached|used up its prepaid credits|reached your Codex usage limit'

# Timeout-proceed windows for absent advisory bots (issue #1193, split from #1181).
# The gate must not block a PR forever when an advisory bot never produces output
# on the repo — a new repo where Gemini/Codex aren't vendor-side enabled, a bot
# uninstalled entirely (Copilot on a Free plan), or a bot outage. Past these
# windows an absent bot is treated as a *missing review*, not a *permanent block*.
#   HEAD_AGE   — proceed once the head commit is this old (primary timeout; the
#                only one that applies when NO bot has produced any output).
#   QUIESCENCE — proceed once no new bot submission has arrived for this long
#                (only meaningful once ≥1 bot has submitted).
# shellcheck disable=SC2034
readonly ADVISORY_HEAD_AGE_TIMEOUT_SEC=1200
# shellcheck disable=SC2034
readonly ADVISORY_QUIESCENCE_TIMEOUT_SEC=600

# Color codes for output
# shellcheck disable=SC2034
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m' # No Color

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
    return 2  # API error — distinct from "no bots yet" (1) so caller can fail-fast
  }

  echo "$gh_output" | jq -c --argjson bots "$bot_array" --arg markers "$RATE_LIMIT_MARKERS" '
    # Collect all bot submissions with their state. A comment whose body matches a
    # known rate-limit/usage-limit marker is classified RATE_LIMITED (the bot is out
    # of quota and cannot submit a real review); all other comments are COMMENTED.
    (
      [(.reviews // [])[] | select([.author.login] | inside($bots)) | {bot: .author.login, state: .state, time: .submittedAt}] +
      [(.comments // [])[] | select([.author.login] | inside($bots)) | {
        bot: .author.login,
        state: (if ((.body // "") | test($markers; "i")) then "RATE_LIMITED" else "COMMENTED" end),
        time: .createdAt
      }]
    ) |
    # Group by bot, sort by time within each group, keep latest submission per bot
    group_by(.bot) |
    map(sort_by(.time) | last | {bot: .bot, state: .state, time: .time}) |
    sort_by(.bot) |
    .[]
  ' || {
    log_warn "jq processing failed"
    return 2  # Parse error — also distinct from "no bots yet" (1)
  }
}

# Get the committer date of the PR's head commit via a single GraphQL query.
# Uses committer.date (not author.date) so that cherry-picked commits reflect
# when the cherry-pick was applied (≈push time) rather than the original author
# date — preserving the cherry-pick guard without relying on pushedDate, which
# is deprecated in GitHub's GraphQL API and now returns null.
# Returns empty string on any API failure.
_get_head_committer_date() {
  local pr_url="$1"
  # shellcheck disable=SC2016  # $url is a GraphQL variable placeholder, not a shell variable
  local _gql='query($url:URI!){resource(url:$url){...on PullRequest{commits(last:1){nodes{commit{committer{date}}}}}}}'
  gh api graphql -f query="$_gql" -f url="$pr_url" \
    --jq '.data.resource.commits.nodes[0].commit.committer.date // empty' 2>/dev/null || true
}

# _head_age_seconds <pr_url>
#   Echo the age in seconds of the PR's head commit (now − committer.date), or an
#   empty string when the committer date can't be determined (GraphQL unreachable
#   or unparseable). Shared by the absent-bot head-age timeout paths so both the
#   partial-submission and zero-output branches proceed on the same clock.
_head_age_seconds() {
  local pr_url="$1" head_time head_time_raw now
  head_time=$(_get_head_committer_date "$pr_url") || head_time=""
  [[ -z "$head_time" ]] && return 0
  head_time_raw=$(date -u -d "$head_time" +%s 2>/dev/null) || head_time_raw=""
  [[ -z "$head_time_raw" ]] && return 0
  now=$(date -u +%s)
  printf '%s' "$((now - head_time_raw))"
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

# ────────────────────────────────────────────────────────────────────
# Rate-limit detection + marker (issue #711)
#
# When an advisory/review bot withholds a real review because it is out of
# quota, the gate keeps deferring approval but no event ever re-fires once CI
# settles green — the PR strands at REVIEW_REQUIRED. detect_advisory_rate_limit
# recognises that state and maybe_post_rate_limited_marker stamps a
# machine-detectable marker so pr-review-sweep can auto-retry after the limit
# resets (no manual force_review, which would bypass the gate entirely).
# ────────────────────────────────────────────────────────────────────

# Bots whose out-of-quota notice should arm the sweep retry. Superset of the
# gate's ADVISORY_BOTS — adds coderabbitai, which posts an explicit rate-limit
# comment but is not one of the bots the gate blocks on.
# shellcheck disable=SC2034
declare -ar RATE_LIMIT_NOTICE_BOTS=(
  gemini-code-assist
  copilot-pull-request-reviewer
  sonarqubecloud
  chatgpt-codex-connector
  coderabbitai
)

# Case-insensitive phrases that indicate a bot is itself rate-limited / out of
# quota (not merely discussing rate limiting). Kept reasonably specific so a
# genuine review that mentions "rate limit" in passing does not arm a retry.
_advisory_rate_limit_pattern() {
  printf '%s' 'usage limit|rate.?limit|too many requests|quota (exceeded|reached|exhausted)|out of (quota|credits|tokens|requests)|limit (reached|exceeded|exhausted)|(reached|exceeded|hit) (the |your )?(usage |rate |daily |monthly )?limit'
}

# detect_advisory_rate_limit <reviews-comments-json>
#   Returns 0 when a known advisory/review bot's LATEST submission body matches
#   the rate-limit pattern; 1 otherwise. Only the latest submission per bot is
#   considered, so a newer real review supersedes an older rate-limit notice
#   (and vice versa). Non-bot authors are ignored.
detect_advisory_rate_limit() {
  local json="${1:-}"
  [[ -z "$json" ]] && return 1

  local bot_array pattern matched
  bot_array=$(printf '%s\n' "${RATE_LIMIT_NOTICE_BOTS[@]}" | jq -R . | jq -s .)
  pattern=$(_advisory_rate_limit_pattern)

  matched=$(jq -r --argjson bots "$bot_array" --arg pat "$pattern" '
    (
      [(.reviews // [])[]  | {bot: .author.login, time: .submittedAt, body: (.body // "")}] +
      [(.comments // [])[] | {bot: .author.login, time: .createdAt,   body: (.body // "")}]
    )
    | map(select(.bot as $b | $bots | any(. == $b)))
    | group_by(.bot)
    | map(sort_by(.time) | last)
    | map(select(.body | test($pat; "i")))
    | length
  ' <<< "$json" 2>/dev/null) || return 1

  [[ "${matched:-0}" -gt 0 ]]
}

# maybe_post_rate_limited_marker <pr_url> <head_sha> <reset_iso> <comments_json>
#   Posts a deduplicated rate-limited marker comment so the sweep can detect the
#   withheld-due-to-rate-limit state and re-trigger a review after <reset_iso>.
#   <comments_json> is the already-fetched PR snapshot (.comments[]) used for the
#   dedup check, so no extra API call is needed to decide whether to post.
#   The marker prefix ("rate-limited" before v1) deliberately never matches the
#   idempotency marker regex (<!-- pr-review-agent v1 sha=...).
maybe_post_rate_limited_marker() {
  local pr_url="${1:-}" head_sha="${2:-}" reset_iso="${3:-}" comments_json="${4:-}"
  if [[ -z "$pr_url" || -z "$head_sha" ]]; then
    log_warn "maybe_post_rate_limited_marker: pr_url and head_sha are required"
    return 1
  fi

  local marker="<!-- pr-review-agent rate-limited v1 sha=${head_sha} status=rate-limited reset=${reset_iso} -->"

  # Dedup: skip if a rate-limited marker already exists at this exact head.
  local cj="$comments_json"
  [[ -z "$cj" ]] && cj='{}'
  local already
  already=$(jq -r --arg sha "$head_sha" '
    [ (.comments // [])[]
      | (.body // "")
      | select(test("<!-- pr-review-agent rate-limited v1 sha=" + $sha + " ")) ]
    | length' <<< "$cj" 2>/dev/null || echo 0)
  if [[ "${already:-0}" -gt 0 ]]; then
    log_info "Rate-limited marker already present at head ${head_sha:0:8} — not re-posting"
    return 0
  fi

  local body="${marker}
Advisory bots were rate-limited; auto-approval is withheld until they recover. pr-review-sweep will re-review this PR after ${reset_iso:-the limit resets}."

  if gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
    log_info "Posted rate-limited marker on $pr_url (head ${head_sha:0:8}, reset ${reset_iso:-n/a})"
  else
    log_warn "Failed to post rate-limited marker on $pr_url"
    return 1
  fi
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
  if [[ -z "$pr_url" ]]; then
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
    local gs_rc=$?
    if [[ $gs_rc -eq 2 ]]; then
      log_warn "Failed to query advisory bot states (API/parse error)"
      return 2  # Propagate API error — caller should fail, not treat as "waiting"
    fi
    log_warn "Failed to query advisory bot states"
    return 1
  }

  if [[ -z "$current_states" ]]; then
    # No advisory bot has produced ANY output on this PR. Historically the gate
    # blocked here forever, permanently stranding PRs on repos where an advisory
    # bot is not vendor-side enabled / not installed, or during a bot outage
    # (issue #1193, split from #1181). Apply the same head-age timeout the
    # partial-submission path uses: once the head commit is older than the window,
    # treat every absent bot as a *missing review* and proceed instead of
    # re-driving indefinitely — the scheduled sweep re-enters this gate until the
    # window is crossed. Within the window we still wait so bots that are merely
    # slow get their chance. When head age is undeterminable (GraphQL unreachable)
    # there is no timing basis to declare bots absent, so stay conservative and
    # wait; the next scheduled sweep retries once the API recovers.
    local head_age_sec
    head_age_sec=$(_head_age_seconds "$PR_URL")
    if [[ -n "$head_age_sec" && "$head_age_sec" -gt "$ADVISORY_HEAD_AGE_TIMEOUT_SEC" ]]; then
      log_warn "No advisory bot output; head is ${head_age_sec}s old (> ${ADVISORY_HEAD_AGE_TIMEOUT_SEC}s) — treating absent bots as missing reviews, proceeding (issue #1193)"
      return 0
    fi
    log_warn "No advisory bot reviews detected yet"
    log_warn "Will re-check when bots submit their reviews (pull_request_review event), or proceed once the head-age timeout (${ADVISORY_HEAD_AGE_TIMEOUT_SEC}s) elapses"
    return 1  # Within window — still waiting for bots
  fi

  # Extract participating bots (those who have submitted)
  local participating_bots num_submitted total_advisory_bots
  participating_bots=$(echo "$current_states" | jq -rs '[.[].bot] | unique | join(" ")')
  # Count only bots with real reviews, not rate-limited/unsupported ones
  num_submitted=$(echo "$current_states" | jq -rs '[.[] | select(.state != "RATE_LIMITED" and .state != "UNSUPPORTED") | .bot] | unique | length')
  total_advisory_bots=${#ADVISORY_BOTS[@]}

  log_info "Advisory bots detected: $participating_bots"
  while IFS= read -r line; do
    local bot state
    bot=$(echo "$line" | jq -r '.bot')
    state=$(echo "$line" | jq -r '.state')
    log_info "  $(format_bot_status "$bot" "$state")"
  done <<< "$current_states"

  # Rate-limited / unsupported bots can't (or needn't) submit a real review, so they
  # must not hold the gate (issue #657). Drop them from the required total:
  # effective_total = total − (rate-limited|unsupported), clamped to ≥1 so the gate
  # never approves with zero advisory input. num_submitted counts only real reviews.
  local num_unavailable effective_total
  num_unavailable=$(echo "$current_states" | jq -rs \
    '[.[] | select(.state == "RATE_LIMITED" or .state == "UNSUPPORTED") | .bot] | unique | length')
  effective_total=$((total_advisory_bots - num_unavailable))
  [[ "$effective_total" -lt 1 ]] && effective_total=1
  if [[ "$num_unavailable" -gt 0 ]]; then
    log_info "${num_unavailable} advisory bot(s) rate-limited/unsupported — required set reduced to ${effective_total}/${total_advisory_bots}"
  fi

  # Require the effective advisory set to submit before approving.
  # Two timeout fallbacks handle absent (but not rate-limited) bots (e.g. Copilot only
  # reviews a subset of PRs):
  #   1. Head-push age > 20 min: use latest commit time, not PR creation time, so a new
  #      commit on an old PR doesn't immediately bypass the gate (thread PRRT_..ofWG).
  #   2. Quiescence > 10 min: if no new submissions have arrived in 10 min, assume the
  #      remaining bots won't participate — prevents indefinite stranding when there is
  #      no scheduled retry event to re-enter this branch (thread PRRT_..ofWI).
  if [[ "$num_submitted" -lt "$effective_total" ]]; then
    local now head_time head_time_raw head_age_sec latest_sub_at latest_sub_raw time_since_last_sub
    now=$(date -u +%s)

    head_age_sec=0
    head_time_raw=""  # Initialize before conditional to prevent set -u abort
    # Use the head commit's committer date (via GraphQL) to determine push age.
    # committer.date reflects when a cherry-pick or rebase was applied, not the
    # original author date, so recently cherry-picked commits do not bypass the
    # gate. pushedDate was previously used for this purpose but now returns null
    # in GitHub's GraphQL API (deprecated and no longer populated).
    head_time=$(_get_head_committer_date "$PR_URL") || head_time=""
    if [[ -n "$head_time" ]]; then
      head_time_raw=$(date -u -d "$head_time" +%s 2>/dev/null) || head_time_raw=""
      [[ -n "$head_time_raw" ]] && head_age_sec=$((now - head_time_raw))
    fi

    time_since_last_sub=0
    # -s (slurp) is required: current_states is a newline-delimited object
    # stream. Without slurping, `.[].time` iterates each object's scalar
    # values and jq errors — leaving latest_sub_at empty, time_since_last_sub
    # at 0, and the quiescence fallback permanently disarmed.
    latest_sub_at=$(echo "$current_states" | jq -rs '[.[].time] | sort | last // empty' 2>/dev/null) || latest_sub_at=""
    if [[ -n "$latest_sub_at" ]]; then
      latest_sub_raw=$(date -u -d "$latest_sub_at" +%s 2>/dev/null) || latest_sub_raw=""
      if [[ -n "$latest_sub_raw" ]]; then
        # Anchor quiescence to the later of head-push and latest submission so that
        # stale submissions from a previous HEAD don't satisfy the fallback for a
        # fresh commit (a new push resets the quiescence timer to the head-push time).
        # When head_time_raw is unavailable, anchor to latest_sub_at alone — this
        # loses the cherry-pick protection for quiescence but avoids indefinite
        # stranding when the commit API is unreachable.
        local quiescence_anchor
        if [[ -n "$head_time_raw" && "$head_time_raw" -gt "$latest_sub_raw" ]]; then
          quiescence_anchor=$head_time_raw
        else
          quiescence_anchor=$latest_sub_raw
        fi
        time_since_last_sub=$((now - quiescence_anchor))
      fi
    fi

    if [[ "$head_age_sec" -gt "$ADVISORY_HEAD_AGE_TIMEOUT_SEC" ]]; then
      log_info "Only ${num_submitted}/${effective_total} required bots submitted; head is ${head_age_sec}s old — timeout fallback, proceeding"
    elif [[ "$time_since_last_sub" -gt "$ADVISORY_QUIESCENCE_TIMEOUT_SEC" ]]; then
      log_info "Only ${num_submitted}/${effective_total} required bots submitted; no new submissions in ${time_since_last_sub}s — assuming absent bots won't participate, proceeding"
    else
      log_warn "Only ${num_submitted}/${effective_total} required advisory bots submitted so far (head age: ${head_age_sec}s, last submission: ${time_since_last_sub}s ago)"
      log_warn "Will re-check when remaining bots submit their reviews"
      return 1
    fi
  fi

  log_success "All detected advisory bots have submitted ✓"
  return 0  # Ready to approve
}

# Run the check (only if not being sourced)
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  if check_advisory_reviews "${1:-}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [[ $exit_code -eq 0 ]]; then
    log_success "Advisory bot review gate check PASSED ✓"
  elif [[ $exit_code -eq 1 ]]; then
    log_warn "Advisory bots still reviewing - will check again on next review submission"
  fi

  exit $exit_code
fi
