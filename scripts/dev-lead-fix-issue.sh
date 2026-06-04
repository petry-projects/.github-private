#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-issue.sh — handles the issue intent
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"

ISSUE_NUMBER="${ISSUE_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"

check_existing_pr() {
  local existing
  existing=$(gh api "repos/${REPO}/pulls?state=open" \
    --jq "[.[] | select(.head.ref | startswith(\"dev-lead/issue-${ISSUE_NUMBER}\"))] | length" 2>/dev/null || echo "0")
  [ "$existing" -gt 0 ]
}

setup_git_identity() {
  local bot="${BOT_USER:-donpetry-bot}"
  local bot_id
  bot_id=$(gh api "users/${bot}" --jq '.id' 2>/dev/null || echo "")
  if [ -n "$bot_id" ]; then
    git config user.email "${bot_id}+${bot}@users.noreply.github.com"
  else
    git config user.email "${bot}@users.noreply.github.com"
  fi
  git config user.name "$bot"
}

main() {
  if [ -z "$ISSUE_NUMBER" ]; then
    echo "::error::ISSUE_NUMBER is required"
    exit 1
  fi

  if check_existing_pr; then
    echo "::notice::Existing open PR found for issue #${ISSUE_NUMBER} — skipping (dedup)"
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "<!-- dev-lead-issue-dedup -->Already working on this: an open PR exists for issue #${ISSUE_NUMBER}." 2>/dev/null || true
    exit 0
  fi

  # Gather issue context
  export ISSUE_NUMBER ISSUE_URL="https://github.com/${REPO}/issues/${ISSUE_NUMBER}"
  export REPO
  ISSUE_TITLE=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.title' 2>/dev/null || echo "Unknown")
  ISSUE_BODY=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.body // ""' 2>/dev/null || echo "")
  ORG_STANDARDS_HINT="See AGENTS.md and docs/ for coding standards."
  export ISSUE_TITLE ISSUE_BODY ORG_STANDARDS_HINT

  local prompt_file="/tmp/dev-lead-fix-issue-prompt-$$.md"
  local template_path="${PROMPTS_DIR}/fix-issue.md"
  local vars_spec
  vars_spec=$(grep -m1 '<!-- VARIABLES:' "$template_path" 2>/dev/null \
    | sed 's/<!-- VARIABLES: //; s/ -->//' \
    | tr ',' '\n' \
    | awk '{gsub(/^ +| +$/, ""); if (length) printf "${%s}", $0}' || true)
  if [ -n "$vars_spec" ]; then
    envsubst "$vars_spec" < "$template_path" > "$prompt_file"
  else
    envsubst < "$template_path" > "$prompt_file"
  fi

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] fix-issue: would implement issue #${ISSUE_NUMBER} using prompt: $prompt_file"
    rm -f "$prompt_file"
    exit 0
  fi

  # Configure git identity so the post-engine commit does not fail.
  # BOT_USER is set as a job-level env var in dev-lead-reusable.yml.
  setup_git_identity

  # Create feature branch
  local branch
  branch="dev-lead/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M)"
  git checkout -b "$branch"
  local pre_engine_sha
  pre_engine_sha=$(git rev-parse HEAD)

  local engine_rc=0
  run_writer_with_fallback "$prompt_file" || engine_rc=$?
  if [ "$engine_rc" -eq 2 ]; then
    echo "::warning::All engines rate-limited — cannot implement issue #${ISSUE_NUMBER}; re-apply the label to retry"
    local reset_msg=""
    if [ -f /tmp/dev-lead-rate-limit-reset ]; then
      local reset_time
      reset_time=$(cat /tmp/dev-lead-rate-limit-reset)
      [ -n "$reset_time" ] && reset_msg=" The limit is expected to reset at ${reset_time}."
    fi
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "<!-- dev-lead-rate-limited -->All engines are currently rate-limited.${reset_msg} Please re-apply the \`dev-lead\` label when the rate limit clears to retry." 2>/dev/null || true
    rm -f "$prompt_file"
    exit 2
  elif [ "$engine_rc" -ne 0 ]; then
    echo "::error::Engine failed to implement issue #${ISSUE_NUMBER}"
    rm -f "$prompt_file"
    exit 1
  fi

  # git status --porcelain catches untracked files that git diff misses.
  # Compare HEAD to pre-engine SHA to detect commits the engine made via Bash.
  local has_uncommitted=false has_unpushed=false
  [ -n "$(git status --porcelain)" ] && has_uncommitted=true
  [ "$(git rev-parse HEAD)" != "$pre_engine_sha" ] && has_unpushed=true

  if ! $has_uncommitted && ! $has_unpushed; then
    echo "::notice::No changes made for issue #${ISSUE_NUMBER}"
    rm -f "$prompt_file"
    exit 0
  fi

  # Run lint before committing to prevent avoidable CI failures.
  # LINT_SCRIPT can be overridden in tests; defaults to sibling script.
  local _lint_script="${LINT_SCRIPT:-"$(dirname "$0")/dev-lead-lint.sh"}"
  local lint_rc=0
  local lint_output=""
  if [ -f "$_lint_script" ]; then
    lint_output=$(bash "$_lint_script" 2>&1) || lint_rc=$?
  fi

  if [ "$lint_rc" -ne 0 ]; then
    echo "::error::Lint check failed — aborting commit to prevent CI failure. Re-apply the dev-lead label after fixing lint errors."
    echo "$lint_output"
    local _lint_body
    _lint_body="<!-- dev-lead-lint-failed -->
## Dev-Lead: Lint Check Failed

The implementation for issue #${ISSUE_NUMBER} contained lint errors. The commit was **aborted** to prevent a CI failure.

\`\`\`
${lint_output}
\`\`\`

**To retry:** fix the lint errors locally (or re-apply the \`dev-lead\` label — the agent will try again)."
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$_lint_body" 2>/dev/null || true
    rm -f "$prompt_file"
    exit 1
  fi

  if $has_uncommitted; then
    git add -A
    git commit -m "feat: implement issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}"
  fi
  git push --set-upstream origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --title "feat: implement issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}" \
    --body "Closes #${ISSUE_NUMBER}

Implemented by dev-lead agent. Please review." \
    --head "$branch"

  rm -f "$prompt_file"
}

main "$@"
