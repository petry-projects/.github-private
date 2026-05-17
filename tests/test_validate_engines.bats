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
