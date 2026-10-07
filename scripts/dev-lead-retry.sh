#!/usr/bin/env bash
set -euo pipefail
# dev-lead-retry.sh — scan open PRs + issues for failure markers and re-dispatch
#
# timer_role: safety-net (docs/agentic-interaction-model.md §6.1). This is the
# 2 h cron's *backstop* — NOT the normal-path convergence clock it used to be
# (the #860 "amplifier"). Since #1407, a blocked/rate-limited dev-lead state is
# resumed EVENT-FIRST the moment a clearing event arrives (a review submitted or
# a check_run success) via scripts/dev-lead-resume.sh; this timer only catches
# the rare, genuinely un-eventable rate-limit recovery where no such event ever
# fires. Both paths dispatch through the SAME logic here (scan_pr_for_rate_limits)
# and the SAME stop-condition (pr_resume_suppressed), so the timer can never
# re-dispatch work the event path would not.
#
# Stop-condition-before-acting (§6.2.1): every scan re-checks, BEFORE any
# dispatch, that the PR is still open, is not human-gated (needs-human-review),
# has not exhausted its per-PR automation budget, and that the rate-limit reset
# window has actually elapsed with no terminal marker already posted.
#
# Called by the dev-lead-retry.yml scheduled cron workflow.
# Scans all open PRs across TARGET_ORG (plus DELEGATION_ORGS if set) for
# status=rate-limited markers on the current HEAD SHA, then re-dispatches the
# appropriate dev-lead event so the run is retried once the rate limit clears.
#
# It ALSO scans open issues labeled `dev-lead` for failed initial implementations
# (#781): an issue whose `Run issue` engine step failed carries a
# `<!-- dev-lead-issue <N> status=<failed|rate-limited> attempt=<K> ... -->`
# marker (written by dev-lead-fix-issue.sh). Those are re-dispatched as
# dev-lead-issue-retry up to MAX_ATTEMPTS, after which fix-issue.sh escalates to
# a human (dev-lead:needs-human) and the scan skips them.
#
# Env (required):
#   GH_TOKEN            — PAT with repo + contents:write scopes
#   TARGET_ORG          — GitHub org to scan (default: petry-projects)
#
# Env (optional):
#   DELEGATION_ORGS     — space-separated additional orgs to scan
#   DISPATCH_DELAY_SEC  — seconds between repo dispatches (default: 30) to
#                         prevent cascading org-wide rate-limit hits
#   DRY_RUN             — if "true", log what would be dispatched but don't send
#   NOW_ISO             — override current time for testing (ISO-8601 UTC)
#   BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC — seconds to wait after posting a
#                         bot-comment retry marker before re-listing markers
#                         to pick the earliest (default: 5), so a concurrent
#                         scan's marker is visible to the listing
#
# Retryable intents: fix-reviews, review-changes, rebase
#   These intents fetch all needed context (open threads, PR metadata) fresh
#   from the GitHub API at run time, so a re-dispatch has full fidelity.
#
# It ALSO re-dispatches fix-reviews for a bot comment EDITED after its dev-lead
# disposition (#2008). CodeRabbit edits one summary comment in place, for example
# to append a Security Architecture finding, and dev-lead only fires on CREATED
# comments. The caller stub's `on:` is standards-owned, so this sweep is the
# trigger. It is deduplicated: a successful fix-reviews run marker posted
# at/after the edit means a pass already saw the edited body, so CodeRabbit's
# frequent progress edits don't each spawn a run (stale_disposition_needs_dispatch).
#
# NOT retried automatically: on-mention
#   on-mention requires USER_INSTRUCTION from the original triggering event,
#   which cannot be reconstructed from the PR's current state. Users are asked
#   to re-trigger manually.
#
# fix-bot-comment IS retried, by a separate scan (#2017). A registered reviewer
#   bot's issue comment still exists, so its context can be rebuilt: the retry
#   dispatch carries only the comment's node id, and dev-lead-intent.sh
#   re-fetches the comment's CURRENT body, author and lastEditedAt by that id.
#   scan_pr_for_undispositioned_bot_comments finds open dev-lead PRs where such
#   a comment has no covering disposition and no info_status_pattern match, and
#   dispatches one deduplicated fix-bot-comment pass (lib/bot-comment-retry.sh).
#   This recovers the run GitHub drops when a burst of PR events supersedes the
#   pending fix-bot-comment run in the per-PR concurrency lane (#2009).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Escalation gate (#946): pr_has_escalation_label / NEEDS_HUMAN_REVIEW_LABEL.
# shellcheck source=lib/pr-automation-budget.sh
source "$SCRIPT_DIR/lib/pr-automation-budget.sh"
# Stale-disposition detector (#2008): maintainer_gate_stale_dispositions. Sourced
# only if not already loaded: its marker regex is readonly, and a caller (e.g.
# review-one-pr.sh via the advisory gate) may have sourced it before this script.
if [ -z "${_MAINTAINER_GATE_AGENT_MARKERS:-}" ]; then
  # shellcheck source=lib/maintainer-comment-gate.sh
  source "$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
fi
# Undispositioned bot-comment retry decision + comment fetch (#2017).
# shellcheck source=lib/bot-comment-retry.sh
source "$SCRIPT_DIR/lib/bot-comment-retry.sh"

TARGET_ORG="${TARGET_ORG:-petry-projects}"
DELEGATION_ORGS="${DELEGATION_ORGS:-}"
DISPATCH_DELAY_SEC="${DISPATCH_DELAY_SEC:-30}"
DRY_RUN="${DRY_RUN:-false}"
BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC="${BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC:-5}"
[[ "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC" =~ ^[0-9]+$ ]] || BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC=5

CI_MARKER_PREFIX="<!-- dev-lead-fix-ci sha="
REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="
ISSUE_MARKER_PREFIX="<!-- dev-lead-issue "

# Dispatch deduplication guard: prevents duplicate repository_dispatch calls
# when the event-first resume path and the safety-net cron arrive concurrently
# on the same PR. A guard marker is posted BEFORE dispatch; concurrent callers
# that see a recent guard skip instead of double-dispatching.
DISPATCH_GUARD_PREFIX="<!-- dev-lead-dispatch-guard sha="
DISPATCH_GUARD_WINDOW_SEC="${DISPATCH_GUARD_WINDOW_SEC:-600}"

# Issue-retry config (#781). MAX_ATTEMPTS matches dev-lead-fix-issue.sh and the
# auto-rebase-retry.sh convention: total attempts (initial + retries) before the
# issue is escalated to a human and skipped here.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
HISTORY_UNAVAILABLE_MAX_RETRIES="${HISTORY_UNAVAILABLE_MAX_RETRIES:-3}"
[[ "$HISTORY_UNAVAILABLE_MAX_RETRIES" =~ ^[0-9]+$ ]] || HISTORY_UNAVAILABLE_MAX_RETRIES=3
DEV_LEAD_LABEL="${DEV_LEAD_LABEL:-dev-lead}"
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-dev-lead:needs-human}"

# Intents whose context can be fully reconstructed at retry time.
# human-pr is included as a legacy alias for review-changes so that PRs already
# marked status=rate-limited with the old intent name are retried during migration.
RETRYABLE_REVIEW_INTENTS="fix-reviews review-changes human-pr rebase"

# get_now_epoch: current UTC time as unix epoch (overridable for tests)
get_now_epoch() {
  if [ -n "${NOW_ISO:-}" ]; then
    date -u -d "$NOW_ISO" +%s 2>/dev/null || date -u +%s
  else
    date -u +%s
  fi
}

# is_reset_in_future <reset_iso>: returns 0 if reset time is still in the future
is_reset_in_future() {
  local reset_iso="$1"
  [ -z "$reset_iso" ] && return 1  # unknown reset = don't skip
  local reset_epoch
  reset_epoch=$(date -u -d "$reset_iso" +%s 2>/dev/null || echo 0)
  [ "$(get_now_epoch)" -lt "$reset_epoch" ]
}

