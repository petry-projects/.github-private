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

@test "fix-reviews: INTENT_TYPE=on-mention → runs on-mention intent" {
  export INTENT_TYPE="on-mention"
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

@test "fix-reviews: review-changes in dry-run: outputs [dry-run] message" {
  export INTENT_TYPE="review-changes"
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

@test "fix-reviews: rate-limited: on-mention intent posts re-trigger ack (not auto-retry)" {
  export INTENT_TYPE="on-mention"
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

@test "fix-reviews: rate-limited: review-changes intent posts user-visible acknowledgment" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="false"
  export HEAD_SHA="ddd444eee555"
  export ACTOR="donpetry"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A description"

  # Track how many times pr comment is called (marker + ack = 2 calls for review-changes)
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
  # review-changes should post 2 comments: the rate-limited marker + the user acknowledgment
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

@test "fix-reviews: no-changes path also calls notify_coderabbit_resolve (dry-run)" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would check for coderabbitai CHANGES_REQUESTED"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for fix-reviews" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for fix-bot-comment" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export COMMENT_BODY="SonarQube found issues"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
}

@test "fix-reviews: try_enable_auto_merge dry-run output present for review-changes" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable auto-merge"* ]]
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

@test "post_no_changes: posts visible heading with fallback when no session log" {
  # Run from a non-git tmpdir so commit_and_push reports no changes → no-changes path
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f /tmp/dev-lead-session-output.txt

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [[ "$output" == *"## Dev-Lead — fix-reviews (no-changes)"* ]]
  [[ "$output" == *"No actionable items found"* ]]
}

@test "post_no_changes: includes agent reasoning when session log is present" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  printf 'Agent determined no code changes required.\n' > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"## Dev-Lead — fix-reviews (no-changes)"* ]]
  [[ "$output" == *"Agent determined no code changes"* ]]
}

@test "post_no_changes: redacts GitHub tokens from session log" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  # Embed a fake GitHub PAT — redact_secrets should mask it before publishing.
  # Build the token at runtime so the literal doesn't appear in this source file
  # (avoids tripping gitleaks on our own test fixture).
  local fake_prefix='ghp' fake_body='_abcdefghij1234567890ABCDEFGHIJ'
  printf 'curl -H "Auth: %s%s" url\n' "$fake_prefix" "$fake_body" > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"***REDACTED-GH-TOKEN***"* ]]
  [[ "$output" != *"${fake_prefix}${fake_body}"* ]]
}

@test "post_no_changes: pick_fence outgrows tilde sequences in content" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  # Content has a 4-tilde sequence — fence must be 5+ to wrap cleanly
  printf 'output line one\n~~~~ this looks like a fence\noutput line two\n' > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  # Fence must be longer than the embedded 4-tilde run
  [[ "$output" == *"~~~~~"* ]]
}

@test "post_no_changes: redacts entire PEM private key block, not just header" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  # Build the PEM markers at runtime so the literal "-----BEGIN RSA PRIVATE
  # KEY-----" never appears in this source file (avoids tripping our own
  # gitleaks check on a test fixture).
  local dashes="-----"
  local begin="${dashes}BEGIN RSA PRIVATE KEY${dashes}"
  local end="${dashes}END RSA PRIVATE KEY${dashes}"
  {
    echo "some preamble text"
    echo "$begin"
    echo "MIIEpAIBAAKCAQEAabcdefghij1234567890BODY_LINE_ONE_SHOULD_BE_REDACTED"
    echo "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZBODY_LINE_TWO_SHOULD_BE_REDACTEDZZZZ"
    echo "$end"
    echo "some postamble text"
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"***REDACTED-PRIVATE-KEY***"* ]]
  # Body and footer lines must be gone — leaking ANY part of the key is a fail
  [[ "$output" != *"BODY_LINE_ONE_SHOULD_BE_REDACTED"* ]]
  [[ "$output" != *"BODY_LINE_TWO_SHOULD_BE_REDACTED"* ]]
  [[ "$output" != *"$end"* ]]
}

