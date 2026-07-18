#!/usr/bin/env bash
# git-push-guard.sh — no-clobber push helper for dev-lead (#1311).
#
# dev-lead must never overwrite a commit it has not seen. A concurrent writer —
# a human pushing to the same branch, or the auto-rebase bot — can advance the
# remote head after dev-lead checked the branch out. push_no_clobber pushes so
# that such an unseen commit is never discarded:
#
#   1. Plain (fast-forward) push first — the common case. It can NEVER discard:
#      a non-fast-forward remote is rejected, not overwritten.
#   2. Retry with --force-with-lease ONLY when the local branch has DIVERGED
#      from its upstream (history was rewritten, e.g. a rebase). The lease is the
#      remote-tracking ref captured at checkout, so the force ABORTS if the
#      remote advanced beyond what we last fetched. We deliberately do NOT fetch
#      here — a fetch would refresh the lease and defeat the guard — and never
#      use a bare --force.
#   3. If the lease fails, the remote moved under us: refuse (return non-zero).
#      Discarding an unseen commit is never acceptable.
#
# Usage: push_no_clobber [git push args...]   e.g. push_no_clobber origin main

push_no_clobber() {
  local errf
  errf="$(mktemp)"

  if git push "$@" 2>"$errf"; then
    rm -f "$errf"
    return 0
  fi

  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)

  # Retry with --force-with-lease ONLY on a non-fast-forward rejection where our
  # branch has diverged from the upstream we last saw (rewritten history).
  # --force-with-lease (no explicit value) leases against the remote-tracking
  # ref, so it still ABORTS if the remote advanced beyond that ref.
  if grep -qiE 'non-fast-forward|\[rejected\]|fetch first' "$errf" \
     && [ -n "$upstream" ] \
     && ! git merge-base --is-ancestor "$upstream" HEAD 2>/dev/null; then
    echo "::notice::push rejected (non-fast-forward) and HEAD diverged from ${upstream} — history was rewritten (likely a rebase); retrying with --force-with-lease (aborts if the remote moved under us)" >&2
    if git push --force-with-lease "$@" 2>>"$errf"; then
      rm -f "$errf"
      return 0
    fi
    cat "$errf" >&2
    rm -f "$errf"
    echo "::error::--force-with-lease refused: the remote branch advanced beyond the commit dev-lead checked out. Refusing to discard an unseen commit." >&2
    return 1
  fi

  cat "$errf" >&2
  rm -f "$errf"
  echo "::error::git push failed — the remote head moved (a commit dev-lead never fetched) or access was denied; not overwriting." >&2
  return 1
}
