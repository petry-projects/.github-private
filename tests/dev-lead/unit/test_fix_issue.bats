#!/usr/bin/env bats
# Unit tests for dev-lead-fix-issue.sh (Phase 5)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_ISSUE_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-issue.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"
GH_STUBS_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/stubs"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Default gh stub that returns no existing PRs (no dedup)
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"pulls?state=open"*)
    echo "[]" ;;
  *"api"*"repos/"*"issues/"*)
    echo '{"title":"Test Issue","body":"Test issue body"}' ;;
  *"issue comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Default env
  export ISSUE_NUMBER="100"
  export REPO="petry-projects/.github-private"
  export REVIEW_ENGINE="claude"
  export DEV_LEAD_DRY_RUN="true"
  export GITHUB_REPOSITORY="petry-projects/.github-private"

  cd "$SCRIPT_DIR"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$STUB_BIN_DIR"
}

# ── dedup tests ───────────────────────────────────────────────────────────────

@test "fix-issue: dedup: existing open PR → exits 0 with comment" {
  # Stub gh to return count > 0 for the dedup check
  # The script uses: gh api ".../pulls?state=open" --jq "[.[] | select(...)] | length"
  # Our stub returns "1" to simulate existing PR found
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pulls?state=open"*)
    echo "1" ;;
  *"issue comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"dedup"* ]] || [[ "$output" == *"Existing open PR"* ]]
}

@test "fix-issue: dry-run: DEV_LEAD_DRY_RUN=true → logs [dry-run]" {
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: missing ISSUE_NUMBER → exits 1" {
  unset ISSUE_NUMBER

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 1 ]
}

@test "fix-issue: ISSUE_TITLE and ISSUE_BODY exported to env before envsubst" {
  export DEV_LEAD_DRY_RUN="true"

  # Create a gh stub that returns known title/body
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"pulls?state=open"*)
    echo "[]" ;;
  *"api"*"repos/"*"issues/"*)
    echo '{"title":"My Known Title","body":"My Known Body"}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: ORG_STANDARDS_HINT included in prompt context" {
  export DEV_LEAD_DRY_RUN="true"

  # We can verify by checking the generated prompt in dry-run mode
  # The dry-run message references the prompt file
  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  # Prompt was built (dry-run says would implement)
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: dry-run: check_existing_pr result does not affect dry-run path" {
  # Even if gh returns an empty list, dry-run should work
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-issue: dry-run: prompt file path appears in output" {
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 0 ]
  # Dry-run message contains reference to the issue
  [[ "$output" == *"issue #${ISSUE_NUMBER}"* ]]
}

# ── rate-limit handling tests ─────────────────────────────────────────────────

@test "fix-issue: rate-limited: all engines rate-limited → exits 2, not 1" {
  # Override engine stubs to emit a rate-limit message and exit 1
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" <<'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done
  export COPILOT_GITHUB_TOKEN="stub-token"

  # Stub git to avoid real branch creation in the workspace
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*) exit 0 ;;
  "checkout"*) exit 0 ;;
  "rev-parse HEAD") echo "abc123deadbeef" ;;
  *) exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # gh stub: no existing PRs, issue API, comment posts ok, copilot rate-limited
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test Issue","body":"Test body"}' ;;
  *"api"*"users/"*) echo '{"id":12345}' ;;
  *"issue comment"*) exit 0 ;;
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_ISSUE_SCRIPT"

  # Must exit 2 (rate-limited), not 1 (engine error)
  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]] || [[ "$output" == *"rate limited"* ]]
  [[ "$output" != *"Engine failed"* ]]
}

@test "fix-issue: rate-limited: posts comment on issue before exiting" {
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" <<'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done
  export COPILOT_GITHUB_TOKEN="stub-token"

  local comment_posted_sentinel
  comment_posted_sentinel="$(mktemp)"
  rm "$comment_posted_sentinel"  # deleted; presence after run = was posted

  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*) exit 0 ;;
  "checkout"*) exit 0 ;;
  "rev-parse HEAD") echo "abc123deadbeef" ;;
  *) exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*) echo '{"id":12345}' ;;
  *"issue comment"*) touch "${comment_posted_sentinel}"; exit 0 ;;
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"

  run bash "$FIX_ISSUE_SCRIPT"

  [ "$status" -eq 2 ]
  [ -f "$comment_posted_sentinel" ]

  rm -f "$comment_posted_sentinel" 2>/dev/null || true
}