@test "post_no_changes: redacts PEM block straddling the tail-30 boundary" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  local dashes="-----"
  local begin="${dashes}BEGIN RSA PRIVATE KEY${dashes}"
  local end="${dashes}END RSA PRIVATE KEY${dashes}"
  # Build a log where the BEGIN marker sits BEFORE the last-30 window. Without
  # redact-then-tail, the body/END would be tailed without a matching BEGIN and
  # the c\ range would never fire, leaking key material.
  {
    echo "$begin"
    for i in $(seq 1 50); do echo "filler-line-$i"; done
    echo "STRADDLE_KEY_BODY_MUST_NOT_LEAK_XYZ"
    echo "$end"
    echo "trailing summary line"
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" != *"STRADDLE_KEY_BODY_MUST_NOT_LEAK_XYZ"* ]]
  [[ "$output" != *"$end"* ]]
}

@test "post_no_changes: neutralises literal </details> in session output" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local session_log="/tmp/dev-lead-session-output.txt"
  printf 'discussing </details> tag\n' > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  # The literal </details> from session content must be escaped so it cannot
  # close the wrapping <details> block early.
  [[ "$output" == *"<\\/details>"* ]]
}

# ── commit_and_push failure tests ─────────────────────────────────────────────

@test "fix-reviews: commit_and_push: git commit failure exits 1 (not silently swallowed)" {
  export INTENT_TYPE="on-mention"
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
  export INTENT_TYPE="on-mention"
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

# ── read_session_summary: marker-based extraction ─────────────────────────────

@test "read_session_summary: extracts buried summary block past the tail-30 window" {
  local tmpdir session_log
  tmpdir="$(mktemp -d)"
  session_log="/tmp/dev-lead-session-output.txt"

  # Summary at line 3, then 200 lines of trailing tool output — the prior tail -30
  # implementation would have missed this entirely.
  {
    echo "tool: Read foo.sh"
    echo "tool: Grep something"
    echo "Addressed 1 threads:"
    echo "- Thread PRRT_xxx: applied fix [resolved]"
    echo "Files changed: foo.sh"
    for i in $(seq 1 200); do echo "tool: extra log line $i"; done
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"## Dev-Lead — fix-reviews (no-changes)"* ]]
  # The structured summary line should be present even though it's far before the EOF.
  [[ "$output" == *"Addressed 1 threads"* ]]
  [[ "$output" == *"PRRT_xxx"* ]]
}

@test "read_session_summary: falls back to tail when no marker is found" {
  local tmpdir session_log
  tmpdir="$(mktemp -d)"
  session_log="/tmp/dev-lead-session-output.txt"

  # Unstructured output with no recognised marker — should still surface the last lines.
  {
    for i in $(seq 1 50); do echo "log line $i"; done
    echo "final completion notice"
  } > "$session_log"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$session_log"

  [[ "$output" == *"final completion notice"* ]]
}

# ── resolve_actor_outdated_threads: safety net for no-changes path ────────────

@test "resolve_actor_outdated_threads: dry-run announces and skips API calls" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f /tmp/dev-lead-session-output.txt

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='chatgpt-codex-connector[bot]' COMMENT_BODY='something'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [[ "$output" == *"would resolve outdated review threads authored by chatgpt-codex-connector[bot]"* ]]
}

@test "resolve_actor_outdated_threads: matches actor with [bot] suffix stripped" {
  local tmpdir mutations_file
  tmpdir="$(mktemp -d)"
  mutations_file="$(mktemp)"
  rm -f /tmp/dev-lead-session-output.txt

  # gh stub: returns the JSON unfiltered (we pipe to real jq), and records mutations.
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"resolveReviewThread"*)
    echo "\$*" >> "$mutations_file"
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *"reviewThreads"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_outdated_thread_id","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]}}]}}}}}'
    ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Use a real git repo so commit_and_push returns "no changes"
  git -C "$tmpdir" init -q
  echo "initial" > "$tmpdir/file.txt"
  git -C "$tmpdir" add .
  git -C "$tmpdir" -c user.email="t@test" -c user.name="T" commit -q -m "init"

  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "No actionable items."
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=false
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export ACTOR='chatgpt-codex-connector[bot]' COMMENT_BODY='something'
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1

  # Mutation must have been invoked for the matched thread id
  grep -q "resolveReviewThread" "$mutations_file"
  grep -q "PRRT_outdated_thread_id" "$mutations_file"

  rm -rf "$tmpdir"
  rm -f "$mutations_file"
}

@test "resolve_actor_outdated_threads: skips when ACTOR is unset" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  rm -f /tmp/dev-lead-session-output.txt

  # No ACTOR set and no TRIGGERING_REVIEWER fallback — helper should log and skip.
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    unset ACTOR TRIGGERING_REVIEWER
    export PATH='$STUB_BIN_DIR:$PATH'
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [[ "$output" == *"ACTOR not set for intent=fix-reviews"* ]]
}

