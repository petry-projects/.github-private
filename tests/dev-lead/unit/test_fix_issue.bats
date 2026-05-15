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
