#!/usr/bin/env bash
# auto-merge.sh — hold GitHub auto-merge while dev-lead works a PR, and push
# defensively so a PR that merges mid-run doesn't fail the job.
#
# Why
# ---
# dev-lead enables auto-merge (squash) by default on every PR it touches (#447).
# GitHub's auto-merge is asynchronous and is NOT gated by the workflow's
# concurrency lane, so a review approval landing while the agent is mid-edit can
# merge — and delete — the branch out from under the run, which then fails on
# push with:
#
#   ! [remote rejected] ... (cannot lock ref 'refs/heads/...':
#     unable to resolve reference 'refs/heads/...')
#
# (petry-projects/.github-private run 27078382804; issue #452.)
#
# Mitigation
# ----------
#  - hold_auto_merge        turns auto-merge OFF at the start of a modifying run
#                           so a mid-flight approval can't merge the branch.
#  - restore_auto_merge     (EXIT trap) puts auto-merge back exactly as it was,
#                           however the run exits (success, error, or timeout).
#  - push_with_merge_guard  treats "branch merged/closed mid-run" as a benign
#                           success instead of a hard, red-X failure.
#
# All functions read PR_NUMBER / REPO / DEV_LEAD_DRY_RUN from the environment.

# Set to 1 by hold_auto_merge only when it actually turned auto-merge off, so
# restore_auto_merge re-enables exactly what we disabled and nothing else (it
# must never newly enable auto-merge on a PR that never had it).
_AM_NEEDS_RESTORE=0

# hold_auto_merge — disable auto-merge for the duration of the run, if it is on.
hold_auto_merge() {
  [ -n "${PR_NUMBER:-}" ] || return 0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would hold auto-merge OFF on PR #${PR_NUMBER} while working"
    return 0
  fi
  local state
  state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge // empty' 2>/dev/null || true)
  [ -n "$state" ] || return 0   # already off — leave it alone
  echo "::notice::PR #${PR_NUMBER} — holding auto-merge OFF while dev-lead works"
  if gh pr merge "$PR_NUMBER" --repo "$REPO" --disable-auto 2>/dev/null; then
    _AM_NEEDS_RESTORE=1
  else
    echo "::warning::could not disable auto-merge on PR #${PR_NUMBER}"
  fi
}

# restore_auto_merge — EXIT-trap safety net: re-enable auto-merge iff
# hold_auto_merge disabled it and the PR is still open. Best-effort and
# idempotent; no-ops when the success path already re-enabled it.
restore_auto_merge() {
  [ "${_AM_NEEDS_RESTORE:-0}" = "1" ] || return 0
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would restore auto-merge on PR #${PR_NUMBER}"
    return 0
  fi
  local pr_state
  pr_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.state' 2>/dev/null || true)
  [ "$pr_state" = "open" ] || return 0   # merged/closed — nothing to restore
  local am
  am=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge // empty' 2>/dev/null || true)
  if [ -n "$am" ]; then return 0; fi     # success path already restored it
  echo "::notice::PR #${PR_NUMBER} — restoring auto-merge (squash)"
  gh pr merge "$PR_NUMBER" --repo "$REPO" --auto --squash 2>/dev/null \
    || echo "::warning::could not restore auto-merge on PR #${PR_NUMBER}"
}

# push_with_merge_guard [git push args...] — push the current branch, but exit 0
# cleanly when the push fails because the PR was merged/closed (its branch
# deleted) mid-run. Returns 0 on a real push; returns 1 on a genuine failure.
push_with_merge_guard() {
  local errf
  errf="$(mktemp)"
  if git push "$@" 2>"$errf"; then
    rm -f "$errf"
    return 0
  fi
  cat "$errf" >&2
  rm -f "$errf"

  # The PR merging out from under us is the expected benign race: GitHub closes
  # the PR (state != open) and deletes its branch, so our push can't lock the ref.
  local state
  state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.state' 2>/dev/null || true)
  if [ -n "$state" ] && [ "$state" != "open" ]; then
    echo "::notice::PR #${PR_NUMBER} is ${state} — its branch was merged/closed mid-run; nothing to push. Exiting cleanly."
    exit 0
  fi

  echo "::error::git push failed — check remote access and branch permissions" >&2
  return 1
}
