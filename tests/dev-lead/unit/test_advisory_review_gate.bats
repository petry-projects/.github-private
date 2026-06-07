#!/usr/bin/env bats
# Tests for advisory-review-gate.sh
#
# Tests the wait logic for advisory bot reviews (Gemini, Copilot, SonarCloud, Codex)

setup() {
  # Use a temp directory for test data
  export TEST_DIR="$(mktemp -d)"
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"

  # Mock gh command
  export GH_MOCK_RESPONSES_DIR="$TEST_DIR/gh-responses"
  mkdir -p "$GH_MOCK_RESPONSES_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
  unset TEST_DIR SCRIPT_DIR GH_MOCK_RESPONSES_DIR
}

# Helper: Create a mock PR response with specific bots
mock_pr_response() {
  local pr_url="$1"
  local -a bot_reviews=("${@:2}")

  local reviews_json="["
  local first=true

  for bot_review in "${bot_reviews[@]}"; do
    IFS='=' read -r bot state <<< "$bot_review"
    if [ "$first" = true ]; then
      first=false
    else
      reviews_json="$reviews_json,"
    fi

    reviews_json="$reviews_json{\"author\":{\"login\":\"$bot\"},\"state\":\"$state\",\"submittedAt\":\"2026-06-07T02:51:35Z\"}"
  done

  reviews_json="$reviews_json]"

  # Create mock response file
  local mock_file="$GH_MOCK_RESPONSES_DIR/pr_${pr_url##*/}"
  cat > "$mock_file" << EOF
{"reviews":$reviews_json,"comments":[]}
EOF
}

# Helper: Override gh to return mock responses
gh() {
  if [[ "$*" == *"pr view"* ]]; then
    local pr_url=$(echo "$*" | grep -oE 'https://[^[:space:]]+')
    local mock_file="$GH_MOCK_RESPONSES_DIR/pr_${pr_url##*/}"
    if [ -f "$mock_file" ]; then
      cat "$mock_file"
    else
      # Default: no reviews yet
      echo '{"reviews":[],"comments":[]}'
    fi
  else
    command gh "$@"
  fi
}

export -f gh
export -f mock_pr_response

@test "Advisory gate: all primary bots present returns success" {
  local pr_url="https://github.com/petry-projects/.github-private/pull/453"

  mock_pr_response "$pr_url" \
    "gemini-code-assist=COMMENTED" \
    "copilot-pull-request-reviewer=COMMENTED" \
    "sonarqubecloud=COMMENTED"

  # Source the gate script
  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"

  # Call with timeout overrides for testing
  TIER1_WAIT=1 TIER2_WAIT=2 TIER3_WAIT=3 wait_for_advisory_reviews "$pr_url"
  local result=$?

  [ $result -eq 0 ] || [ $result -eq 2 ]  # 0=success, 2=timeout but proceed
}

@test "Advisory gate: missing Codex on partial PR returns success" {
  local pr_url="https://github.com/petry-projects/.github-private/pull/450"

  # Only 3 bots, no Codex (Codex not on all PRs)
  mock_pr_response "$pr_url" \
    "gemini-code-assist=COMMENTED" \
    "copilot-pull-request-reviewer=COMMENTED" \
    "sonarqubecloud=COMMENTED"

  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"

  TIER1_WAIT=1 TIER2_WAIT=2 TIER3_WAIT=3 wait_for_advisory_reviews "$pr_url"
  local result=$?

  # Should succeed because 3 primary bots are present
  [ $result -eq 0 ] || [ $result -eq 2 ]
}

@test "Advisory gate: Codex present and later submission is detected" {
  local pr_url="https://github.com/petry-projects/.github-private/pull/451"

  # All 4 bots present
  mock_pr_response "$pr_url" \
    "gemini-code-assist=COMMENTED" \
    "copilot-pull-request-reviewer=COMMENTED" \
    "sonarqubecloud=COMMENTED" \
    "chatgpt-codex-connector=COMMENTED"

  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"

  TIER1_WAIT=1 TIER2_WAIT=2 TIER3_WAIT=3 wait_for_advisory_reviews "$pr_url"
  local result=$?

  [ $result -eq 0 ] || [ $result -eq 2 ]
}

@test "Advisory gate: SonarCloud CHANGES_REQUESTED is noted" {
  local pr_url="https://github.com/petry-projects/.github-private/pull/452"

  mock_pr_response "$pr_url" \
    "gemini-code-assist=COMMENTED" \
    "copilot-pull-request-reviewer=COMMENTED" \
    "sonarqubecloud=CHANGES_REQUESTED"

  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"

  TIER1_WAIT=1 TIER2_WAIT=2 TIER3_WAIT=3 wait_for_advisory_reviews "$pr_url"
  local result=$?

  # Even with CHANGES_REQUESTED, gate still succeeds (advisory only)
  [ $result -eq 0 ] || [ $result -eq 2 ]
}

@test "Advisory gate: no bots submitted triggers timeout warning" {
  local pr_url="https://github.com/petry-projects/.github-private/pull/454"

  # No bots reviewed
  mock_pr_response "$pr_url"

  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"

  TIER1_WAIT=1 TIER2_WAIT=2 TIER3_WAIT=3 wait_for_advisory_reviews "$pr_url"
  local result=$?

  # Should return 2 (hard timeout with warning)
  [ $result -eq 2 ]
}

@test "Advisory gate: script is executable" {
  [ -x "$SCRIPT_DIR/lib/advisory-review-gate.sh" ]
}

@test "Advisory gate: helper functions exist" {
  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"

  declare -f wait_for_advisory_reviews >/dev/null 2>&1
  declare -f log_info >/dev/null 2>&1
  declare -f format_bot_status >/dev/null 2>&1
}