# has_dispatch_guard <comments_json> <sha>
# Returns 0 when a dispatch guard for this SHA was posted within
# DISPATCH_GUARD_WINDOW_SEC seconds, indicating a concurrent caller already
# claimed dispatch for this PR and the current caller should skip.
has_dispatch_guard() {
  local comments_json="$1" sha="$2" guard_time guard_epoch now_epoch age
  guard_time=$(echo "$comments_json" | jq -r \
    --arg pat "${DISPATCH_GUARD_PREFIX}${sha}" \
    '[.[] | select(. | test($pat))] | .[0] | capture("at=(?<t>[0-9T:Z-]+)") | .t // ""' \
    2>/dev/null || true)
  [ -z "$guard_time" ] && return 1
  guard_epoch=$(date -u -d "$guard_time" +%s 2>/dev/null || echo 0)
  now_epoch=$(get_now_epoch)
  age=$(( now_epoch - guard_epoch ))
  [ "$age" -lt "${DISPATCH_GUARD_WINDOW_SEC:-600}" ]
}

# post_dispatch_guard <repo> <pr_number> <sha>
# Posts a deduplication guard comment before dispatching. Skipped in DRY_RUN
# so tests stay clean; best-effort (failure is non-fatal).
post_dispatch_guard() {
  local repo="$1" pr_number="$2" sha="$3" now_iso
  [ "${DRY_RUN:-false}" = "true" ] && return 0
  now_iso="${NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local body="${DISPATCH_GUARD_PREFIX}${sha} at=${now_iso} -->"
  gh api --method POST "repos/${repo}/issues/${pr_number}/comments" \
    -f body="$body" >/dev/null 2>&1 || true
}

# lookup_check_run_details <repo> <head_sha> <check_name>
# Returns JSON {id, details_url} for the most recent failed check matching
# check_name on head_sha, so the retry dispatch has full failure context.
lookup_check_run_details() {
  local repo="$1" head_sha="$2" check_name="$3"
  gh api "repos/${repo}/commits/${head_sha}/check-runs?per_page=100" \
    --jq --arg name "$check_name" \
    '.check_runs
     | map(select(.name == $name and .conclusion == "failure"))
     | sort_by(.completed_at)
     | last
     | {id: (.id // ""), details_url: (.details_url // "")}' \
    2>/dev/null || echo '{"id":"","details_url":""}'
}

# dispatch_ci_retry <repo> <pr_number> <head_sha> <check_name>
# All logging goes to stderr so the function's stdout (empty) stays clean
# when called from within a command substitution.
dispatch_ci_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" check_name="${4:-CI failure}"
  echo "  -> dispatch ci-retry: repo=${repo} pr=${pr_number} sha=${head_sha:0:8} check=${check_name}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-ci-failure for PR ${pr_number} in ${repo}" >&2
    return 0
  fi

  # Look up the current check run to provide full failure context (details_url,
  # check run id) so fix-ci.sh can fetch logs and annotations for the retry.
  local run_details check_run_id details_url
  run_details=$(lookup_check_run_details "$repo" "$head_sha" "$check_name")
  check_run_id=$(echo "$run_details" | jq -r '.id // ""')
  details_url=$(echo "$run_details"  | jq -r '.details_url // ""')

  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg name "$check_name" \
    --arg details_url "$details_url" \
    --argjson check_run_id "$([ -n "$check_run_id" ] && echo "$check_run_id" || echo 'null')" \
    '{
      event_type: "dev-lead-ci-failure",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        checks: [{name: $name, conclusion: "failure", details_url: $details_url,
                  app_slug: "github-actions", id: $check_run_id}]
      }
    }')
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
    return 1
  fi
}

# dispatch_reviews_retry <repo> <pr_number> <head_sha> <intent_type>
# All logging goes to stderr (same reason as dispatch_ci_retry above).
dispatch_reviews_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" intent_type="$4"
  echo "  -> dispatch reviews-retry: repo=${repo} pr=${pr_number} sha=${head_sha:0:8} intent=${intent_type}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-reviews-retry for PR ${pr_number} in ${repo} intent=${intent_type}" >&2
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg intent_type "$intent_type" \
    '{
      event_type: "dev-lead-reviews-retry",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        intent_type: $intent_type
      }
    }')
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
    return 1
  fi
}

# dispatch_issue_retry <repo> <issue_number> <attempt>
# Re-dispatches a failed initial issue implementation (#781). The reusable
# workflow's intent classifier (dev-lead-intent.sh) recognises the
# dev-lead-issue-retry type and routes it back to the `issue` intent.
# All logging goes to stderr (same reason as dispatch_ci_retry above).
dispatch_issue_retry() {
  local repo="$1" issue_number="$2" attempt="$3"
  echo "  -> dispatch issue-retry: repo=${repo} issue=${issue_number} attempt=${attempt}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-issue-retry for issue ${issue_number} in ${repo} attempt=${attempt}" >&2
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson issue_number "$issue_number" \
    --arg repo "$repo" \
    --argjson attempt "$attempt" \
    '{
      event_type: "dev-lead-issue-retry",
      client_payload: {
        issue_number: $issue_number,
        repo: $repo,
        attempt: $attempt
      }
    }')
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for issue ${issue_number} in ${repo}" >&2
  fi
}

