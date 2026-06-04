#!/usr/bin/env bash
# git-identity.sh — shared helper for dev-lead scripts.
#
# All dev-lead entry points (fix-issue, fix-ci, fix-reviews) must call
# setup_git_identity before any git commit. Without it, the runner has
# no user.name/user.email and `git commit` aborts with:
#   fatal: empty ident name (for <(null)>) not allowed
#
# Background: prior to centralizing this helper, only dev-lead-fix-issue.sh
# called the local setup_git_identity defined inline. fix-ci and fix-reviews
# silently committed under runner-default identity, which on GitHub-hosted
# runners is unset — causing the commit step to error and the agent run to
# fail. See bmad-bgreat-suite PR #203 dev-lead failures (2026-05-23) for the
# observed symptom.

# setup_git_identity — configure git user.name/user.email for the bot user.
#
# GitHub-hosted runners lack git identity by default; this helper ensures
# commits succeed whether we're committing to the primary repo or secondary checkouts.
#
# BOT_USER env var (default: donpetry-bot) determines the identity. The
# canonical noreply form (<id>+<login>@users.noreply.github.com) is preferred
# because it links commits to the bot's GitHub profile; fall back to the
# legacy form when the GitHub user API is unreachable.
setup_git_identity() {
  local bot="${BOT_USER:-donpetry-bot}"
  local bot_id
  bot_id=$(gh api "users/${bot}" --jq '.id' 2>/dev/null || echo "")
  if [[ -n $bot_id ]]; then
    git config user.email "${bot_id}+${bot}@users.noreply.github.com"
  else
    git config user.email "${bot}@users.noreply.github.com"
  fi
  git config user.name "$bot"
}
