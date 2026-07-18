#!/usr/bin/env bats
# Unit tests for scripts/lib/git-push-guard.sh :: push_no_clobber (#1311).
#
# Defense-in-depth for the concurrent-writer race: after dev-lead's agent runs,
# the push must never discard a commit dev-lead did not fetch. A plain
# fast-forward push can only ever be REJECTED (never overwrites); a rewritten
# (rebased) branch is retried with --force-with-lease, which ABORTS if the
# remote advanced beyond the last-seen remote-tracking ref. A bare --force is
# never used.

setup() {
  GUARD_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/git-push-guard.sh"

  TMP_ROOT="$(mktemp -d)"
  REMOTE="$TMP_ROOT/remote.git"
  WORK="$TMP_ROOT/work"

  # Bare remote seeded with commit A on `main`.
  git init -q --bare "$REMOTE"
  local seed="$TMP_ROOT/seed"
  git init -q "$seed"
  (
    cd "$seed"
    git config user.email t@t.co; git config user.name t
    echo A > f; git add f; git commit -q -m A
    git branch -M main
    git remote add origin "$REMOTE"
    git push -q -u origin main
  )
  # Point the bare remote's HEAD at main so fresh clones check it out.
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

  # dev-lead's working checkout (origin/main tracked, last seen = A).
  git clone -q "$REMOTE" "$WORK"
  ( cd "$WORK"; git config user.email t@t.co; git config user.name t )
}

teardown() {
  rm -rf "$TMP_ROOT"
}

# Advance the remote's `main` from an independent clone (a concurrent writer)
# WITHOUT updating $WORK's remote-tracking ref — simulates an unseen commit.
_advance_remote() {
  local other="$TMP_ROOT/other"
  git clone -q "$REMOTE" "$other"
  (
    cd "$other"
    git config user.email o@o.co; git config user.name o
    echo C >> f; git add f; git commit -q -m C
    git push -q origin main
  )
}

_remote_head() { git --git-dir="$REMOTE" rev-parse main; }

@test "push_no_clobber: fast-forward push succeeds and updates the remote" {
  cd "$WORK"
  source "$GUARD_LIB"
  echo B >> f; git add f; git commit -q -m B
  local local_head; local_head=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$local_head" ]
}

@test "push_no_clobber: rewritten branch pushes with lease when remote is unchanged" {
  cd "$WORK"
  source "$GUARD_LIB"
  # Rewrite history (rebase-like) so the branch diverges from origin/main.
  echo A2 > f; git add f; git commit -q --amend -m A2
  local local_head; local_head=$(git rev-parse HEAD)

  run push_no_clobber origin main
  [ "$status" -eq 0 ]
  [ "$(_remote_head)" = "$local_head" ]
}

@test "push_no_clobber: rewritten branch ABORTS when the remote moved under us — unseen commit survives" {
  cd "$WORK"
  source "$GUARD_LIB"
  # dev-lead rewrites its branch...
  echo A2 > f; git add f; git commit -q --amend -m A2
  # ...but meanwhile a concurrent writer advanced the remote to an unseen commit.
  _advance_remote
  local unseen; unseen=$(_remote_head)

  run push_no_clobber origin main
  [ "$status" -ne 0 ]
  # The unseen commit is preserved — dev-lead did NOT force over it.
  [ "$(_remote_head)" = "$unseen" ]
}

@test "push_no_clobber: non-fast-forward without divergence is refused (no force), remote preserved" {
  cd "$WORK"
  source "$GUARD_LIB"
  # dev-lead adds a commit on top (no rewrite)...
  echo B >> f; git add f; git commit -q -m B
  # ...but the remote advanced to an unseen commit.
  _advance_remote
  local unseen; unseen=$(_remote_head)

  run push_no_clobber origin main
  [ "$status" -ne 0 ]
  [ "$(_remote_head)" = "$unseen" ]
}

@test "push_no_clobber: never invokes a bare --force" {
  # A bare --force would defeat the lease guard entirely. Every force on a
  # `git push` command in the lib must be --force-with-lease. (Scoped to git push
  # invocations so prose in comments does not trip the check.)
  local bare
  bare=$(grep -nE 'git push[^|&]*--force([^-]|$)' "$GUARD_LIB" | grep -v -- '--force-with-lease' || true)
  [ -z "$bare" ]
}
