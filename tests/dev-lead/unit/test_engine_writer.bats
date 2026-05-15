#!/usr/bin/env bats
# Unit tests for engine.sh — run_writer and run_writer_with_fallback (Phase 2)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  # Create a temp bin dir with stub engines
  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  # Create a test prompt file
  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT
  export STUB_BIN_DIR
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT"
  rm -rf "$STUB_BIN_DIR"
}

# Helper: source engine with a given engine type (suppresses info line)
_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# ── run_writer tests ──────────────────────────────────────────────────────────

@test "writer: run_writer with stub claude exits 0 on success" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "writer: run_writer dry-run exits 0 without calling engine" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  # Remove the claude stub to verify it's not called
  rm -f "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "writer: run_writer dry-run: no engine binary needed" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  # Even without claude in PATH, dry-run should succeed
  local saved_path="$PATH"
  export PATH="/usr/bin:/bin"

  run run_writer "$TEST_PROMPT"

  export PATH="$saved_path"
  [ "$status" -eq 0 ]
}

@test "writer: run_writer exits non-zero on engine failure" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=1
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -ne 0 ]
}

@test "writer: gemini engine exits 0 on success" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "writer: copilot falls back to claude in run_writer (internal)" {
  # When REVIEW_ENGINE=copilot, run_writer internally falls back to claude
  _source_engine "copilot"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false

  run run_writer "$TEST_PROMPT"

  # Should succeed because the internal claude stub is present
  [ "$status" -eq 0 ]
}

@test "writer: run_writer dry-run logs prompt line count" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  printf 'line1\nline2\nline3\n' > "$TEST_PROMPT"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"3 lines"* ]]
}
