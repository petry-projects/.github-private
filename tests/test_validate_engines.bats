#!/usr/bin/env bats

setup() {
  export TEST_DIR="$BATS_TMPDIR/validate-test"
  mkdir -p "$TEST_DIR/bin"
  export PATH="$TEST_DIR/bin:$PATH"

  cp "$BATS_TEST_DIRNAME/../scripts/validate-engines.sh" "$TEST_DIR/"

  cat > "$TEST_DIR/bin/claude" <<'EOF'
#!/bin/bash
echo "claude"
EOF
  chmod +x "$TEST_DIR/bin/claude"

  cat > "$TEST_DIR/bin/gemini" <<'EOF'
#!/bin/bash
echo "gemini"
EOF
  chmod +x "$TEST_DIR/bin/gemini"

  cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/bin/bash
echo "gh copilot"
EOF
  chmod +x "$TEST_DIR/bin/gh"

  # curl mock: returns 200 OK (Gemini billing healthy) by default.
  # Tests that need billing-depleted behaviour set MOCK_GEMINI_BILLING=depleted.
  # Tests simulating a transient quota error set MOCK_GEMINI_BILLING=rate_limited
  # (RESOURCE_EXHAUSTED without billing-specific text — should NOT disable Gemini).
  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
if [ "${MOCK_GEMINI_BILLING:-ok}" = "depleted" ]; then
  printf '{"error":{"code":429,"message":"Your prepayment credits are depleted.","status":"RESOURCE_EXHAUSTED"}}\n'
  printf '429\n'
elif [ "${MOCK_GEMINI_BILLING:-ok}" = "rate_limited" ]; then
  printf '{"error":{"code":429,"message":"Quota exceeded for this model.","status":"RESOURCE_EXHAUSTED"}}\n'
  printf '429\n'
else
  printf '{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}\n'
  printf '200\n'
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/curl"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "validate_engines: Gemini available when key and trust workspace are set" {
  source "$TEST_DIR/validate-engines.sh"
  export GOOGLE_API_KEY="fake"
  export GEMINI_CLI_TRUST_WORKSPACE="true"
  export CLAUDE_CODE_OAUTH_TOKEN="fake"
  export COPILOT_GITHUB_TOKEN="fake"

  validate_engines

  [ "$GEMINI_AVAILABLE" = "true" ]
}

@test "validate_engines: Gemini unavailable when trust workspace is not true" {
  source "$TEST_DIR/validate-engines.sh"
  export GOOGLE_API_KEY="fake"
  export GEMINI_CLI_TRUST_WORKSPACE="false"
  export CLAUDE_CODE_OAUTH_TOKEN="fake"
  export COPILOT_GITHUB_TOKEN="fake"

  validate_engines > "$TEST_DIR/out.log"
  output=$(cat "$TEST_DIR/out.log")

  [ "$GEMINI_AVAILABLE" = "false" ]
  [[ "$output" == *"::warning::Gemini fallback unavailable — GEMINI_CLI_TRUST_WORKSPACE is not true (fix: set in env or pass --skip-trust)"* ]]
}

@test "validate_engines: Gemini unavailable when billing probe detects depleted credits text" {
  source "$TEST_DIR/validate-engines.sh"
  export GOOGLE_API_KEY="fake"
  export GEMINI_CLI_TRUST_WORKSPACE="true"
  export CLAUDE_CODE_OAUTH_TOKEN="fake"
  export COPILOT_GITHUB_TOKEN="fake"
  export MOCK_GEMINI_BILLING="depleted"

  validate_engines > "$TEST_DIR/out.log" 2>&1
  output=$(cat "$TEST_DIR/out.log")

  [ "$GEMINI_AVAILABLE" = "false" ]
  [[ "$output" == *"prepayment credits depleted"* ]]
}

@test "validate_engines: billing probe does not fire on transient RESOURCE_EXHAUSTED without credits text" {
  source "$TEST_DIR/validate-engines.sh"
  export GOOGLE_API_KEY="fake"
  export GEMINI_CLI_TRUST_WORKSPACE="true"
  export CLAUDE_CODE_OAUTH_TOKEN="fake"
  export COPILOT_GITHUB_TOKEN="fake"
  export MOCK_GEMINI_BILLING="rate_limited"

  validate_engines > "$TEST_DIR/out.log" 2>&1

  # A transient quota RESOURCE_EXHAUSTED (no "credits depleted" text) must not
  # disable Gemini for the whole batch — it may recover after the quota window resets.
  [ "$GEMINI_AVAILABLE" = "true" ]
}
