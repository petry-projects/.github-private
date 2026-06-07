#!/usr/bin/env bats
# Unit tests for dev-lead-intent.sh — the `dev-lead:hands-off` label guard.
# A PR or issue carrying the label is excluded from the agent regardless of the
# event that would otherwise route it (so the agent doesn't pile commits onto
# PRs that modify the dev-lead workflow itself).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
INTENT_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-intent.sh"
FIXTURES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/events"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot],chatgpt-codex-connector[bot]"
  export TRIGGER_PHRASES="@dev-lead"
  export GITHUB_REPOSITORY="petry-projects/.github-private"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
}

_get_env() {
  local key="$1"
  grep "^${key}=" "$GITHUB_ENV" | cut -d= -f2- | head -1
}

@test "hands-off: bot review comment on a labeled PR → skip (not fix-reviews)" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_copilot_hands_off.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hands-off-label" ]
}

@test "hands-off: control — same bot review comment without the label → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/pr_review_comment_copilot.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "fix-reviews" ]
}

@test "hands-off: issue labeled dev-lead but also hands-off → skip (no pickup)" {
  export GITHUB_EVENT_NAME="issues"
  export GITHUB_EVENT_PATH="$FIXTURES_DIR/issues_labeled_dev_lead_hands_off.json"

  run bash "$INTENT_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(_get_env INTENT_TYPE)" = "skip" ]
  [ "$(_get_env INTENT_REASON)" = "hands-off-label" ]
}
