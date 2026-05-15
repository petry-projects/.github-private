#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-issue.sh — handles the issue intent

source "$(dirname "$0")/engine.sh"

ISSUE_NUMBER="${ISSUE_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"

check_existing_pr() {
  local existing
  existing=$(gh api "repos/${REPO}/pulls?state=open" \
    --jq "[.[] | select(.head.ref | startswith(\"dev-lead/issue-${ISSUE_NUMBER}\"))] | length" 2>/dev/null || echo "0")
  [ "$existing" -gt 0 ]
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
  envsubst < "prompts/dev-lead/fix-issue.md" > "$prompt_file"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] fix-issue: would implement issue #${ISSUE_NUMBER} using prompt: $prompt_file"
    rm -f "$prompt_file"
    exit 0
  fi

  # Create feature branch
  local branch="dev-lead/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M)"
  git checkout -b "$branch"

  if ! run_writer_with_fallback "$prompt_file"; then
    echo "::error::Engine failed to implement issue #${ISSUE_NUMBER}"
    rm -f "$prompt_file"
    exit 1
  fi

  if git diff --quiet && git diff --cached --quiet; then
    echo "::notice::No changes made for issue #${ISSUE_NUMBER}"
    rm -f "$prompt_file"
    exit 0
  fi

  git add -A
  git commit -m "feat: implement issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}"
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
