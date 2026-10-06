#!/usr/bin/env bats
# Unit tests for scripts/lib/git-history.sh (#2053).
#
# dev-lead runs on a depth-1 actions/checkout. With only the tip of each ref
# present, a PR branch and its base share no visible ancestor, so a rebase sees
# "unrelated histories" and the conflict list is computed against nothing. The
# helper must make the merge base resolvable BEFORE anything reads it, and tell
# an un-deepenable remote (infrastructure failure) apart from histories that are
# genuinely unrelated. Every test uses a real local bare remote and a depth-1
# clone of it — no git stubs.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/git-history.sh"

_git() { git -c user.email="t@test" -c user.name="T" -c init.defaultBranch=main "$@"; }

setup() {
  # shellcheck source=scripts/lib/git-history.sh
  source "$LIB"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  SEED="$BATS_TEST_TMPDIR/seed"
  CLONE="$BATS_TEST_TMPDIR/clone"
  _git init -q --bare "$REMOTE"
  _git init -q "$SEED"
  # Shared history: a few commits so a depth-1 clone truncates real ancestry.
  printf 'line1\nline2\nline3\n' > "$SEED/conflict.txt"
  printf 'a\n' > "$SEED/other.txt"
  _git -C "$SEED" add .
  _git -C "$SEED" commit -qm "base 1"
  printf 'b\n' >> "$SEED/other.txt"
  _git -C "$SEED" commit -qam "base 2"
  _git -C "$SEED" remote add origin "file://$REMOTE"
  _git -C "$SEED" push -q origin main

  # PR branch: edits conflict.txt line2 and adds a file main never touches.
  _git -C "$SEED" checkout -qb feat
  printf 'line1\nfeat-change\nline3\n' > "$SEED/conflict.txt"
  printf 'feat\n' > "$SEED/feat-only.txt"
  _git -C "$SEED" add .
  _git -C "$SEED" commit -qm "feat: change line2"

  # main moves on: edits the same line, plus a non-conflicting file.
  _git -C "$SEED" checkout -q main
  printf 'line1\nmain-change\nline3\n' > "$SEED/conflict.txt"
  printf 'main\n' > "$SEED/main-only.txt"
  _git -C "$SEED" add .
  _git -C "$SEED" commit -qm "main: change line2"
  _git -C "$SEED" push -q origin main feat
}

# _shallow_clone: depth-1 clone of every branch (what actions/checkout leaves
# behind), with the PR branch checked out.
_shallow_clone() {
  _git clone -q --depth 1 --no-single-branch "file://$REMOTE" "$CLONE"
  _git -C "$CLONE" checkout -q feat
}

@test "depth-1 fixture: merge base is NOT resolvable before the helper runs" {
  _shallow_clone
  cd "$CLONE"
  [ "$(git rev-parse --is-shallow-repository)" = "true" ]
  run git merge-base HEAD origin/main
  [ "$status" -eq 1 ]
}

@test "git_ensure_merge_base: depth-1 clone → merge base resolves, conflict list is exactly the one file (AC6a)" {
  _shallow_clone
  cd "$CLONE"
  run git_ensure_merge_base main feat
  [ "$status" -eq 0 ]
  run git merge-base HEAD origin/main
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  # The same trial merge detect_conflicting_paths performs in the rebase arm.
  conflicts=$(_git merge --no-commit --no-ff origin/main >/dev/null 2>&1 || true
              git diff --name-only --diff-filter=U
              _git merge --abort >/dev/null 2>&1 || true)
  [ "$conflicts" = "conflict.txt" ]
  # Worktree left clean.
  [ -z "$(git status --porcelain)" ]
}

@test "git_ensure_merge_base: remote that cannot be deepened → rc 2, says history could not be deepened (AC6b)" {
  _shallow_clone
  cd "$CLONE"
  git remote set-url origin "file://$BATS_TEST_TMPDIR/gone.git"
  run git_ensure_merge_base main feat
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be deepened"* ]]
  # Never misreported as a conflict or as unrelated histories.
  [[ "$output" != *"unrelated"* ]]
  [[ "$output" != *"conflict"* ]]
}

@test "git_ensure_merge_base: unshallow refused → falls back to a deep fetch of both refs" {
  _shallow_clone
  cd "$CLONE"
  # Wrap git so `fetch --unshallow` fails; the deep-fetch fallback must recover.
  local bin="$BATS_TEST_TMPDIR/bin" real
  real="$(command -v git)"
  mkdir -p "$bin"
  cat > "$bin/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" --unshallow "*) exit 128 ;; esac
exec "$real" "\$@"
EOF
  chmod +x "$bin/git"
  PATH="$bin:$PATH" run git_ensure_merge_base main feat
  [ "$status" -eq 0 ]
  run git merge-base HEAD origin/main
  [ "$status" -eq 0 ]
}

