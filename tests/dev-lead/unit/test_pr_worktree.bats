#!/usr/bin/env bats
# Unit tests for scripts/lib/pr-worktree.sh
#
# Regression coverage for issue #448: checking out a PR branch must NOT remove
# the agent's own prompt/script files from the working tree. The library
# isolates the PR branch in a separate git worktree, so the agent checkout —
# and an absolute PROMPTS_DIR pinned to it — survives the branch switch.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/pr-worktree.sh"

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  # gh stub: `gh pr checkout <n>` switches the worktree to the PR branch,
  # mirroring the real command (which is what made the old prompt files vanish).
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr checkout") git checkout -q old ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"

  # Repo with a `main` branch that has prompts/x.md and an `old` branch that
  # predates it — the exact shape that broke run 27077585464.
  AGENT_REPO="$(mktemp -d)"
  git -C "$AGENT_REPO" init -q -b main
  git -C "$AGENT_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$AGENT_REPO" branch old
  mkdir -p "$AGENT_REPO/prompts"
  echo "PROMPT BODY" > "$AGENT_REPO/prompts/x.md"
  git -C "$AGENT_REPO" add prompts/x.md
  git -C "$AGENT_REPO" -c user.email=t@t -c user.name=t commit -q -m "add prompt"
}

teardown() {
  rm -rf "$STUB_BIN_DIR" "$AGENT_REPO"
}

@test "resolve_abs: leaves an absolute path unchanged" {
  source "$LIB"
  run resolve_abs /etc
  [ "$status" -eq 0 ]
  [ "$output" = "/etc" ]
}

@test "resolve_abs: converts an existing relative path to absolute" {
  source "$LIB"
  cd "$AGENT_REPO"
  run resolve_abs prompts
  [ "$status" -eq 0 ]
  [ "$output" = "$AGENT_REPO/prompts" ]
}

@test "resolve_abs: returns a non-existent path unchanged" {
  source "$LIB"
  run resolve_abs does/not/exist
  [ "$status" -eq 0 ]
  [ "$output" = "does/not/exist" ]
}

@test "checkout_pr_in_worktree: PR branch switch does not clobber the agent prompts" {
  source "$LIB"
  cd "$AGENT_REPO"
  # Pin PROMPTS_DIR before entering the worktree, as the real scripts do.
  local prompts; prompts="$(resolve_abs prompts)"

  checkout_pr_in_worktree 42 owner/repo

  # We are now inside the worktree, on the `old` branch where prompts/x.md
  # never existed — proving the branch switch really happened here.
  [ "$PWD" = "$PR_WORKTREE_DIR" ]
  [ ! -e "$PWD/prompts/x.md" ]

  # The agent checkout (and the absolute PROMPTS_DIR pointing at it) is intact:
  # this is the guarantee that issue #448 broke.
  [ -f "$prompts/x.md" ]
  [ "$(cat "$prompts/x.md")" = "PROMPT BODY" ]

  cleanup_pr_worktree
}

@test "cleanup_pr_worktree: removes the worktree and returns to the agent checkout" {
  source "$LIB"
  cd "$AGENT_REPO"

  checkout_pr_in_worktree 42 owner/repo
  local wt="$PR_WORKTREE_DIR"
  [ -d "$wt" ]

  cleanup_pr_worktree

  [ "$PWD" = "$AGENT_REPO" ]
  [ ! -d "$wt" ]
  [ -z "$PR_WORKTREE_DIR" ]
  # Registry no longer references the removed worktree.
  run git -C "$AGENT_REPO" worktree list
  [[ "$output" != *"$wt"* ]]
}

@test "cleanup_pr_worktree: is a no-op when no worktree is active" {
  source "$LIB"
  PR_WORKTREE_DIR=""
  run cleanup_pr_worktree
  [ "$status" -eq 0 ]
}