# fetch_pr_comment_nodes <repo> <pr_number>
#   Echo a JSON array of the PR's issue-comment nodes with the fields the #2008
#   stale-disposition check needs, including lastEditedAt, which the REST comments
#   API does not expose. Paginated GraphQL. Echoes nothing on any API failure, so
#   the caller never dispatches on a guess.
fetch_pr_comment_nodes() {
  local repo="$1" pr_number="$2" page nodes all="[]" has_next="true" cursor="" pages=0
  local -a cursor_args=()
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  local q='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$pr){comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{id author{login __typename} authorAssociation body createdAt isMinimized minimizedReason lastEditedAt}}}}}'
  while [ "$has_next" = "true" ]; do
    pages=$((pages + 1))
    [ "$pages" -le 50 ] || return 0
    page=$(gh api graphql -f query="$q" -F owner="${repo%%/*}" -F repo="${repo##*/}" \
      -F pr="$pr_number" "${cursor_args[@]}" 2>/dev/null) || return 0
    nodes=$(jq -c '.data.repository.pullRequest.comments.nodes // empty' <<< "$page" 2>/dev/null) || return 0
    [ -n "$nodes" ] || return 0
    all=$(jq -cn --argjson a "$all" --argjson b "$nodes" '$a + $b' 2>/dev/null) || return 0
    has_next=$(jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage // false' <<< "$page" 2>/dev/null || echo false)
    cursor=$(jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor // ""' <<< "$page" 2>/dev/null || echo "")
    [ -n "$cursor" ] || has_next="false"
    cursor_args=(-f "cursor=${cursor}")
  done
  printf '%s' "$all"
}

# stale_disposition_needs_dispatch <comment_nodes_json> <pr_number>
#   0 when a fix-reviews pass should be dispatched for the #2008 edit re-open:
#   some bot comment was edited strictly after its latest dev-lead disposition
#   (maintainer_gate_stale_dispositions), AND no successful fix-reviews run marker
#   for THIS PR (`<!-- dev-lead-fix-reviews pr=<N> … intent=fix-reviews
#   status=applied|no-changes`) was posted at/after the latest such edit. The
#   marker check is the dedup. A pass that already ran after the edit saw the
#   current body, so a burst of CodeRabbit progress edits costs one run, not one per
#   edit. A pass counts from when it STARTED (the marker's read_at=, a lower bound
#   on when it read the comments), not when its marker was posted: a pass that
#   began before the edit and finished after it never saw the edited body. A
#   legacy marker without read_at= falls back to its createdAt.
#   A failed pass does not count, so its comment is retried. Only a marker
#   from a trusted author (OWNER/MEMBER/COLLABORATOR, as dev-lead's own markers
#   are) counts, so an outside commenter pasting a success-shaped marker cannot
#   suppress the re-dispatch. 1 otherwise, including unreadable input (never
#   dispatch on a guess). Pure apart from reading the reviewer registry.
stale_disposition_needs_dispatch() {
  local nodes="$1" pr_number="$2" stale latest_edit later_runs
  [[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
  stale=$(maintainer_gate_stale_dispositions "$nodes" "${BOT_USER:-donpetry-bot}") || return 1
  latest_edit=$(jq -r 'map(.lastEditedAt) | max // ""' <<< "$stale" 2>/dev/null) || return 1
  [ -n "$latest_edit" ] || return 1
  later_runs=$(jq -r --arg e "$latest_edit" \
    --arg re "<!-- dev-lead-fix-reviews pr=${pr_number} [^>]*intent=fix-reviews status=(applied|no-changes)" '
      [ .[] | objects
        | select((.authorAssociation // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a) != null)
        | select((.body // "") | test($re))
        | (.createdAt // "") as $posted
        | ([(.body // "") | capture("read_at=(?<r>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)") | .r] | first // $posted) as $seen
        | select($seen >= $e) ] | length' <<< "$nodes" 2>/dev/null) || return 1
  [ "$later_runs" = "0" ]
}

# scan_pr_for_rate_limits <repo> <pr_number>
# Checks the PR's comments for rate-limited markers and dispatches retries.
# Prints only a single integer (retries dispatched) to stdout; all other
# output goes to stderr so callers can safely capture the count.
scan_pr_for_rate_limits() {
  local repo="$1" pr_number="$2"

  # Fetch the PR object once — we need both its HEAD SHA and its labels.
  local pr_obj
  pr_obj=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null || echo '{}')

  local head_sha
  head_sha=$(jq -r '.head?.sha // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ -z "$head_sha" ]; then
    echo "  [warn] could not resolve HEAD SHA for PR ${pr_number} in ${repo} — skipping" >&2
    echo "0"
    return 0
  fi

  # Guard against dispatching on closed or merged PRs. A review or check event
  # can race with a PR close/merge, leaving a historical rate-limited marker
  # still eligible — we must not re-dispatch work for a non-open PR.
  local pr_state
  pr_state=$(jq -r '.state // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ "$pr_state" != "open" ]; then
    echo "  [skip] PR ${pr_number} in ${repo} is ${pr_state:-unknown} — not re-dispatching closed/merged PR" >&2
    echo "0"
    return 0
  fi

  # Stop-condition-before-acting (§6.2.1 timer contract). This safety-net cron and
  # the event-first resume bridge (scripts/dev-lead-resume.sh) share ONE gate,
  # pr_resume_suppressed, so the timer can never re-dispatch work the event path
  # would not (#1407 AC #3). It suppresses a PR that is human-gated
  # (needs-human-review, #946) OR that has exhausted its per-PR automation budget
  # (#926) — re-dispatching either would re-ignite the #860 "amplifier". We reuse
  # the already-fetched labels to avoid a redundant PR fetch.
  local labels_json
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$pr_obj" 2>/dev/null || echo '[]')
  if pr_resume_suppressed "$pr_number" "$repo" "$labels_json"; then
    echo "0"
    return 0
  fi

  # Fetch all comment bodies, paginating to ensure we don't miss markers on busy PRs
  local comments_json
  comments_json=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
    --jq '[.[].body]' 2>/dev/null | jq -s 'add // []' || echo "[]")

  # Deduplication guard: if a concurrent resume path already claimed dispatch
  # for this SHA, skip to prevent duplicate repository_dispatch calls (#1407).
  if has_dispatch_guard "$comments_json" "$head_sha"; then
    echo "  [skip] PR ${pr_number} SHA ${head_sha:0:8} has a recent dispatch guard — skipping to avoid duplicate" >&2
    echo "0"
    return 0
  fi
  local guard_posted=0

  local dispatched=0
  # Set when a rate-limit hold has not reset yet. A pass dispatched now would hit
  # the same limit, so the #2008 edit re-dispatch below waits for the reset too.
  local held=0

  # ── Check for fix-ci rate-limited marker on current HEAD SHA ──────────────
  local ci_pattern="${CI_MARKER_PREFIX}${head_sha} status=rate-limited"
  if echo "$comments_json" | jq -e --arg pat "$ci_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
    # Extract reset time from the marker (format: reset=<ISO>)
    local reset_time
    reset_time=$(echo "$comments_json" | jq -r \
      --arg pat "$ci_pattern" \
      '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?<r>[0-9T:Z-]+)") | .r // ""' \
      2>/dev/null || true)

    if is_reset_in_future "$reset_time"; then
      echo "  [skip] fix-ci rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
      held=1
    else
      # Skip if a terminal marker was already posted for this SHA (prior retry succeeded)
      local terminal_pattern="${CI_MARKER_PREFIX}${head_sha} status=(applied|failed|no-changes)"
      if echo "$comments_json" | jq -e --arg pat "$terminal_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
        echo "  [skip] fix-ci already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
      else
        local check_name="CI failure"
        check_name=$(echo "$comments_json" | jq -r \
          --arg pat "$ci_pattern" \
          '[.[] | select(. | test($pat))] | .[0] | capture("check=(?<c>[^\\s\"<>]+)") | .c // "CI failure"' \
          2>/dev/null || echo "CI failure")
        if [ "$guard_posted" -eq 0 ]; then
          # Fetch fresh comments to re-check for concurrent guards posted while we were evaluating
          local fresh_guard_check rc=0
          fresh_guard_check=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
            --jq '[.[].body]' 2>/dev/null | jq -s 'add // []') || rc=$?
          # If the read failed (rc != 0), skip dispatch to avoid potentially duplicating work
          if [ "$rc" -ne 0 ]; then
            echo "  [skip] PR ${pr_number} could not verify dispatch guard (read failed) — skipping to avoid duplicate dispatch" >&2
            echo "$dispatched"
            return 0
          fi
          if has_dispatch_guard "$fresh_guard_check" "$head_sha"; then
            echo "  [skip] PR ${pr_number} SHA ${head_sha:0:8} concurrent guard detected — skipping dispatch" >&2
            echo "$dispatched"
            return 0
          fi
          post_dispatch_guard "$repo" "$pr_number" "$head_sha"
          guard_posted=1
        fi
        # Count only a dispatch that was accepted: the caller gives a PR with no
        # dispatch this scan to the bot-comment retry (#2017), so a failed call must
        # not read as "this PR's one dispatch is used".
        if dispatch_ci_retry "$repo" "$pr_number" "$head_sha" "$check_name"; then
          dispatched=$(( dispatched + 1 ))
        fi
      fi
    fi
  fi

  # ── Check for retryable fix-reviews hold markers on HEAD SHA ───────────────
  # Only intents that can reconstruct their full context from the PR at retry
  # time. on-mention is excluded: its USER_INSTRUCTION cannot be recovered from
  # the PR's current state. fix-bot-comment is retried per comment (by node id)
  # by scan_pr_for_undispositioned_bot_comments instead (#2017).
  # Both hold tokens are retryable (#1568): status=rate-limited (genuine quota) and
  # status=blocked (non-quota PR blockers). Matching both keeps re-dispatch behaviour
  # unchanged and leaves pre-#1568 status=rate-limited blocked markers parseable.
  for intent_type in $RETRYABLE_REVIEW_INTENTS; do
    local reviews_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=(rate-limited|blocked|history-unavailable)"
    if echo "$comments_json" | jq -e --arg pat "$reviews_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
      local reset_time
      reset_time=$(echo "$comments_json" | jq -r \
        --arg pat "$reviews_pattern" \
        '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?<r>[0-9T:Z-]+)") | .r // ""' \
        2>/dev/null || true)

      if is_reset_in_future "$reset_time"; then
        echo "  [skip] ${intent_type} rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
        held=1
        continue
      fi

      # Bound infrastructure-failure retries: a remote that cannot be deepened
      # posts a history-unavailable marker per run, with no reset time. After
      # HISTORY_UNAVAILABLE_MAX_RETRIES markers on this SHA, hold instead of
      # dispatching again. These runs are separate from rebase-conflict
      # exhaustion; a new head SHA starts a fresh count.
      local history_count
      history_count=$(echo "$comments_json" | jq -r --arg hpat "${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=history-unavailable" \
        '[.[] | select(test($hpat))] | length' 2>/dev/null || echo 0)
      if [[ "$history_count" =~ ^[0-9]+$ ]] && [ "$history_count" -ge "$HISTORY_UNAVAILABLE_MAX_RETRIES" ]; then
        echo "  [skip] ${intent_type} history-unavailable ${history_count}x for PR ${pr_number} SHA ${head_sha:0:8} — holding (infrastructure failure, retry limit ${HISTORY_UNAVAILABLE_MAX_RETRIES})" >&2
        continue
      fi

      # Normalize legacy intent aliases to their canonical names before checking
      # terminal markers and dispatching. "human-pr" was renamed to "review-changes";
      # dev-lead-intent.sh rewrites human-pr → review-changes, so the retried run
      # posts terminal markers as intent=review-changes, not intent=human-pr.
      # Without normalization here the terminal check never matches and the same
      # SHA is re-dispatched on every cron cycle indefinitely.
      local dispatch_intent="${intent_type}"
      [ "$dispatch_intent" = "human-pr" ] && dispatch_intent="review-changes"

      # Skip if a terminal marker was already posted (prior retry ran to completion)
      local reviews_terminal="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${dispatch_intent} status=(applied|no-changes|failed|unrelated-histories)"
      # A terminal marker older than a later status=history-unavailable marker is
      # stale (the pass failed, then hit a history infra error on a re-run), so it
      # must not mask the retry. Comments are chronological; compare positions.
      local history_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${dispatch_intent} status=history-unavailable"
      if echo "$comments_json" | jq -e --arg pat "$reviews_terminal" --arg hpat "$history_pattern" '
          to_entries as $e
          | ([$e[] | select(.value | test($pat)) | .key] | max) as $t
          | ([$e[] | select(.value | test($hpat)) | .key] | max) as $h
          | $t != null and ($h == null or $h < $t)' >/dev/null 2>&1; then
        echo "  [skip] ${intent_type} already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
        continue
      fi

      if [ "$guard_posted" -eq 0 ]; then
        # Fetch fresh comments to re-check for concurrent guards posted while we were evaluating
        local fresh_guard_check rc=0
        fresh_guard_check=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
          --jq '[.[].body]' 2>/dev/null | jq -s 'add // []') || rc=$?
        # If the read failed (rc != 0), skip dispatch to avoid potentially duplicating work
        if [ "$rc" -ne 0 ]; then
          echo "  [skip] PR ${pr_number} could not verify dispatch guard (read failed) — skipping to avoid duplicate dispatch" >&2
          continue
        fi
        if has_dispatch_guard "$fresh_guard_check" "$head_sha"; then
          echo "  [skip] PR ${pr_number} SHA ${head_sha:0:8} concurrent guard detected — skipping dispatch" >&2
          continue
        fi
        post_dispatch_guard "$repo" "$pr_number" "$head_sha"
        guard_posted=1
      fi
      if dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "$dispatch_intent"; then
        dispatched=$(( dispatched + 1 ))
      fi
    fi
  done

  # ── #2008: a bot comment edited after its dev-lead disposition ─────────────
  # dev-lead never sees comment edits, so re-dispatch a fix-reviews pass to
  # re-disposition the current body. This runs only when nothing else was
  # dispatched (that pass would see the edit too) and no rate-limit hold is still
  # active, and is deduplicated against fix-reviews runs that already ran after
  # the edit.
  if [ "$dispatched" -eq 0 ] && [ "$held" -eq 0 ]; then
    local comment_nodes
    comment_nodes=$(fetch_pr_comment_nodes "$repo" "$pr_number")
    if [ -n "$comment_nodes" ] && stale_disposition_needs_dispatch "$comment_nodes" "$pr_number"; then
      echo "  [stale-disposition] PR ${pr_number}: a bot comment was edited after its dev-lead disposition — re-dispatching fix-reviews (#2008)" >&2
      if [ "$guard_posted" -eq 0 ]; then
        # Fetch fresh comments to re-check for concurrent guards posted while we were evaluating
        local fresh_guard_check rc=0
        fresh_guard_check=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
          --jq '[.[].body]' 2>/dev/null | jq -s 'add // []') || rc=$?
        # If the read failed (rc != 0), skip dispatch to avoid potentially duplicating work
        if [ "$rc" -ne 0 ]; then
          echo "  [skip] PR ${pr_number} could not verify dispatch guard (read failed) — skipping to avoid duplicate dispatch" >&2
        elif has_dispatch_guard "$fresh_guard_check" "$head_sha"; then
          echo "  [skip] PR ${pr_number} SHA ${head_sha:0:8} concurrent guard detected — skipping dispatch" >&2
        else
          post_dispatch_guard "$repo" "$pr_number" "$head_sha"
          guard_posted=1
          dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "fix-reviews"
          dispatched=$(( dispatched + 1 ))
        fi
      else
        dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "fix-reviews"
        dispatched=$(( dispatched + 1 ))
      fi
    fi
  fi

  echo "$dispatched"
}

# withdraw_bot_comment_retry_marker <repo> <marker_id>
# Deletes a retry marker this scan posted but did not dispatch over. Best effort:
# a marker left behind reads as a pending retry and holds the comment for the
# BOT_COMMENT_RETRY_PENDING_SEC window, so a failed delete surfaces as a warning.
withdraw_bot_comment_retry_marker() {
  local repo="$1" marker_id="$2"
  [ -n "$marker_id" ] || return 0
  if ! gh api -X DELETE "repos/${repo}/issues/comments/${marker_id}" >/dev/null 2>&1; then
    echo "  ::warning::bot-comment retry: could not withdraw retry marker ${marker_id} in ${repo} — it holds the comment as retry-pending until BOT_COMMENT_RETRY_PENDING_SEC passes" >&2
  fi
}

# dispatch_bot_comment_retry <repo> <pr_number> <head_sha> <comment_node_id>
# Re-dispatches a fix-bot-comment pass for ONE bot comment (#2017). Reuses the
# dev-lead-reviews-retry type every caller stub already subscribes to, so no stub
# change is needed. The payload carries only the comment's node id — never its
# body — so the pass re-reads the comment's current body by id.
# All logging goes to stderr (same reason as dispatch_ci_retry above).
dispatch_bot_comment_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" comment_node_id="$4"
  echo "  -> dispatch bot-comment-retry: repo=${repo} pr=${pr_number} comment=${comment_node_id}" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-reviews-retry for PR ${pr_number} in ${repo} intent=fix-bot-comment comment=${comment_node_id}" >&2
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg comment_node_id "$comment_node_id" \
    '{
      event_type: "dev-lead-reviews-retry",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        intent_type: "fix-bot-comment",
        comment_node_id: $comment_node_id
      }
    }')
  if ! echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null 2>&1; then
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}" >&2
    return 1
  fi
}

# dev_lead_identity: dev-lead's acting login, from its persona manifest — NOT
# BOT_USER, which is pr-review's identity when pr-review calls this scan (#2017).
# DEV_LEAD_USER overrides; don-petry is the same fail-safe default the dev-lead
# workflow uses.
dev_lead_identity() {
  if [ -z "${DEV_LEAD_USER:-}" ]; then
    DEV_LEAD_USER=$(bash "$SCRIPT_DIR/lib/resolve-persona-identity.sh" dev-lead \
      "$SCRIPT_DIR/../personas" account 2>/dev/null || true)
    DEV_LEAD_USER="${DEV_LEAD_USER:-don-petry}"
  fi
  printf '%s' "$DEV_LEAD_USER"
}

# pr_review_identity: pr-review's acting login (it posts this scan's retry markers
# when its gate verdict runs the scan, #2017). PR_REVIEW_USER overrides;
# donpetry-bot is the pr-review workflow's own fallback.
pr_review_identity() {
  if [ -z "${PR_REVIEW_USER:-}" ]; then
    PR_REVIEW_USER=$(bash "$SCRIPT_DIR/lib/resolve-persona-identity.sh" pr-review \
      "$SCRIPT_DIR/../personas" account 2>/dev/null || true)
    PR_REVIEW_USER="${PR_REVIEW_USER:-donpetry-bot}"
  fi
  printf '%s' "$PR_REVIEW_USER"
}

# bcr_automation_logins: the comma-separated logins whose markers the bot-comment
# retry trusts — only our own automation. Each must be a plain GitHub login
# (it is also spliced into a --jq filter); anything else is dropped.
bcr_automation_logins() {
  local l out=""
  for l in "$(dev_lead_identity)" "$(pr_review_identity)"; do
    [[ "$l" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || continue
    out="${out:+${out},}${l}"
  done
  printf '%s' "$out"
}

# scan_pr_for_undispositioned_bot_comments <repo> <pr_number>
# Finds registered reviewer-bot issue comments on an open dev-lead PR that have
# no covering disposition and are not cleared by info_status_pattern, and
# dispatches a fix-bot-comment retry for the OLDEST one (#2017). At most one
# dispatch per PR per scan: every retry lands in the same per-PR concurrency lane,
# where a second dispatch would supersede the first while it is still pending —
# the exact loss this scan exists to recover. Remaining comments are picked up on
# later scans. Dedup (pending / completed / edited / attempt cap) lives in the
# pure bcr_retry_decisions. Prints only the number of dispatches to stdout; all
# other output goes to stderr. Fails closed (0 dispatches) on any read failure.
# It never minimizes anything: the pass posts a disposition, which the harness
# verifies as usual.
scan_pr_for_undispositioned_bot_comments() {
  local repo="$1" pr_number="$2"

  local pr_obj
  pr_obj=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null || echo '{}')
  local pr_state head_sha head_repo pr_author
  pr_state=$(jq -r '.state // empty' <<< "$pr_obj" 2>/dev/null || true)
  head_sha=$(jq -r '.head?.sha // empty' <<< "$pr_obj" 2>/dev/null || true)
  head_repo=$(jq -r '.head?.repo?.full_name // empty' <<< "$pr_obj" 2>/dev/null || true)
  pr_author=$(jq -r '.user?.login // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ "$pr_state" != "open" ]; then
    echo "  [skip] bot-comment retry: PR ${pr_number} in ${repo} is ${pr_state:-unknown}" >&2
    echo "0"; return 0
  fi
  # Authorship gate (#1311), mirrored from dev-lead-intent.sh (which re-checks it
  # on the retried event): fix-bot-comment only acts on PRs dev-lead authored.
  # Ownership is the PR's AUTHOR plus a same-repository head — never the branch
  # name, which any contributor can choose (a fork's `dev-lead/issue-*` branch
  # must not buy write-capable automation).
  if [ -z "$pr_author" ] || [ "$pr_author" != "$(dev_lead_identity)" ] \
     || [ "$head_repo" != "$repo" ]; then
    echo "0"; return 0
  fi
  local labels_json
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$pr_obj" 2>/dev/null || echo '[]')
  if pr_resume_suppressed "$pr_number" "$repo" "$labels_json"; then
    echo "0"; return 0
  fi

  local comments
  if ! comments=$(bcr_fetch_pr_comments "$repo" "$pr_number"); then
    echo "  [warn] bot-comment retry: could not read PR ${pr_number} comments in ${repo} — skipping (fail closed)" >&2
    echo "0"; return 0
  fi

  local trusted="${TRUSTED_BOTS:-}"
  if [ -z "$trusted" ]; then
    trusted=$( (
      # shellcheck source=lib/reviewer-sources.sh
      source "$SCRIPT_DIR/lib/reviewer-sources.sh" && reviewer_sources_trusted_bots_csv
    ) 2>/dev/null || true)
  fi
  if [ -z "$trusted" ]; then
    echo "  [warn] bot-comment retry: no trusted reviewer bots resolved — skipping" >&2
    echo "0"; return 0
  fi

  local automation
  automation=$(bcr_automation_logins)
  local decisions
  if ! decisions=$(bcr_retry_decisions "$comments" "$trusted" \
       "$(_maintainer_gate_info_patterns_json)" "$(get_now_epoch)" "$automation"); then
    echo "  [warn] bot-comment retry: could not evaluate PR ${pr_number} comments — skipping (fail closed)" >&2
    echo "0"; return 0
  fi

  if ! jq -r --arg pr "$pr_number" '.[] | select(.decision == "skip")
         | "  [skip] bot-comment \(.id) (\(.login)) on PR \($pr): \(.reason)"' \
       <<< "$decisions" >&2; then
    echo "  [warn] bot-comment retry: could not render skip decisions for PR ${pr_number}" >&2
  fi

  local pick cid version attempt now_iso
  pick=$(jq -c 'first(.[] | select(.decision == "dispatch")) // empty' <<< "$decisions")
  if [ -z "$pick" ]; then
    echo "0"; return 0
  fi
  cid=$(jq -r '.id' <<< "$pick")
  version=$(jq -r '.version' <<< "$pick")
  attempt=$(jq -r '.attempt' <<< "$pick")
  # These are spliced into the marker body and the claim's --jq filter below.
  if [[ ! "$cid" =~ ^[-A-Za-z0-9_+/=]+$ ]] || [[ ! "$attempt" =~ ^[0-9]+$ ]] \
     || [[ ! "$version" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
    echo "  [warn] bot-comment retry: unexpected comment id/version/attempt on PR ${pr_number} — not dispatching" >&2
    echo "0"; return 0
  fi
  now_iso="${NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  echo "  [retry] bot-comment ${cid} ($(jq -r '.login' <<< "$pick")) on PR ${pr_number}: undispositioned → fix-bot-comment attempt ${attempt}" >&2

  # Record the attempt BEFORE dispatching so a concurrent caller (the cron and
  # pr-review's gate verdict) sees it as pending and does not duplicate it.
  local marker_id=""
  if [ "$DRY_RUN" != "true" ]; then
    if ! marker_id=$(gh api --method POST "repos/${repo}/issues/${pr_number}/comments" \
         -f body="$(bcr_retry_marker "$cid" "$version" "$attempt" "$now_iso")" \
         --jq '.id // empty' 2>/dev/null); then
      echo "  [warn] bot-comment retry: could not record the retry marker on PR ${pr_number} — not dispatching (dedup unavailable)" >&2
      echo "0"; return 0
    fi
    if [[ ! "$marker_id" =~ ^[0-9]+$ ]]; then
      # Posted, but its id is unreadable: it can be neither verified nor withdrawn.
      echo "  [warn] bot-comment retry: the retry marker's id on PR ${pr_number} is unreadable — not dispatching (fail closed)" >&2
      echo "0"; return 0
    fi
    # Two concurrent scans can both have seen no marker. Keep only the earliest
    # marker for this comment version AND attempt; the loser withdraws and does
    # not dispatch. Scoped to the attempt so a lost run's expired attempt-N marker
    # never wins against the attempt-N+1 retry that replaces it, and to markers
    # our own automation posted with a trusted association — exactly the markers
    # bcr_retry_decisions counts — so a commenter pasting matching text cannot
    # make every scan back off.
    #
    # This is a best-effort claim, not a lock: the listing is eventually
    # consistent, so the re-list waits BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC for a
    # concurrent scan's marker to become visible. If two scans still each see only
    # their own marker, both dispatch. The residual cost is bounded: the per-PR
    # lane does not cancel in progress, the second pass re-checks the comment's
    # disposition at run time, and both markers count toward the attempt limits.
    local marker_ids first_marker logins_jq
    # Compared without a `[bot]` suffix, as bcr_retry_decisions does (REST keeps
    # the suffix on an App login; GraphQL omits it).
    logins_jq=$(jq -cn --arg a "$automation" '$a | split(",") | map(sub("\\[bot\\]$"; ""))')
    if [ "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC" -gt 0 ]; then
      sleep "$BOT_COMMENT_RETRY_CLAIM_SETTLE_SEC"
    fi
    if ! marker_ids=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
      --jq '.[] | select((.user.login // "" | sub("\\[bot\\]$"; "")) as $l | '"${logins_jq}"' | index($l) != null)
            | select((.author_association // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a) != null)
            | select((.body // "") | contains("dev-lead-bot-comment-retry id='"${cid}"' version='"${version}"' attempt='"${attempt}"' ")) | .id' \
      2>/dev/null); then
      echo "  [warn] bot-comment retry: could not re-read retry markers on PR ${pr_number} — withdrawing and not dispatching (fail closed)" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
    first_marker=$(printf '%s\n' "$marker_ids" | grep -E '^[0-9]+$' | sort -n | head -n1 || true)
    if [ -z "$first_marker" ]; then
      # Our own marker is not among the trusted ones: this scan posts under an
      # identity (or association) bcr_retry_decisions does not count, so its
      # markers could never hold a retry pending or count an attempt — every scan
      # would dispatch again. Fail closed rather than dispatch without dedup.
      echo "  ::warning::bot-comment retry: the retry marker on PR ${pr_number} was posted by an identity the retry dedup does not trust (expected one of: ${automation}) — withdrawing and not dispatching" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
    if [ "$first_marker" != "$marker_id" ]; then
      echo "  [skip] bot-comment ${cid} on PR ${pr_number}: a concurrent scan already recorded a retry" >&2
      withdraw_bot_comment_retry_marker "$repo" "$marker_id"
      echo "0"; return 0
    fi
  fi
  if ! dispatch_bot_comment_retry "$repo" "$pr_number" "$head_sha" "$cid"; then
    # Nothing was dispatched, so withdraw the marker — left in place it would read
    # as a pending retry and block the next attempt for the whole pending window.
    withdraw_bot_comment_retry_marker "$repo" "$marker_id"
    echo "0"; return 0
  fi
  echo "1"
}

# ── dropped-review recovery (#1741) ───────────────────────────────────────────
# A run cancelled while still PENDING (GitHub keeps only the newest pending run
# in a concurrency group and cancels the older ones) does its work-detection
# NEVER — it leaves no marker at all. The rate-limited-only scan above cannot
# recover it because there is no status=rate-limited marker to key on. This is
# the PR #1696 case: trusted-reviewer findings sit unaddressed for hours while
# the PR looks active (merge-churn commits, CI re-running), because the run that
# would have addressed them was silently dropped.
#
# The signal for a dropped review-handling run is therefore the ABSENCE of a
# dev-lead-fix-reviews marker for the current HEAD SHA while trusted-reviewer
# findings exist on that same SHA. Once dev-lead processes a SHA it posts a
# marker (any status), so this is idempotent: repeated merge-main churn cannot
# re-trigger a recovery for a SHA already handled (#1741 AC #4).

# resolve_trusted_reviewers: CSV of trusted reviewer logins (normalized, no
# "[bot]" suffix). TRUSTED_REVIEWERS overrides; otherwise projected from the
# single reviewer-source registry so this list can never drift from the gate
# (#1425). Falls back to a minimal built-in set if the manifest is unreadable.
resolve_trusted_reviewers() {
  if [ -n "${TRUSTED_REVIEWERS:-}" ]; then
    printf '%s' "$TRUSTED_REVIEWERS"
    return 0
  fi
  local csv=""
  if [ -f "$SCRIPT_DIR/lib/reviewer-sources.sh" ]; then
    # shellcheck source=lib/reviewer-sources.sh
    if source "$SCRIPT_DIR/lib/reviewer-sources.sh" 2>/dev/null; then
      csv=$(reviewer_sources_trusted_logins 2>/dev/null | paste -sd, - || true)
    fi
  fi
  if [ -z "$csv" ]; then
    echo "::warning::dev-lead: reviewer-sources registry unreadable — falling back to the built-in trusted-reviewer set (coderabbitai,copilot-pull-request-reviewer,gemini-code-assist); this may drift from the review gate (#1425)." >&2
    csv="coderabbitai,copilot-pull-request-reviewer,gemini-code-assist"
  fi
  printf '%s' "$csv"
}

# has_unaddressed_head_findings <pr_number> <head_sha> <trusted_csv>
#                               <reviews_json> <review_comments_json>
#                               <issue_comments_json>
# Returns 0 (true) when a trusted reviewer has an UNADDRESSED finding pinned to
# head_sha — a CHANGES_REQUESTED review at that commit, or an inline review
# comment at that commit — that the SAME reviewer has NOT resolved with a later
# APPROVED at that commit, AND no dev-lead-fix-reviews marker exists for that PR
# at that SHA (dev-lead never processed this HEAD's reviews). Ordering is decided
# by submitted_at / created_at, NOT by the reviewer's latest STATE: a
# CHANGES_REQUESTED followed by a COMMENTED (no APPROVED) is still an open finding
# (the prior "latest state" collapse dropped it), and an inline comment left AFTER
# an APPROVED is still a finding (the prior collapse wrongly treated it as
# resolved) — #1742 review. Only an APPROVED whose submit time is at or after the
# finding resolves it. The REST review-comment payload carries no
# resolution/outdated flag, so the selector filters on commit_id == head_sha plus
# this timestamp-ordered approval check; the marker gate below is the idempotency
# guard.
has_unaddressed_head_findings() {
  local pr_number="$1" head_sha="$2" trusted_csv="$3"
  local reviews_json="$4" review_comments_json="$5" issue_comments_json="$6"

  local findings
  findings=$(jq -n \
    --arg sha "$head_sha" \
    --arg csv "$trusted_csv" \
    --argjson reviews "$reviews_json" \
    --argjson comments "$review_comments_json" \
    '
    def norm: (. // "") | sub("\\[bot\\]$"; "");
    ($csv | [splits("[, ]+")] | map(norm) | map(select(. != ""))) as $trusted
    # Trusted reviews at this exact commit, each tagged with reviewer + submit
    # time. Ordering is decided by submitted_at, NOT array position, so a
    # CHANGES_REQUESTED followed by a COMMENTED is not silently swallowed (#1742).
    | ([ $reviews[]?
         | select((.commit_id // "") == $sha)
         | { login: ((.user?.login // "") | norm), state: .state, ts: (.submitted_at // "") }
         | .login as $l | select(($trusted | index($l)) != null) ]) as $rev
    # Latest APPROVED submit time per trusted reviewer at this commit ("" = none).
    # An APPROVED only resolves findings at or before it (finding ts <= approval).
    | ($rev | map(select(.state == "APPROVED"))
            | group_by(.login) | map({ (.[0].login): (map(.ts) | max) }) | add // {}) as $approved_ts
    # A CHANGES_REQUESTED counts unless the same reviewer APPROVED at or after it.
    | ([ $rev[]
         | select(.state == "CHANGES_REQUESTED")
         | .login as $l
         | select((($approved_ts[$l]) // "") == "" or ($approved_ts[$l] < .ts)) ]
       | length) as $review_findings
    # Inline comments at this commit count unless the author APPROVED at or after
    # the comment — an APPROVED that PREDATES the comment does NOT resolve it.
    | ([ $comments[]?
         | select((.commit_id // "") == $sha)
         | { login: ((.user?.login // "") | norm), ts: (.created_at // "") }
         | .login as $l
         | select(($trusted | index($l)) != null)
         | select((($approved_ts[$l]) // "") == "" or ($approved_ts[$l] < .ts)) ]
       | length) as $comment_findings
    | $review_findings + $comment_findings
    ' 2>/dev/null || echo 0)

  [ "${findings:-0}" -gt 0 ] || return 1

  # Any dev-lead-fix-reviews marker for this SHA (any status) means the reviews
  # were processed — nothing was dropped.
  local marker_pat="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha}"
  if echo "$issue_comments_json" | jq -e --arg pat "$marker_pat" \
      '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# scan_pr_for_dropped_reviews <repo> <pr_number>
# Recovers a PR whose review-handling run was dropped while pending. Prints only
# a single integer (retries dispatched) to stdout; all other output goes to
# stderr so callers can capture the count. Shares every stop-condition with the
# rate-limited scan (open-state, pr_resume_suppressed budget/human gate, and the
# dispatch-dedup guard) so it can never re-ignite the #860 amplifier.
scan_pr_for_dropped_reviews() {
  local repo="$1" pr_number="$2"

  local pr_obj head_sha pr_state labels_json
  # Fail safe, not silent: a failed metadata fetch must SKIP (return 0 retries),
  # never mask into an empty object that could be misread. `if !` keeps the
  # failure out of set -e so one PR's API blip cannot abort the scan_repo loop.
  if ! pr_obj=$(gh api "repos/${repo}/pulls/${pr_number}"); then
    echo "  [warn] dropped-reviews: metadata fetch failed for PR ${pr_number} in ${repo} — skipping (no dispatch)" >&2
    echo "0"; return 0
  fi
  head_sha=$(jq -r '.head?.sha // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ -z "$head_sha" ]; then
    echo "  [warn] dropped-reviews: could not resolve HEAD SHA for PR ${pr_number} in ${repo}" >&2
    echo "0"; return 0
  fi

  pr_state=$(jq -r '.state // empty' <<< "$pr_obj" 2>/dev/null || true)
  if [ "$pr_state" != "open" ]; then
    echo "  [skip] dropped-reviews: PR ${pr_number} in ${repo} is ${pr_state:-unknown}" >&2
    echo "0"; return 0
  fi

  # Authorship gate: recovery is only allowed for dev-lead-authored PRs.
  # The ordinary review flow checks this via is_dev_lead_authored(); this path
  # must enforce the same invariant (#1741, P0).
  local head_ref pr_author
  head_ref=$(jq -r '.head?.ref // "" | tostring' <<< "$pr_obj" 2>/dev/null || true)
  pr_author=$(jq -r '.user?.login // "" | tostring' <<< "$pr_obj" 2>/dev/null || true)
  case "$head_ref" in
    dev-lead/issue-*) ;;  # Issue pickup pattern recognized
    *)
      if [ -z "$pr_author" ] || [ "$pr_author" != "${BOT_USER:-}" ]; then
        echo "  [skip] dropped-reviews: PR ${pr_number} in ${repo} is not dev-lead-authored (author: ${pr_author:-unknown})" >&2
        echo "0"; return 0
      fi
      ;;
  esac

  labels_json=$(jq -c '[.labels[]?.name]' <<< "$pr_obj" 2>/dev/null || echo '[]')
  if pr_resume_suppressed "$pr_number" "$repo" "$labels_json"; then
    echo "0"; return 0
  fi

  # A failed reviews/comments fetch must NOT masquerade as an empty result: an
  # empty issue-comments list would miss an existing dispatch/marker and let the
  # script dispatch duplicate recovery work. On any fetch failure, skip this PR
  # (return 0) — errs toward NOT dispatching, the safe direction for the #860
  # amplifier. `add // []` still yields [] when the API succeeds with no results.
  local reviews_json review_comments_json comments_json
  if ! reviews_json=$(gh api --paginate "repos/${repo}/pulls/${pr_number}/reviews?per_page=100" \
      --jq '[.[] | {state, commit_id, submitted_at, user: {login: .user?.login}}]' | jq -s 'add // []'); then
    echo "  [warn] dropped-reviews: reviews fetch failed for PR ${pr_number} in ${repo} — skipping (no dispatch)" >&2
    echo "0"; return 0
  fi
  if ! review_comments_json=$(gh api --paginate "repos/${repo}/pulls/${pr_number}/comments?per_page=100" \
      --jq '[.[] | {commit_id, created_at, user: {login: .user?.login}}]' | jq -s 'add // []'); then
    echo "  [warn] dropped-reviews: review-comments fetch failed for PR ${pr_number} in ${repo} — skipping (no dispatch)" >&2
    echo "0"; return 0
  fi
  if ! comments_json=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
      --jq '[.[].body]' | jq -s 'add // []'); then
    echo "  [warn] dropped-reviews: issue-comments fetch failed for PR ${pr_number} in ${repo} — skipping (no dispatch)" >&2
    echo "0"; return 0
  fi

  # Deduplication guard: a concurrent resume/cron path may already have claimed
  # dispatch for this SHA.
  if has_dispatch_guard "$comments_json" "$head_sha"; then
    echo "  [skip] dropped-reviews: PR ${pr_number} SHA ${head_sha:0:8} has a recent dispatch guard" >&2
    echo "0"; return 0
  fi

  local trusted_csv
  trusted_csv=$(resolve_trusted_reviewers)

  if has_unaddressed_head_findings "$pr_number" "$head_sha" "$trusted_csv" \
       "$reviews_json" "$review_comments_json" "$comments_json"; then
    # Re-check for guard before posting: a concurrent caller may have posted one
    # between the initial guard check (line 1009) and here, while we were fetching
    # findings. Fetch fresh comments to verify.
    local fresh_guard_check rc=0
    fresh_guard_check=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
      --jq '[.[].body]' 2>/dev/null | jq -s 'add // []') || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  [skip] dropped-reviews: PR ${pr_number} could not verify dispatch guard (read failed) — skipping to avoid duplicate dispatch" >&2
      echo "0"; return 0
    fi
    if has_dispatch_guard "$fresh_guard_check" "$head_sha"; then
      echo "  [skip] dropped-reviews: PR ${pr_number} SHA ${head_sha:0:8} concurrent guard detected — skipping dispatch" >&2
      echo "0"; return 0
    fi
    # Observable signal (#1741 AC #2): a ::warning:: distinguishes "a run was
    # dropped and is being recovered" from "nothing to do" without a manual sweep.
    echo "::warning::dev-lead dropped-review recovery: PR ${pr_number} in ${repo} has trusted-reviewer findings on HEAD ${head_sha:0:8} with no dev-lead-fix-reviews marker — a pending run was likely cancelled before it ran (#1741). Re-dispatching fix-reviews." >&2
    post_dispatch_guard "$repo" "$pr_number" "$head_sha"
    dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "fix-reviews"
    echo "1"; return 0
  fi

  echo "0"
}

# scan_repo <repo>: scan all open PRs in a repo for rate-limited markers
scan_repo() {
  local repo="$1"
  echo "[retry] scanning ${repo}..."

  local prs_json
  prs_json=$(gh api --paginate "repos/${repo}/pulls?state=open&per_page=100" \
    --jq '[.[] | {number: .number, head_sha: .head.sha}]' 2>/dev/null || echo "[]")

  local pr_count
  pr_count=$(echo "$prs_json" | jq -s 'add // [] | length')
  if [ "$pr_count" -eq 0 ]; then
    echo "  no open PRs in ${repo}"
  else
    echo "  found ${pr_count} open PR(s)"
    local total_dispatched=0
    while IFS= read -r pr_entry; do
      local pr_number
      pr_number=$(echo "$pr_entry" | jq -r '.number')
      local dispatched dropped
      dispatched=$(scan_pr_for_rate_limits "$repo" "$pr_number")
      total_dispatched=$(( total_dispatched + dispatched ))
      # One dispatch per PR per scan (#2017): a second dispatch into the same
      # per-PR lane would supersede the first while it is still pending.
      if [ "${dispatched:-0}" -eq 0 ]; then
        dispatched=$(scan_pr_for_undispositioned_bot_comments "$repo" "$pr_number")
        total_dispatched=$(( total_dispatched + dispatched ))
      fi
      # #1741: also recover a PR whose review-handling run was dropped while
      # pending (no rate-limited marker to key on).
      dropped=$(scan_pr_for_dropped_reviews "$repo" "$pr_number")
      total_dispatched=$(( total_dispatched + dropped ))
    done < <(echo "$prs_json" | jq -sc 'add // [] | .[]')
    echo "  dispatched ${total_dispatched} PR retries from ${repo}"
  fi

  # Always scan open issues for failed initial implementations (#781) — even when
  # the repo has no open PRs, which is the common case for a stalled issue.
  scan_repo_issues "$repo"
}

# open_issue_pr_exists <repo> <issue_number>
# Returns 0 if an open PR for this issue already exists (branch dev-lead/issue-<N>*),
# meaning a prior attempt already produced — or is producing — a PR. In that case
# the issue must NOT be re-dispatched (the PR path takes over).
open_issue_pr_exists() {
  local repo="$1" issue_number="$2" count
  count=$(gh api --paginate "repos/${repo}/pulls?state=open&per_page=100" \
    --jq "[.[] | select(.head.ref | startswith(\"dev-lead/issue-${issue_number}-\"))]" \
    2>/dev/null | jq -s 'add | length' || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# scan_issue_for_retry <repo> <issue_number>
# Inspects the issue's newest dev-lead-issue marker and re-dispatches a bounded
# retry when warranted. Prints only a single integer (retries dispatched) to
# stdout; all other output goes to stderr so callers can capture the count.
scan_issue_for_retry() {
  local repo="$1" issue_number="$2"

  local comments_json
  comments_json=$(gh api --paginate "repos/${repo}/issues/${issue_number}/comments?per_page=100" \
    --jq '[.[].body]' 2>/dev/null || echo "[]")

  # Newest dev-lead-issue marker for this issue (comments are chronological, so
  # the last matching one is the most recent attempt — earlier ones superseded).
  local prefix="${ISSUE_MARKER_PREFIX}${issue_number} "
  local marker
  marker=$(echo "$comments_json" | jq -s -r --arg p "$prefix" \
    '[ .[] | .[]? | select(. != null and (. | contains($p))) ] | last // ""' 2>/dev/null || echo "")

  if [ -z "$marker" ]; then
    # No failure marker → nothing failed (or it succeeded). Nothing to retry.
    echo "0"
    return 0
  fi

  local status attempt reason reset
  status=$(printf '%s' "$marker"  | grep -oE 'status=[^ ]+'  | head -1 | cut -d= -f2)
  attempt=$(printf '%s' "$marker" | grep -oE 'attempt=[0-9]+' | head -1 | cut -d= -f2)
  reason=$(printf '%s' "$marker"  | grep -oE 'reason=[^ ]+'  | head -1 | cut -d= -f2)
  reset=$(printf '%s' "$marker"   | grep -oE 'reset=[0-9TZ:-]+' | head -1 | cut -d= -f2)

  # Only failed / rate-limited markers are retryable. A status=needs-human marker
  # (or any other) is terminal — skip (such issues also carry the needs-human
  # label and are filtered before reaching here, but double-guard).
  case "$status" in
    failed|rate-limited) : ;;
    *)
      echo "  [skip] issue #${issue_number}: newest marker status=${status:-?} not retryable" >&2
      echo "0"; return 0 ;;
  esac

  # Honour the rate-limit reset window for rate-limited markers.
  if [ "$status" = "rate-limited" ] && is_reset_in_future "$reset"; then
    echo "  [skip] issue #${issue_number} rate-limit not yet cleared (resets ${reset})" >&2
    echo "0"; return 0
  fi

  # Enforce the attempt ceiling. attempt>=MAX means fix-issue.sh already escalated
  # to a human on its last failure; do not re-dispatch.
  if [ -z "$attempt" ] || [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "  [skip] issue #${issue_number}: attempts exhausted (attempt=${attempt:-?}/${MAX_ATTEMPTS})" >&2
    echo "0"; return 0
  fi

  # Skip if a PR already exists for this issue (prior attempt succeeded, or a
  # retry run is currently producing one).
  if open_issue_pr_exists "$repo" "$issue_number"; then
    echo "  [skip] issue #${issue_number}: an open dev-lead PR already exists" >&2
    echo "0"; return 0
  fi

  echo "  [retry] issue #${issue_number}: status=${status} reason=${reason:-?} attempt=${attempt} < ${MAX_ATTEMPTS} → re-dispatching" >&2
  dispatch_issue_retry "$repo" "$issue_number" "$attempt"
  echo "1"
}

# scan_repo_issues <repo>: scan open issues labeled dev-lead for failed initial
# implementations and re-dispatch bounded retries.
scan_repo_issues() {
  local repo="$1"

  # Enumerate open issues carrying the dev-lead label but NOT the needs-human
  # escalation label. The issues endpoint also returns PRs, so filter
  # .pull_request==null to keep true issues only.
  local issues_json
  issues_json=$(gh api --paginate \
    "repos/${repo}/issues?state=open&labels=${DEV_LEAD_LABEL}&per_page=100" \
    --jq "[.[] | select(.pull_request == null)
           | select([.labels[].name] | index(\"${NEEDS_HUMAN_LABEL}\") | not)
           | {number: .number}]" \
    2>/dev/null || echo "[]")

  local issue_count
  issue_count=$(echo "$issues_json" | jq -s 'add // [] | length')
  if [ "${issue_count:-0}" -eq 0 ]; then
    echo "  no open dev-lead issues in ${repo}"
    return 0
  fi

  echo "  found ${issue_count} open dev-lead issue(s)"
  local total_dispatched=0
  while IFS= read -r issue_entry; do
    local issue_number dispatched
    issue_number=$(echo "$issue_entry" | jq -r '.number')
    dispatched=$(scan_issue_for_retry "$repo" "$issue_number")
    total_dispatched=$(( total_dispatched + dispatched ))
  done < <(echo "$issues_json" | jq -c '.[]')

  echo "  dispatched ${total_dispatched} issue retries from ${repo}"
}

# list_repos_for_org <org>: list all non-fork repos in the org.
# Hard-errors (non-zero exit) when the list is empty and not in DRY_RUN, since
# an empty result most likely means a token permission issue rather than a
# legitimately empty org — silently scanning 0 repos would hide misconfig.
list_repos_for_org() {
  local org="$1"
  local result
  result=$(gh repo list "$org" --limit 1000 --json nameWithOwner,isFork \
    --jq '[.[] | select(.isFork == false) | .nameWithOwner]' 2>/dev/null || echo "[]")
  if [ "$result" = "[]" ] || [ -z "$result" ]; then
    echo "::warning::No repos found for org '${org}' — check GH_TOKEN has repo read scope" >&2
    if [ "${DRY_RUN:-false}" != "true" ]; then
      echo "::error::Aborting: scanning 0 repos would silently miss all rate-limited PRs" >&2
      exit 1
    fi
  fi
  echo "$result"
}

main() {
  echo "[retry] dev-lead-retry starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[retry] dry_run=${DRY_RUN} dispatch_delay=${DISPATCH_DELAY_SEC}s"

  local all_repos=()

  # Collect repos from TARGET_ORG
  while IFS= read -r repo; do
    all_repos+=("$repo")
  done < <(list_repos_for_org "$TARGET_ORG" | jq -r '.[]')

  # Collect repos from DELEGATION_ORGS
  if [ -n "$DELEGATION_ORGS" ]; then
    for org in $DELEGATION_ORGS; do
      while IFS= read -r repo; do
        all_repos+=("$repo")
      done < <(list_repos_for_org "$org" | jq -r '.[]')
    done
  fi

  local repo_count="${#all_repos[@]}"
  echo "[retry] scanning ${repo_count} repo(s) across org(s)"

  local repo_index=0
  for repo in "${all_repos[@]}"; do
    if [ "$repo_index" -gt 0 ] && [ "$DISPATCH_DELAY_SEC" -gt 0 ]; then
      # Stagger dispatches to avoid hammering the rate-limited API simultaneously
      echo "[retry] waiting ${DISPATCH_DELAY_SEC}s before next repo (stagger)..."
      sleep "$DISPATCH_DELAY_SEC"
    fi
    scan_repo "$repo"
    repo_index=$(( repo_index + 1 ))
  done

  echo "[retry] done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Run main only when executed directly (bash dev-lead-retry.sh), not when sourced
# by unit tests that exercise individual functions (scan_issue_for_retry, etc.).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