@test "git_ensure_merge_base: complete but genuinely unrelated histories → rc 1 (not an infra failure)" {
  _git clone -q --no-single-branch "file://$REMOTE" "$CLONE"
  cd "$CLONE"
  _git checkout -q --orphan seed
  _git commit -qm "Initial commit"
  [ "$(git rev-parse --is-shallow-repository)" = "false" ]
  run git_ensure_merge_base main seed
  [ "$status" -eq 1 ]
}

@test "git_ensure_merge_base: base refresh fails with no merge base on complete history → rc 2, not unrelated" {
  _git clone -q --no-single-branch "file://$REMOTE" "$CLONE"
  cd "$CLONE"
  _git checkout -q --orphan seed
  _git commit -qm "Initial commit"
  local bin="$BATS_TEST_TMPDIR/bin" real
  real="$(command -v git)"
  mkdir -p "$bin"
  cat > "$bin/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *"refs/heads/main:refs/remotes/origin/main "*) exit 128 ;; esac
exec "$real" "\$@"
EOF
  chmod +x "$bin/git"
  PATH="$bin:$PATH" run git_ensure_merge_base main seed
  [ "$status" -eq 2 ]
  [[ "$output" != *"unrelated histories"* ]]
}

@test "git_ensure_merge_base: merge-base fatal error (not rc 1) → rc 2, not unrelated histories" {
  _shallow_clone
  cd "$CLONE"
  local bin="$BATS_TEST_TMPDIR/bin" real
  real="$(command -v git)"
  mkdir -p "$bin"
  cat > "$bin/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" merge-base "*) exit 128 ;; esac
exec "$real" "\$@"
EOF
  chmod +x "$bin/git"
  PATH="$bin:$PATH" run git_ensure_merge_base main feat
  [ "$status" -eq 2 ]
  [[ "$output" != *"unrelated"* ]]
}

@test "git_history_deepen: empty head_ref still deepens the checked-out HEAD" {
  _shallow_clone
  cd "$CLONE"
  local bin="$BATS_TEST_TMPDIR/bin" real
  real="$(command -v git)"
  mkdir -p "$bin"
  cat > "$bin/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" --unshallow "*) exit 128 ;; esac
exec "$real" "\$@"
EOF
  chmod +x "$bin/git"
  PATH="$bin:$PATH" run git_ensure_merge_base main
  [ "$status" -eq 0 ]
  run git merge-base HEAD origin/main
  [ "$status" -eq 0 ]
}

@test "git_ensure_merge_base: already-complete history → rc 0 without fetching deeper" {
  _git clone -q --no-single-branch "file://$REMOTE" "$CLONE"
  _git -C "$CLONE" checkout -q feat
  cd "$CLONE"
  run git_ensure_merge_base main feat
  [ "$status" -eq 0 ]
}

@test "git_ensure_merge_base: base fetch fails on a full clone → rc 2 (stale base is an infra failure, not a pass)" {
  _git clone -q --no-single-branch "file://$REMOTE" "$CLONE"
  _git -C "$CLONE" checkout -q feat
  cd "$CLONE"
  git remote set-url origin "file://$BATS_TEST_TMPDIR/gone.git"
  run git_ensure_merge_base main feat
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be refreshed"* ]]
}

@test "git_history_deepen: un-shallows a depth-1 clone; no-op on a full clone" {
  _shallow_clone
  cd "$CLONE"
  git_history_deepen main feat
  [ "$(git rev-parse --is-shallow-repository)" = "false" ]
  # Second call on a complete repo is a harmless no-op.
  run git_history_deepen main feat
  [ "$status" -eq 0 ]
}

@test "git_history_deepen: un-deepenable remote is best-effort (rc 0, no abort)" {
  _shallow_clone
  cd "$CLONE"
  git remote set-url origin "file://$BATS_TEST_TMPDIR/gone.git"
  run git_history_deepen main feat
  [ "$status" -eq 0 ]
}

@test "single helper: net-diff-guard and pr_nets_to_zero share git_history_deepen (AC2)" {
  # Only scripts/lib/git-history.sh may carry the un-shallow fetch itself.
  run grep -rlE -- 'git fetch[^#]*--unshallow' "$SCRIPT_DIR/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$SCRIPT_DIR/scripts/lib/git-history.sh" ]
  grep -q 'git_history_deepen' "$SCRIPT_DIR/scripts/lib/net-diff-guard.sh"
  grep -q 'git_history_deepen' "$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
}
