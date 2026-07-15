#!/usr/bin/env bats
# Regression tests for the rolling-branch push in scripts/aw-readme-refresh.sh.
#
# The weekly refresh resets `chore/readme-refresh` to main + freshly generated
# READMEs and pushes it with `--force-with-lease`. Because ~5 min of Claude
# generation elapse between clone and push, an auto-merge of the *previous*
# refresh PR can move or delete the branch mid-run, staling the lease and
# producing a "stale info" rejection (the #1265 failure). `push_branch_with_retry`
# must recover by re-syncing (`fetch --prune`) and retrying — for both the
# branch-MOVED and branch-DELETED races — and must return non-zero only on a
# genuinely persistent failure.
#
# Run: bats tests/test_readme_refresh_push.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/aw-readme-refresh.sh"

setup() {
  # Extract only push_branch_with_retry; the script's main body needs live env.
  eval "$(awk '
    /^push_branch_with_retry\(\)/ { f=1 }
    f                             { print }
    f && /^\}$/                   { f=0 }
  ' "$SCRIPT")"

  # Stubs for the logging helpers the function calls, and fast retries.
  warn() { echo "warn: $*" >&2; }
  export PUSH_RETRY_ATTEMPTS=3
  export PUSH_RETRY_SLEEP_SEC=0

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  RUN="$BATS_TEST_TMPDIR/run"
  git init -q --bare "$REMOTE"

  # Seed main, then a v1 rolling branch on the remote.
  local seed="$BATS_TEST_TMPDIR/seed"
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m init
  git -C "$seed" push -q "$REMOTE" main
  git -C "$seed" checkout -q -B chore/readme-refresh
  git -C "$seed" commit -q --allow-empty -m "rolling v1"
  git -C "$seed" push -q "$REMOTE" chore/readme-refresh

  # The workflow's per-run clone: reset the rolling branch to main + fresh READMEs.
  # origin/chore/readme-refresh is captured here and goes stale once the remote moves.
  git clone -q "$REMOTE" "$RUN"
  git -C "$RUN" checkout -q main
  git -C "$RUN" checkout -q -B chore/readme-refresh
  echo "fresh readme" > "$RUN/README.md"
  git -C "$RUN" add -A
  git -C "$RUN" commit -q -m "docs: refresh"
}

# Advance the remote rolling branch out from under the run (auto-merge of prior PR).
_move_remote_branch() {
  local w="$BATS_TEST_TMPDIR/mover"
  git clone -q "$REMOTE" "$w"
  git -C "$w" checkout -q chore/readme-refresh
  git -C "$w" commit -q --allow-empty -m "rolling v2 (moved)"
  git -C "$w" push -q "$REMOTE" chore/readme-refresh
}

_delete_remote_branch() {
  local w="$BATS_TEST_TMPDIR/deleter"
  git clone -q "$REMOTE" "$w"
  git -C "$w" push -q "$REMOTE" --delete chore/readme-refresh
}

@test "push_branch_with_retry: clean first push succeeds" {
  run push_branch_with_retry "$RUN" "chore/readme-refresh" "org/repo"
  [ "$status" -eq 0 ]
}

@test "push_branch_with_retry: recovers from stale lease when branch MOVED mid-run" {
  _move_remote_branch
  run push_branch_with_retry "$RUN" "chore/readme-refresh" "org/repo"
  [ "$status" -eq 0 ]
  # The move must actually have staled the first attempt (retry path exercised).
  [[ "$output" == *"push to chore/readme-refresh failed (attempt 1/3)"* ]]
  # Remote now carries the run's fresh content.
  git clone -q "$REMOTE" "$BATS_TEST_TMPDIR/verify"
  git -C "$BATS_TEST_TMPDIR/verify" checkout -q chore/readme-refresh
  [ "$(cat "$BATS_TEST_TMPDIR/verify/README.md")" = "fresh readme" ]
}

@test "push_branch_with_retry: recovers from stale lease when branch DELETED mid-run" {
  _delete_remote_branch
  run push_branch_with_retry "$RUN" "chore/readme-refresh" "org/repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"push to chore/readme-refresh failed (attempt 1/3)"* ]]
  git clone -q "$REMOTE" "$BATS_TEST_TMPDIR/verify"
  git -C "$BATS_TEST_TMPDIR/verify" checkout -q chore/readme-refresh
  [ "$(cat "$BATS_TEST_TMPDIR/verify/README.md")" = "fresh readme" ]
}

@test "push_branch_with_retry: returns non-zero after exhausting attempts on a persistent failure" {
  # Point origin at an unreachable remote so every push (and fetch) fails.
  git -C "$RUN" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  run push_branch_with_retry "$RUN" "chore/readme-refresh" "org/repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"(attempt 3/3)"* ]]
}
