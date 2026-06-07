#!/usr/bin/env bash
# pr-worktree.sh — check out a PR branch in an isolated git worktree.
#
# Why this exists
# ---------------
# dev-lead's prompt templates (prompts/dev-lead/*.md) and helper scripts
# (scripts/*) live in the SAME repository the agent operates on. The previous
# approach ran `gh pr checkout` in place, switching the agent's working tree to
# the PR branch. When that branch predated a prompt/script file, the file
# vanished mid-run, e.g.:
#
#   scripts/dev-lead-fix-reviews.sh: line 51:
#     prompts/dev-lead/on-mention.md: No such file or directory
#
# (See petry-projects/.github-private run 27077585464 and issue #448.)
#
# A worktree gives the PR branch its own directory, so the agent checkout — and
# everything under it — stays on the agent ref while the engine edits the PR.
#
# Usage
# -----
#   source "$(dirname "$0")/lib/pr-worktree.sh"
#   PROMPTS_DIR="$(resolve_abs "$PROMPTS_DIR")"   # pin BEFORE entering worktree
#   checkout_pr_in_worktree "$PR_NUMBER" "$REPO"  # cds into the worktree
#   ... run engine, commit, push (now operating on the PR branch) ...
#   # the worktree is removed automatically on exit (EXIT trap)
#
# IMPORTANT: resolve any path the agent reads after checkout (PROMPTS_DIR, and
# anything else relative to the original CWD) to an absolute path with
# resolve_abs BEFORE calling checkout_pr_in_worktree — the cd changes what
# relative paths resolve to.

# resolve_abs <path> — echo an absolute form of <path> when it exists, else the
# original string unchanged. Used to pin PROMPTS_DIR before we cd elsewhere.
resolve_abs() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  ( cd "$1" 2>/dev/null && pwd ) || printf '%s\n' "$1" ;;
  esac
}

# Directory of the active PR worktree (empty when none). Tracked so the EXIT
# trap can tear it down, and so the cleanup is idempotent.
PR_WORKTREE_DIR=""
# The agent checkout to return to during cleanup; captured at checkout time.
PR_WORKTREE_AGENT_DIR=""

# checkout_pr_in_worktree <pr_number> <repo>
#   Creates a temp worktree, checks the PR out inside it, and cds into it.
#   Registers an EXIT trap that removes the worktree.
checkout_pr_in_worktree() {
  local pr="$1" repo="$2"

  PR_WORKTREE_AGENT_DIR="$(pwd)"

  # mktemp -d gives us a private parent dir; the worktree leaf must NOT pre-exist
  # because `git worktree add` refuses a populated target directory.
  local parent
  parent="$(mktemp -d "${TMPDIR:-/tmp}/dev-lead-wt-XXXXXX")"
  PR_WORKTREE_DIR="${parent}/pr-${pr}"

  # Tear the worktree down on exit (success or failure) so /tmp and the repo's
  # worktree registry don't accumulate stale entries across runs. Chain onto any
  # EXIT trap the caller already registered (e.g. restore_auto_merge) instead of
  # clobbering it — the trap commands dev-lead registers are bare function names.
  local _prev_exit
  _prev_exit="$(trap -p EXIT | sed -n -E "s/^trap -- '(.*)' (EXIT|0)\$/\1/p")"
  # Deliberately expand $_prev_exit now to bake the captured prior trap into the
  # new handler; it is gone by the time the trap fires.
  # shellcheck disable=SC2064
  trap "cleanup_pr_worktree${_prev_exit:+; $_prev_exit}" EXIT

  # Start detached at the agent checkout's HEAD so `gh pr checkout` can create or
  # switch to the PR branch inside the worktree without colliding with whatever
  # branch the agent checkout already has out.
  git worktree add --detach "$PR_WORKTREE_DIR" HEAD >/dev/null

  cd "$PR_WORKTREE_DIR" || return 1
  gh pr checkout "$pr" --repo "$repo"
}

# cleanup_pr_worktree — return to the agent checkout and remove the worktree.
# Idempotent and safe to call from an EXIT trap or by hand.
cleanup_pr_worktree() {
  [ -n "${PR_WORKTREE_DIR:-}" ] || return 0
  local wt="$PR_WORKTREE_DIR" parent
  parent="$(dirname "$wt")"
  PR_WORKTREE_DIR=""

  cd "${PR_WORKTREE_AGENT_DIR:-/}" 2>/dev/null || true
  git worktree remove --force "$wt" 2>/dev/null || true
  # Best-effort: drop the mktemp parent and prune any dangling registry entry.
  if [ -n "$parent" ] && [ "$parent" != "/" ] && [[ "$parent" == *"/dev-lead-wt-"* ]]; then
    rm -rf "$parent" 2>/dev/null || true
  fi
  git worktree prune 2>/dev/null || true
}