# ── resolve_actor_outdated_threads: called in both branches ─────────────────

@test "fix-reviews: resolve_actor_outdated_threads called in applied path (dry-run)" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export ACTOR="chatgpt-codex-connector[bot]"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # In dry-run, resolve_actor_outdated_threads should announce it would resolve
  [[ "$output" == *"would resolve outdated review threads authored by chatgpt-codex-connector[bot]"* ]]
}

@test "fix-bot-comment: resolve_actor_outdated_threads called in applied path (dry-run)" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export ACTOR="sonarqubecloud[bot]"
  export COMMENT_BODY="SonarQube found issues"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Should call resolve_actor_outdated_threads in dry-run mode
  [[ "$output" == *"would resolve outdated review threads authored by sonarqubecloud[bot]"* ]]
}

@test "review-changes: resolve_actor_outdated_threads called in applied path (dry-run)" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export ACTOR="donpetry"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test PR"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Should call resolve_actor_outdated_threads in dry-run mode
  [[ "$output" == *"would resolve outdated review threads authored by donpetry"* ]]
}

# ── ALL_REVIEWS_JSON deduplication: latest review per user ───────────────────
# The GitHub Reviews API returns the full history of all reviews. If a reviewer
# previously requested changes but later approved, both entries are present.
# The jq filter in collect_assessment_data must keep only the latest per user,
# but COMMENTED reviews must not clear a prior CHANGES_REQUESTED or APPROVED
# (GitHub does not count COMMENTED as a blocking state change).
readonly JQ_DEDUP_REVIEWS='[ [.[].[] | select(.user != null)] | group_by(.user.login)[] | (. as $g | ($g | map(select(.state != "COMMENTED")) | sort_by(.id) | last) // ($g | sort_by(.id) | last)) | {id:.id, user:.user.login, state:.state, submitted_at:.submitted_at, body:.body} ]'

@test "collect_assessment_data: jq dedup expression keeps only latest review per user" {
  # Feed sample multi-review JSON through the exact jq expression used in the script
  # to verify that CHANGES_REQUESTED is superseded by a later APPROVED from the same user.
  # Input is a single-page array; jq -s simulates --paginate output (wraps to [[...]])
  # so .[].[] correctly flattens across pages.
  local input='[
    {"id":1,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z"},
    {"id":2,"user":{"login":"bob"},"state":"APPROVED","submitted_at":"2024-01-02T00:00:00Z"},
    {"id":3,"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2024-01-03T00:00:00Z"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  # alice's latest review (id=3) is APPROVED — CHANGES_REQUESTED (id=1) must not appear
  [[ "$output" == *'"alice"'* ]]
  [[ "$output" == *'"APPROVED"'* ]]
  # Only one entry for alice — no duplicate
  local alice_count
  alice_count=$(echo "$output" | grep -c '"alice"')
  [ "$alice_count" -eq 1 ]
  # CHANGES_REQUESTED should not appear in output
  [[ "$output" != *'"CHANGES_REQUESTED"'* ]]
}

@test "collect_assessment_data: jq dedup expression filters out null-user entries" {
  local input='[
    {"id":1,"user":null,"state":"APPROVED","submitted_at":"2024-01-01T00:00:00Z"},
    {"id":2,"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2024-01-02T00:00:00Z"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  # Result should have only alice; the null-user entry is filtered out
  local count
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 1 ]
}

@test "collect_assessment_data: jq dedup keeps CHANGES_REQUESTED when later COMMENTED review exists" {
  # A COMMENTED review must not supersede a prior CHANGES_REQUESTED — GitHub only
  # clears the blocking state when the reviewer submits APPROVED or is dismissed.
  local input='[
    {"id":1,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z"},
    {"id":2,"user":{"login":"alice"},"state":"COMMENTED","submitted_at":"2024-01-02T00:00:00Z"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"CHANGES_REQUESTED"'* ]]
  [[ "$output" != *'"COMMENTED"'* ]]
}

@test "collect_assessment_data: jq dedup preserves review body in output" {
  # When a reviewer uses only the review summary (no line threads), the body field
  # must be preserved in ALL_REVIEWS_JSON so the agent can read the instructions.
  local input='[
    {"id":1,"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z","body":"Please fix the type errors before merging."}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_REVIEWS'"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"body"'* ]]
  [[ "$output" == *'Please fix the type errors before merging.'* ]]
}

# ── holistic assessment: CI_STATUS_JSON and ALL_REVIEWS_JSON fetching ──────────
# These tests verify that fix-reviews, review-changes, and fix-bot-comment all
# fetch CI check results and all PR reviews before running the engine, so the
# agent can detect Tier-1 blockers (failing CI + CHANGES_REQUESTED reviews) and
# never wrongly declare "no-changes" while the PR is still blocked.

_make_assessment_gh_stub() {
  local calls_file="$1"
  cat > "$STUB_BIN_DIR/gh" << GHEOF
#!/usr/bin/env bash
# Record every invocation for assertion
printf '%s\n' "\$*" >> "${calls_file}"
ARGS="\$*"
case "\$ARGS" in
  *"commits/"*"check-runs"*)
    # Return raw GitHub API format — script now uses --paginate piped to jq -s
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"/reviews"*)
    # Return raw GitHub API format with user as object — script now uses --paginate piped to jq -s
    echo '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"CHANGES_REQUESTED","submitted_at":"2024-01-01T00:00:00Z"}]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
}

