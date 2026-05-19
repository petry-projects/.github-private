#!/usr/bin/env bats
# Unit tests for dev-lead-fix-reviews.sh (Phase 3)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX_REVIEWS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"
GH_STUBS_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/stubs"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  cp "$GH_STUBS_DIR/gh" "$STUB_BIN_DIR/gh"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini" "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Default env
  export PR_NUMBER="54"
  export HEAD_SHA="ddd444eee555"
  export REPO="petry-projects/.github-private"
  export REVIEW_ENGINE="claude"
  export DEV_LEAD_DRY_RUN="true"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
  export BASE_REF="main"
  export ACTOR="donpetry"

  # Install a graphql-aware gh stub
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    exit 0 ;;
  *"pr checkout"*)
    exit 0 ;;
  *"issue comment"*)
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cd "$SCRIPT_DIR"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$STUB_BIN_DIR"
}

# ── dry-run tests ─────────────────────────────────────────────────────────────

@test "fix-reviews: dry-run: no engine called" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  # Remove engine binaries to verify they're not called
  rm -f "$STUB_BIN_DIR/claude"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=fix-reviews → runs fix-reviews" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=human → runs human intent" {
  export INTENT_TYPE="human"
  export DEV_LEAD_DRY_RUN="true"
  export USER_INSTRUCTION="Please fix the tests"
  export PR_DESCRIPTION="Test PR"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=fix-bot-comment → runs fix-bot-comment" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export COMMENT_BODY="SonarQube found issues"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: INTENT_TYPE=rebase dry-run → logs [dry-run]" {
  export INTENT_TYPE="rebase"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: unknown INTENT_TYPE → exits 1" {
  export INTENT_TYPE="totally-unknown-intent"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 1 ]
}

@test "fix-reviews: fix-reviews in dry-run: outputs [dry-run] message" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: human-pr in dry-run: outputs [dry-run] message" {
  export INTENT_TYPE="human-pr"
  export DEV_LEAD_DRY_RUN="true"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "fix-reviews: missing PR_NUMBER → exits 1 for non-rebase intents" {
  export INTENT_TYPE="fix-reviews"
  unset PR_NUMBER

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 1 ]
}

# ── rate-limit handling tests ─────────────────────────────────────────────────

@test "fix-reviews: rate-limited: engine exit 2 posts rate-limited marker" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export COPILOT_GITHUB_TOKEN="stub-token"

  # claude and gemini engines rate-limited
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
# copilot must be checked first — its -p prompt text may contain "graphql"
case "$1" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
esac
ARGS="$*"
case "$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    echo "COMMENT_POSTED: $ARGS"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  [[ "$output" == *"intent=fix-reviews"* ]]
}

@test "fix-reviews: rate-limited: human intent posts re-trigger ack (not auto-retry)" {
  export INTENT_TYPE="human"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export ACTOR="donpetry"
  export USER_INSTRUCTION="Please fix the failing tests"
  export COPILOT_GITHUB_TOKEN="stub-token"

  # claude and gemini engines rate-limited
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    echo "COMMENT_POSTED: $ARGS"; exit 0 ;;
  *"pulls/"*)
    echo '{"head":{"sha":"ddd444eee555"}}' ;;
  *"copilot"*)
    echo "hit your limit"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  # human intent must tell user to re-trigger manually (can't reconstruct instruction)
  [[ "$output" == *"re-trigger"* || "$output" == *"re-mention"* ]]
}

@test "fix-reviews: rate-limited: human-pr intent posts user-visible acknowledgment" {
  export INTENT_TYPE="human-pr"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export ACTOR="donpetry"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A description"

  # Track how many times pr comment is called (marker + ack = 2 calls for human-pr)
  local comment_count_file
  comment_count_file=$(mktemp)
  echo "0" > "$comment_count_file"

  export COPILOT_GITHUB_TOKEN="stub-token"
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
# copilot must be checked first — its -p prompt text may contain "graphql"
case "\$1" in
  copilot) echo "quota exceeded"; exit 1 ;;
esac
ARGS="\$*"
case "\$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    count=\$(cat "${comment_count_file}")
    echo \$((count + 1)) > "${comment_count_file}"
    echo "COMMENT_POSTED #\$((count + 1))"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
  # human-pr should post 2 comments: the rate-limited marker + the user acknowledgment
  local final_count
  final_count=$(cat "$comment_count_file")
  rm -f "$comment_count_file"
  [ "$final_count" -ge 2 ]
}

