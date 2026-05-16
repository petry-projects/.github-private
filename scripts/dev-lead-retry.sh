#!/usr/bin/env bash
set -euo pipefail
# dev-lead-retry.sh — scan open PRs for rate-limited markers and re-dispatch
#
# Called by the dev-lead-retry.yml scheduled cron workflow.
# Scans all open PRs across TARGET_ORG (plus DELEGATION_ORGS if set) for
# status=rate-limited markers on the current HEAD SHA, then re-dispatches the
# appropriate dev-lead event so the run is retried once the rate limit clears.
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
#
# Retryable intents: fix-reviews, human-pr, rebase
#   These intents fetch all needed context (open threads, PR metadata) fresh
#   from the GitHub API at run time, so a re-dispatch has full fidelity.
#
# NOT retried automatically: human, fix-bot-comment
#   These intents require USER_INSTRUCTION / COMMENT_BODY from the original
#   triggering event, which cannot be reconstructed from the PR's current
#   state. Users are asked to re-trigger manually.

TARGET_ORG="${TARGET_ORG:-petry-projects}"
DELEGATION_ORGS="${DELEGATION_ORGS:-}"
DISPATCH_DELAY_SEC="${DISPATCH_DELAY_SEC:-30}"
DRY_RUN="${DRY_RUN:-false}"

CI_MARKER_PREFIX="<!-- dev-lead-fix-ci sha="
REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="

# Intents whose context can be fully reconstructed at retry time
RETRYABLE_REVIEW_INTENTS="fix-reviews human-pr rebase"

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
  fi
}

# scan_pr_for_rate_limits <repo> <pr_number>
# Checks the PR's comments for rate-limited markers and dispatches retries.
# Prints only a single integer (retries dispatched) to stdout; all other
# output goes to stderr so callers can safely capture the count.
scan_pr_for_rate_limits() {
  local repo="$1" pr_number="$2"

  # Get the current HEAD SHA of the PR
  local head_sha
  head_sha=$(gh api "repos/${repo}/pulls/${pr_number}" --jq '.head.sha' 2>/dev/null || true)
  if [ -z "$head_sha" ]; then
    echo "  [warn] could not resolve HEAD SHA for PR ${pr_number} in ${repo} — skipping" >&2
    echo "0"
    return 0
  fi

  # Fetch all comment bodies, paginating to ensure we don't miss markers on busy PRs
  local comments_json
  comments_json=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments?per_page=100" \
    --jq '[.[].body]' 2>/dev/null || echo "[]")

  local dispatched=0

  # ── Check for fix-ci rate-limited marker on current HEAD SHA ──────────────
  local ci_pattern="${CI_MARKER_PREFIX}${head_sha} status=rate-limited"
  if echo "$comments_json" | jq -e --arg pat "$ci_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
    # Extract reset time from the marker (format: reset=<ISO>)
    local reset_time
    reset_time=$(echo "$comments_json" | jq -r \
      --arg pat "$ci_pattern" \
      '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?P<r>[0-9T:Z-]+)") | .r // ""' \
      2>/dev/null || true)

    if is_reset_in_future "$reset_time"; then
      echo "  [skip] fix-ci rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
    else
      # Skip if a terminal marker was already posted for this SHA (prior retry succeeded)
      local terminal_pattern="${CI_MARKER_PREFIX}${head_sha} status=(applied|failed|no-changes)"
      if echo "$comments_json" | jq -e --arg pat "$terminal_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
        echo "  [skip] fix-ci already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
      else
        local check_name="CI failure"
        check_name=$(echo "$comments_json" | jq -r \
          --arg pat "$ci_pattern" \
          '[.[] | select(. | test($pat))] | .[0] | capture("check=(?P<c>[^\\s\"<>]+)") | .c // "CI failure"' \
          2>/dev/null || echo "CI failure")
        dispatch_ci_retry "$repo" "$pr_number" "$head_sha" "$check_name"
        dispatched=$(( dispatched + 1 ))
      fi
    fi
  fi

  # ── Check for retryable fix-reviews rate-limited markers on HEAD SHA ───────
  # Only intents that can reconstruct their full context at retry time.
  # human and fix-bot-comment are excluded: their USER_INSTRUCTION/COMMENT_BODY
  # cannot be recovered from the PR's current state.
  for intent_type in $RETRYABLE_REVIEW_INTENTS; do
    local reviews_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=rate-limited"
    if echo "$comments_json" | jq -e --arg pat "$reviews_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
      local reset_time
      reset_time=$(echo "$comments_json" | jq -r \
        --arg pat "$reviews_pattern" \
        '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?P<r>[0-9T:Z-]+)") | .r // ""' \
        2>/dev/null || true)

      if is_reset_in_future "$reset_time"; then
        echo "  [skip] ${intent_type} rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})" >&2
        continue
      fi

      # Skip if a terminal marker was already posted (prior retry ran to completion)
      local reviews_terminal="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=(applied|no-changes|failed)"
      if echo "$comments_json" | jq -e --arg pat "$reviews_terminal" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
        echo "  [skip] ${intent_type} already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}" >&2
        continue
      fi

      dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "$intent_type"
      dispatched=$(( dispatched + 1 ))
    fi
  done

  echo "$dispatched"
}

# scan_repo <repo>: scan all open PRs in a repo for rate-limited markers
scan_repo() {
  local repo="$1"
  echo "[retry] scanning ${repo}..."

  local prs_json
  prs_json=$(gh api --paginate "repos/${repo}/pulls?state=open&per_page=100" \
    --jq '[.[] | {number: .number, head_sha: .head.sha}]' 2>/dev/null || echo "[]")

  local pr_count
  pr_count=$(echo "$prs_json" | jq 'length')
  if [ "$pr_count" -eq 0 ]; then
    echo "  no open PRs in ${repo}"
    return 0
  fi

  echo "  found ${pr_count} open PR(s)"
  local total_dispatched=0

  while IFS= read -r pr_entry; do
    local pr_number
    pr_number=$(echo "$pr_entry" | jq -r '.number')
    local dispatched
    dispatched=$(scan_pr_for_rate_limits "$repo" "$pr_number")
    total_dispatched=$(( total_dispatched + dispatched ))
  done < <(echo "$prs_json" | jq -c '.[]')

  echo "  dispatched ${total_dispatched} retries from ${repo}"
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

main "$@"