@test "fix-reviews: fix-reviews case fetches CI check-runs endpoint" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Script must have called the check-runs API endpoint
  grep -q "commits/.*check-runs" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-reviews case fetches all PR reviews endpoint" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  # Script must have called the reviews API endpoint
  grep -q "pulls/.*reviews" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: review-changes case fetches CI check-runs endpoint" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*check-runs" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: review-changes case fetches all PR reviews endpoint" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "pulls/.*reviews" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-bot-comment case fetches CI check-runs endpoint" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*check-runs" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-bot-comment case fetches all PR reviews endpoint" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "pulls/.*reviews" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-reviews case fetches commit statuses endpoint" {
  export INTENT_TYPE="fix-reviews"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*statuses" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: review-changes case fetches commit statuses endpoint" {
  export INTENT_TYPE="review-changes"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export PR_TITLE="Test PR"
  export PR_DESCRIPTION="A test pull request"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*statuses" "$calls_file"
  rm -f "$calls_file"
}

@test "fix-reviews: fix-bot-comment case fetches commit statuses endpoint" {
  export INTENT_TYPE="fix-bot-comment"
  export DEV_LEAD_DRY_RUN="true"
  export HEAD_SHA="ddd444eee555"
  export COMMENT_BODY="SonarQube found issues"

  local calls_file
  calls_file="$(mktemp)"
  _make_assessment_gh_stub "$calls_file"

  run bash "$FIX_REVIEWS_SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "commits/.*statuses" "$calls_file"
  rm -f "$calls_file"
}

# ── Tier-1 blocker gating: no-changes must not be posted while blockers exist ──
# Regression tests for issue #425: the agent must not declare "no-changes" while
# CI is failing or a reviewer has CHANGES_REQUESTED.

@test "fix-reviews: does not post no-changes when Tier-1 blockers exist (fix-reviews)" {
  local calls_file tmpdir
  calls_file="$(mktemp)"
  tmpdir="$(mktemp -d)"
  _make_assessment_gh_stub "$calls_file"

  # Run from a non-git tmpdir so commit_and_push returns 1 (no changes), taking the no-changes path
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$calls_file"

  [ "$status" -eq 0 ]
  # Must NOT post a terminal no-changes marker while CI is failing + CHANGES_REQUESTED
  [[ "$output" != *"status=no-changes"* ]]
  # Must emit the warning explaining why no-changes was skipped
  [[ "$output" == *"Tier-1 blockers still present"* ]]
}

@test "fix-reviews: fix-bot-comment with hard blockers posts terminal no-changes (not silently skipped)" {
  # fix-bot-comment is excluded from RETRYABLE_REVIEW_INTENTS, so when hard blockers
  # exist (failing CI or CHANGES_REQUESTED) and no code changes were made, we must
  # post a terminal no-changes marker rather than leaving the SHA without any marker.
  local calls_file tmpdir
  calls_file="$(mktemp)"
  tmpdir="$(mktemp -d)"
  _make_assessment_gh_stub "$calls_file"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='petry-projects/.github-private'
    export COMMENT_BODY='SonarQube found issues'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$calls_file"

  [ "$status" -eq 0 ]
  # Hard blockers present + no code changes → must post terminal marker (not silently skip)
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  # Must not post a rate-limited marker (fix-bot-comment is not retried automatically)
  [[ "$output" != *"[dry-run] would post rate-limited marker"* ]]
}

