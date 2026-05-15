#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-ci.sh — handles the fix-ci intent
# Called when a CI check fails on a PR.
# Env: PR_NUMBER, HEAD_SHA, CHECKS_JSON, REPO, GITHUB_REPOSITORY,
#      DEV_LEAD_DRY_RUN, REVIEW_ENGINE, GH_TOKEN
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"
source "$(dirname "$0")/lib/git-identity.sh"
source "$(dirname "$0")/lib/pr-worktree.sh"
source "$(dirname "$0")/lib/auto-merge.sh"

PR_NUMBER="${PR_NUMBER:-}"
HEAD_SHA="${HEAD_SHA:-}"
CHECKS_JSON="${CHECKS_JSON:-[]}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
MAX_CI_CYCLES="${MAX_CI_CYCLES:-3}"
LOG_MAX_LINES="${LOG_MAX_LINES:-200}"
MARKER_PREFIX="<!-- dev-lead-fix-ci sha="
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"

check_idempotency() {
  local existing
  existing=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq "[.[] | select(.body | startswith(\"${MARKER_PREFIX}${HEAD_SHA}\"))] | length" 2>/dev/null || echo "0")
  [ "$existing" -gt 0 ]
}

collect_logs() {
  local check_name="$1" details_url="$2"
  # Try to get run ID from details URL
  local run_id
  run_id=$(echo "$details_url" | grep -oP '(?<=runs/)\d+' || true)
  if [ -n "$run_id" ]; then
    gh run view "$run_id" --log-failed 2>/dev/null | tail -n "$LOG_MAX_LINES" || true
  else
    echo "# No run logs available for check: $check_name"
  fi
}

build_prompt() {
  local prompt_template="${PROMPTS_DIR}/fix-ci.md"
  local check_name app_slug details_url
  check_name=$(echo "$CHECKS_JSON" | jq -r '.[0].name // "unknown"')
  app_slug=$(echo "$CHECKS_JSON" | jq -r '.[0].app_slug // "github-actions"')
  details_url=$(echo "$CHECKS_JSON" | jq -r '.[0].details_url // ""')

  export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
  export CHECK_NAME="$check_name" APP_SLUG="$app_slug"
  export HEAD_SHA DETAILS_URL="$details_url"
  export REPO

  FAILURE_LOGS=$(collect_logs "$check_name" "$details_url")
  ANNOTATIONS=$(gh api "repos/${REPO}/check-runs/$(echo "$CHECKS_JSON" | jq -r '.[0].id // empty')/annotations?per_page=100" 2>/dev/null | jq -c '.' || echo "[]")
  export FAILURE_LOGS ANNOTATIONS

  local rendered="/tmp/dev-lead-fix-ci-prompt-$$.md"
  envsubst < "$prompt_template" > "$rendered"
  echo "$rendered"
}

post_summary() {
  local status="$1" details="${2:-}"
  local marker="${MARKER_PREFIX}${HEAD_SHA} status=${status} -->"
  local body="${marker}
## Dev-Lead Fix CI — ${status}
**PR:** #${PR_NUMBER} | **SHA:** \`${HEAD_SHA}\`
${details}"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would post PR comment:"
    echo "$body"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
  fi
}

post_exhaustion() {
  local reason="$1"
  local body="${EXHAUSTION_MARKER}
## Dev-Lead Fix CI — exhausted

This PR has had **${MAX_FAIL_ATTEMPTS}** consecutive engine failures (timeouts or errors). Automated CI fixing has been paused to avoid consuming further tokens.

**Reason for last failure:** ${reason}

To re-enable, delete this comment or push a new commit with a substantially different change."
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would post exhaustion comment"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
  fi
}

main() {
  if [ -z "$PR_NUMBER" ] || [ -z "$HEAD_SHA" ]; then
    echo "::error::PR_NUMBER and HEAD_SHA are required"
    exit 1
  fi

  # Hold auto-merge OFF while we work so a review approval landing mid-run can't
  # merge (and delete) the branch out from under us. Install the trap and hold
  # before check_idempotency so an approval landing during the API/JQ scan can't
  # merge the branch before the trap is in place. restore_auto_merge is
  # idempotent (_AM_NEEDS_RESTORE guards it), so the EXIT trap no-ops cleanly
  # when check_idempotency causes an early exit with nothing to restore.
  # checkout_pr_in_worktree chains its own cleanup onto this trap.
  trap restore_auto_merge EXIT
  hold_auto_merge

  if check_idempotency; then
    echo "::notice::Already handled CI failure at SHA $HEAD_SHA — skipping (idempotent)"
    exit 0
  fi

  local prompt_file
  prompt_file=$(build_prompt)

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] fix-ci: would run engine with prompt: $prompt_file"
    post_summary "dry-run" "Would apply fix for: $(echo "$CHECKS_JSON" | jq -r '[.[].name] | join(", ")')"
    exit 0
  fi

  # Checkout the PR branch for modification
  gh pr checkout "$PR_NUMBER" --repo "$REPO"

  local cycle=1
  while [ "$cycle" -le "$MAX_CI_CYCLES" ]; do
    echo "  [fix-ci] cycle $cycle/$MAX_CI_CYCLES"

    if ! run_writer_with_fallback "$prompt_file"; then
      post_summary "failed" "Engine invocation failed after all retries."
      exit 1
    fi

    # Check if there are changes to commit
    if git diff --quiet && git diff --cached --quiet; then
      echo "  [fix-ci] no changes made by engine"
      post_summary "no-changes" "Engine ran but made no changes."
      exit 0
    fi

    if $has_uncommitted; then
      # GitHub-hosted runners have no default git identity; configure it
      # before committing or commit fails with "fatal: empty ident name".
      setup_git_identity
      git add -A
      git commit -m "fix(ci): auto-fix for $(echo "$CHECKS_JSON" | jq -r '.[0].name // "CI failure"') [skip ci-relay]"
    fi
    # push_with_merge_guard exits 0 cleanly if the PR was merged/closed mid-run
    # (its branch deleted); a genuine push failure still aborts with exit 1.
    push_with_merge_guard || exit 1

    post_summary "applied" "Fix committed and pushed. Waiting for CI."
    break
  done

  rm -f "$prompt_file"
}

main "$@"
