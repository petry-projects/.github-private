#!/usr/bin/env bats

setup() {
  export TEST_DIR="$BATS_TMPDIR/batch-test"
  mkdir -p "$TEST_DIR/scripts"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"
  
  export PRS_FILE="prs.txt"
  echo "https://github.com/fake/pull/1" > "$PRS_FILE"
  export CANDIDATE_LIMIT=1
  export MAX_PRS=1
  export REVIEW_ENGINE="claude"
  export COPILOT_GITHUB_TOKEN="fake_token"
  export PATH="$TEST_DIR/bin:$PATH"

  cp "$BATS_TEST_DIRNAME/../scripts/review-batch.sh" "scripts/"

  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="true"
  export GEMINI_AVAILABLE="true"
  export COPILOT_AVAILABLE="true"
}
EOF

  cat > "scripts/engine.sh" <<'EOF'
export COPILOT_API_MODEL="openai/o4-mini"
EOF

  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
if [ "$REVIEW_ENGINE" = "claude" ]; then
  exit 2
elif [ "$REVIEW_ENGINE" = "gemini" ]; then
  exit 55
elif [ "$REVIEW_ENGINE" = "copilot" ]; then
  touch copilot_called.txt
  exit 0
fi
EOF
  chmod +x "scripts/review-one-pr.sh"

  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo '{"choices":[{"message":{"content":"ready"}}]}'
echo '200'
EOF
  chmod +x "$TEST_DIR/bin/curl"

  cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "extension" ]; then
  echo "github/gh-copilot"
elif [ "$1" = "copilot" ]; then
  echo "gh copilot version"
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "batch: Gemini trust error (55) falls back to Copilot" {
  run bash scripts/review-batch.sh
  
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [ -f copilot_called.txt ]
  [[ "$output" == *"Claude rate limit hit"* ]]
  [[ "$output" == *"Engine gemini unavailable at runtime (exit 55)"* ]] || [[ "$output" == *"Gemini engine unavailable at runtime (exit 55)"* ]]
  [[ "$output" == *"falling through to Copilot"* ]] || [[ "$output" == *"switching to Copilot engine"* ]]
}