@test "fix-reviews: does not post no-changes when Tier-1 blockers exist (review-changes)" {
  local calls_file tmpdir
  calls_file="$(mktemp)"
  tmpdir="$(mktemp -d)"
  _make_assessment_gh_stub "$calls_file"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='petry-projects/.github-private'
    export PR_TITLE='Test PR' PR_DESCRIPTION='A test pull request'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir" "$calls_file"

  [ "$status" -eq 0 ]
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
}

@test "fix-reviews: posts no-changes when no Tier-1 blockers exist (fix-reviews)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub with all-success CI and no CHANGES_REQUESTED reviews
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"commits/"*"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Run from a non-git tmpdir so commit_and_push returns 1 (no changes), taking the no-changes path
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # No blockers → no-changes marker should be posted
  [[ "$output" == *"status=no-changes"* ]]
}

# ── Legacy commit statuses dedup: latest state per context wins ────────────────
# The /statuses API returns the full history per context (newest first). A stale
# failure followed by a newer success for the same context must not suppress
# no-changes — only the latest entry per context should be considered.
readonly JQ_DEDUP_STATUSES='[ [.[].[] | select(.context != null)] | group_by(.context)[] | first | {name:.context, conclusion:(if .state == "success" then "success" elif .state == "failure" or .state == "error" then "failure" else null end)} ]'

@test "collect_assessment_data: jq statuses dedup keeps only latest entry per context" {
  # GitHub /statuses API returns newest-first. Here jenkins/build had a failure then a
  # newer success, so success appears first in the array (= newest). After dedup, only
  # the success (first entry per context) should remain.
  local input='[
    {"context":"jenkins/build","state":"success","target_url":"https://ci.example.com/2"},
    {"context":"jenkins/build","state":"failure","target_url":"https://ci.example.com/1"},
    {"context":"other/check","state":"success","target_url":"https://ci.example.com/3"}
  ]'

  run bash -c "printf '%s' '$input' | jq -s '$JQ_DEDUP_STATUSES'"

  [ "$status" -eq 0 ]
  # The newer success for jenkins/build must appear; the old failure must not
  local jenkins_conclusion
  jenkins_conclusion=$(echo "$output" | jq -r '.[] | select(.name == "jenkins/build") | .conclusion')
  [ "$jenkins_conclusion" = "success" ]
  # Only one entry for jenkins/build — no duplicate
  local jenkins_count
  jenkins_count=$(echo "$output" | jq '[.[] | select(.name == "jenkins/build")] | length')
  [ "$jenkins_count" -eq 1 ]
}

@test "fix-reviews: does not treat superseded legacy CI failure as Tier-1 blocker (fix-reviews)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: check-runs all success; statuses has old failure then new success for same context
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"commits/"*"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"commits/"*"statuses"*)
    # Newest-first: success (newer) comes before failure (older) in the history
    echo '[{"context":"jenkins/build","state":"success","target_url":"https://ci.example.com/2"},{"context":"jenkins/build","state":"failure","target_url":"https://ci.example.com/1"}]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"issues/"*"comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"ddd444eee555"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  # Run from a non-git tmpdir so commit_and_push returns 1 (no changes), taking the no-changes path
  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=54 HEAD_SHA=ddd444eee555 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # The old failure is superseded by the newer success → no Tier-1 blockers → no-changes is posted
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"Tier-1 blockers still present"* ]]
}

@test "fix-reviews: resolve_bot_outdated_threads called in no-changes path (dry-run)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"resolve outdated review threads from bot reviewers"* ]]
}

@test "fix-reviews: bot-thread-only blocker posts no-changes terminal marker (not rate-limited)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: check-runs success, statuses none, but graphql returns unresolved bot threads
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    # First query (for has_tier1_blockers) or review-changes context query returns bot threads
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                },
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "coderabbitai[bot]"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot threads only → no hard blockers → posts terminal no-changes (not rate-limited)
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: posts no-changes terminal marker when only bot threads block (no hard blockers)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: graphql returns unresolved bot threads but no failing CI
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                }
              ]
            }
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot threads only, no hard blockers → posts terminal no-changes; no rate-limited retry loop
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: detects bot threads via __typename Bot (login without [bot] suffix)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: graphql returns a bot thread where login has no [bot] suffix but __typename is "Bot"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "some-bot-without-suffix", "__typename": "Bot"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot detected via __typename == "Bot" even without [bot] suffix → no-changes posted (no rate-limited retry loop)
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: bot-thread query failure is treated conservatively (as blocked)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: graphql call exits nonzero (simulates transient GitHub error / secondary rate limit).
  # Uses fix-bot-comment intent because has_tier1_blockers is still called there.
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    # Simulate transient API failure — exit nonzero
    echo "GraphQL error: secondary rate limit" >&2
    exit 1 ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export COMMENT_BODY='SonarQube found issues'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Query failure → has_tier1_blockers returns 0 (conservatively blocked) → warning emitted
  # → no-changes terminal is still posted (fix-bot-comment elif branch), not silently skipped
  [[ "$output" == *"bot-thread query failed"* ]]
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
}