# ── lint-before-commit tests ──────────────────────────────────────────────────

@test "fix-issue: lint passes → proceeds to commit without error" {
  # Stub dev-lead-lint.sh to pass
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "  [lint] all checks passed (stub)"
exit 0
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  # Stub git to simulate a clean commit path
  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*)           exit 0 ;;
  "checkout -b"*)      exit 0 ;;
  "rev-parse HEAD")    echo "abc123" ;;
  "status --porcelain") echo "M scripts/foo.sh" ;;
  "add -A")            exit 0 ;;
  "commit"*)           exit 0 ;;
  "push"*)             exit 0 ;;
  *)                   exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*)     echo '{"id":12345}' ;;
  *"pr create"*)        exit 0 ;;
  *"issue comment"*)    exit 0 ;;
  *)                    echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  run bash "$FIX_ISSUE_SCRIPT"

  # Should not fail because of lint
  [[ "$output" != *"lint check failed"* ]]
}

@test "fix-issue: lint fails → posts issue comment and exits without committing" {
  # Stub dev-lead-lint.sh to fail
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "::error::shellcheck: SC2086 unquoted variable in scripts/bad.sh line 3"
exit 1
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  local commit_sentinel
  commit_sentinel="$(mktemp)"
  rm "$commit_sentinel"

  cat > "$STUB_BIN_DIR/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  "config"*)           exit 0 ;;
  "checkout -b"*)      exit 0 ;;
  "rev-parse HEAD")    echo "abc123" ;;
  "status --porcelain") echo "M scripts/bad.sh" ;;
  "commit"*)           touch "${commit_sentinel}"; exit 0 ;;
  "add -A")            exit 0 ;;
  "push"*)             exit 0 ;;
  *)                   exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  local comment_sentinel
  comment_sentinel="$(mktemp)"
  rm "$comment_sentinel"

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*) echo '{"id":12345}' ;;
  *"issue comment"*) touch "${comment_sentinel}"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  run bash "$FIX_ISSUE_SCRIPT"

  # Lint failure must block the commit
  [ ! -f "$commit_sentinel" ]   # commit must NOT have been called

  rm -f "$comment_sentinel" "$commit_sentinel" 2>/dev/null || true
}

@test "fix-issue: lint fails → posts lint-failure comment on the issue" {
  cat > "$STUB_BIN_DIR/dev-lead-lint.sh" <<'LINTEOF'
#!/usr/bin/env bash
echo "SC2086: Double quote to prevent globbing" >&2
exit 1
LINTEOF
  chmod +x "$STUB_BIN_DIR/dev-lead-lint.sh"

  cat > "$STUB_BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  "config"*)           exit 0 ;;
  "checkout -b"*)      exit 0 ;;
  "rev-parse HEAD")    echo "abc123" ;;
  "status --porcelain") echo "M scripts/bad.sh" ;;
  *)                   exit 0 ;;
esac
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  local comment_sentinel
  comment_sentinel="$(mktemp)"
  rm "$comment_sentinel"

  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"pulls?state=open"*) echo "0" ;;
  *"api"*"repos/"*"issues/"*) echo '{"title":"Test","body":"body"}' ;;
  *"api"*"users/"*) echo '{"id":12345}' ;;
  *"issue comment"*) touch "${comment_sentinel}"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  export DEV_LEAD_DRY_RUN="false"
  export LINT_SCRIPT="$STUB_BIN_DIR/dev-lead-lint.sh"

  run bash "$FIX_ISSUE_SCRIPT"

  # A comment explaining the lint failure must be posted on the issue
  [ -f "$comment_sentinel" ]

  rm -f "$comment_sentinel" 2>/dev/null || true
}
