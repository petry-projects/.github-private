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

@test "batch: Claude runtime error (exit 55) falls back to Copilot" {
  # Gemini is now last in the fallback chain (claude→copilot→gemini, #571), so
  # a Gemini trust error no longer falls back to Copilot.  The equivalent test
  # of the trust-error→fallback path is: Claude exits 55 (treated as
  # fallback-eligible by the exit-55 normaliser), then Copilot picks up.
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
if [ "$REVIEW_ENGINE" = "claude" ]; then
  exit 55
elif [ "$REVIEW_ENGINE" = "gemini" ]; then
  exit 55
elif [ "$REVIEW_ENGINE" = "copilot" ]; then
  touch copilot_called.txt
  exit 0
fi
EOF
  chmod +x "scripts/review-one-pr.sh"

  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 0 ]
  [ -f copilot_called.txt ]
  [[ "$output" == *"Engine claude unavailable at runtime (exit 55)"* ]]
  [[ "$output" == *"switching to Copilot engine"* ]]
}

@test "batch: empty PRS_FILE with Gemini unavailable exits 0 without Copilot smoke test" {
  # Regression guard: when the billing probe marks Gemini unavailable the
  # pre-flight switch to Copilot must not run the smoke test (which would fail
  # on a missing/invalid COPILOT_GITHUB_TOKEN) when there are no PRs to review.
  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="false"
  export GEMINI_AVAILABLE="false"
  export COPILOT_AVAILABLE="true"
}
EOF

  # Empty PRS_FILE — nothing to review.
  : > "$PRS_FILE"
  unset COPILOT_GITHUB_TOKEN

  export REVIEW_ENGINE="gemini"
  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"No candidate PRs to review"* ]]
}

@test "batch: primary Gemini with GEMINI_AVAILABLE=false skips to Copilot without invoking Gemini" {
  # Simulate the billing probe marking Gemini unavailable at startup.
  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="false"
  export GEMINI_AVAILABLE="false"
  export COPILOT_AVAILABLE="true"
}
EOF

  # Track every engine that review-one-pr.sh is called with.
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$REVIEW_ENGINE" >> engine_calls.txt
exit 0
EOF
  chmod +x "scripts/review-one-pr.sh"

  export REVIEW_ENGINE="gemini"
  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 0 ]
  # review-one-pr.sh must have been called, and never as gemini.
  [ -f engine_calls.txt ]
  ! grep -q "^gemini$" engine_calls.txt
  grep -q "^copilot$" engine_calls.txt
  [[ "$output" == *"unavailable"* ]]
}

@test "batch: primary Gemini with GEMINI_AVAILABLE=false and COPILOT_AVAILABLE=false aborts with error" {
  # When both Gemini and Copilot are unavailable, the batch should abort rather
  # than switch to an unusable engine and fail on the first PR.
  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="false"
  export GEMINI_AVAILABLE="false"
  export COPILOT_AVAILABLE="false"
}
EOF

  export REVIEW_ENGINE="gemini"
  run bash scripts/review-batch.sh

  echo "$output" >&2

  [ "$status" -eq 1 ]
  [[ "$output" == *"Copilot fallback also unavailable"* ]]
}