@test "fix-reviews: hard blockers take precedence over bot thread warning" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI + unresolved bot thread → hard blocker wins, no retry marker
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "coderabbitai[bot]", "__typename": "Bot"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Hard blocker (failing CI) → shows hard-blocker warning, NOT the bot-thread retry path,
  # and now posts a rate-limited marker so the cron can retry later.
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" != *"Unresolved bot review threads remain"* ]]
  [[ "$output" != *"status=no-changes"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  # Must include a future reset time so the retry cron backs off instead of re-dispatching immediately
  [[ "$output" == *"reset="* ]]
}

@test "fix-reviews: hard blockers path posts rate-limited marker for retry" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI, no bot threads — hard blocker only
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Hard blockers path must post a rate-limited marker so the retry cron can re-dispatch
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  [[ "$output" != *"status=no-changes"* ]]
  # Must include a future reset time so the retry cron backs off instead of re-dispatching immediately
  [[ "$output" == *"reset="* ]]
}

@test "review-changes: hard blockers path posts rate-limited marker for retry" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: failing CI, no bot threads — hard blocker only
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"failure","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reviewDecision":null}}}}' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=review-changes DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier-1 blockers still present"* ]]
  [[ "$output" == *"rate-limited marker"* ]]
  [[ "$output" != *"status=no-changes"* ]]
  # Must include a future reset time so the retry cron backs off instead of re-dispatching immediately
  [[ "$output" == *"reset="* ]]
}

@test "fix-reviews: bot-thread-only blocker posts no-changes terminal marker (fix-reviews intent)" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: success CI, no CHANGES_REQUESTED, unresolved bot thread only
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-reviews DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # Bot threads only → no hard blockers → posts terminal no-changes; no rate-limited retry loop
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"rate-limited marker"* ]]
  [[ "$output" != *"reset="* ]]
}

@test "fix-bot-comment: unresolved bot threads posts no-changes terminal marker" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Stub: success CI, no CHANGES_REQUESTED, unresolved bot thread
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"check-runs"*)
    echo '{"check_runs":[{"name":"Lint","status":"completed","conclusion":"success","details_url":"https://example.com"}]}' ;;
  *"statuses"*)
    echo '[]' ;;
  *"pulls/"*"reviews"*)
    echo '[]' ;;
  *"graphql"*)
    echo '{
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "isResolved": false,
                  "comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer[bot]"}}]}
                }
              ]
            },
            "reviewDecision": null
          }
        }
      }
    }' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"pr merge"*) exit 0 ;;
  *"pulls/"*) echo '{"head":{"sha":"abc123"},"auto_merge":null}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run bash -c "
    cd '$tmpdir'
    export INTENT_TYPE=fix-bot-comment DEV_LEAD_DRY_RUN=true
    export PR_NUMBER=422 HEAD_SHA=abc123 REPO='petry-projects/.github-private'
    export COMMENT_BODY='bot feedback' ACTOR='copilot-pull-request-reviewer[bot]'
    export REVIEW_ENGINE=claude BASE_REF=main PROMPTS_DIR='$SCRIPT_DIR/prompts/dev-lead'
    export PATH=\"$STUB_BIN_DIR:\$PATH\"
    bash '$FIX_REVIEWS_SCRIPT'
  " 2>&1
  rm -rf "$tmpdir"

  [ "$status" -eq 0 ]
  # fix-bot-comment is not retryable, so bot-thread blocker posts terminal no-changes (not rate-limited)
  [[ "$output" == *"fix-bot-comment is not automatically retried"* ]]
  [[ "$output" == *"status=no-changes"* ]]
  [[ "$output" != *"[dry-run] would post rate-limited marker"* ]]
}