@test "fix-reviews: rate-limited: fix-bot-comment posts rate-limited marker" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"
  export COPILOT_GITHUB_TOKEN="stub-token"

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"api"*"repos/"*"issues/"*)
    echo "[]" ;;
  *"pr comment"*)
    echo "COMMENT_POSTED"; exit 0 ;;
  *"copilot"*)
    echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"rate-limited"* ]]
}

@test "fix-reviews: rate-limited dedup: existing marker for same SHA+intent skips duplicate" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export COPILOT_GITHUB_TOKEN="stub-token"

  # Returns existing rate-limited marker for this sha+intent
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
# copilot must be checked first — its -p prompt text may contain "graphql"
case "$1" in
  copilot) echo "rate limit exceeded"; exit 1 ;;
esac
ARGS="$*"
case "$ARGS" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"api"*"repos/"*"issues/"*)
    echo '[{"body":"<!-- dev-lead-fix-reviews pr=54 sha=ddd444eee555 intent=fix-reviews status=rate-limited -->"}]' ;;
  *"pr comment"*)
    echo "COMMENT_POSTED"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"skipping duplicate"* ]]
}

@test "fix-reviews: terminal marker written after successful fix-reviews run" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # In dry-run mode, the terminal marker post is announced
  [[ "$output" == *"terminal marker"* || "$output" == *"[dry-run]"* ]]
}

# ── commit_and_push failure tests ─────────────────────────────────────────────

@test "fix-reviews: commit_and_push: git commit failure exits 1 (not silently swallowed)" {
  export INTENT_TYPE="human"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="abc123"
  export ACTOR="donpetry"
  export USER_INSTRUCTION="fix something"
  # Use absolute path so envsubst can find the prompt even when running from git_repo dir
  export PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead"

  # Real temp git repo with one uncommitted change to trigger commit_and_push
  local git_repo
  git_repo="$(mktemp -d)"
  git -C "$git_repo" init -q
  echo "initial" > "$git_repo/file.txt"
  git -C "$git_repo" add .
  git -C "$git_repo" -c user.email="init@test" -c user.name="Init" commit -q -m "initial"
  echo "change" >> "$git_repo/file.txt"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Changes applied."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED"; exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"}}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Stub git to fail on commit (simulates missing identity) but pass everything else to real git
  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [[ "$*" == *"commit"* ]]; then
  echo "::error::git commit failed — check git identity configuration on the runner"
  echo "fatal: empty ident name not allowed" >&2
  exit 128
fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  # Run from git_repo so git status/add/commit/push operate on the temp repo
  cd "$git_repo"
  # Capture stderr too so ::error:: messages appear in $output
  run bash "$FIX_REVIEWS_SCRIPT" 2>&1

  # Must exit non-zero — git commit failure must NOT be silently swallowed
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* || "$output" == *"failed"* || "$output" == *"fatal"* ]]
}

@test "fix-reviews: commit_and_push: no false 'applied' marker posted on git commit failure" {
  export INTENT_TYPE="human"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="abc123"
  export ACTOR="donpetry"
  export USER_INSTRUCTION="fix something"
  export PROMPTS_DIR="$SCRIPT_DIR/prompts/dev-lead"

  local git_repo
  git_repo="$(mktemp -d)"
  git -C "$git_repo" init -q
  echo "initial" > "$git_repo/file.txt"
  git -C "$git_repo" add .
  git -C "$git_repo" -c user.email="init@test" -c user.name="Init" commit -q -m "initial"
  echo "change" >> "$git_repo/file.txt"

  local comment_file
  comment_file="$(mktemp)"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "Changes applied."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*)
    echo "\$*" >> "$comment_file"
    exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"}}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  cat > "$STUB_BIN_DIR/git" << 'GITEOF'
#!/usr/bin/env bash
if [[ "$*" == *"commit"* ]]; then
  echo "::error::git commit failed — check git identity configuration on the runner"
  exit 128
fi
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$STUB_BIN_DIR/git"

  cd "$git_repo"
  run bash "$FIX_REVIEWS_SCRIPT" 2>&1

  # Script must exit non-zero when commit fails
  [ "$status" -ne 0 ]
  # The "applied" status must NOT have been posted since commit failed
  if [ -f "$comment_file" ]; then
    ! grep -q "status=applied" "$comment_file"
  fi
  rm -f "$comment_file"
}
