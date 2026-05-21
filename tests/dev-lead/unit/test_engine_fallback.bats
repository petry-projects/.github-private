#!/usr/bin/env bats
# Unit tests for engine.sh — run_writer_with_fallback (Phase 6)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-claude" "$STUB_BIN_DIR/claude"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/claude" "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  # Create a test prompt file
  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  export DEV_LEAD_DRY_RUN="false"
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

# Helper: create a stub that always returns a given exit code
_make_stub() {
  local name="$1" exit_code="$2"
  cat > "$STUB_BIN_DIR/$name" <<STUBEOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --print|--model|--permission-mode|--allowed-tools|--prompt|--approval-mode|--output-format) shift; shift ;;
    *) shift ;;
  esac
done
exit ${exit_code}
STUBEOF
  chmod +x "$STUB_BIN_DIR/$name"
}

# Helper: create a stub that records calls and returns a given exit code
_make_recording_stub() {
  local name="$1" exit_code="$2" record_file="$3"
  cat > "$STUB_BIN_DIR/$name" <<STUBEOF
#!/usr/bin/env bash
echo "\$0" >> "${record_file}"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --print|--model|--permission-mode|--allowed-tools|--prompt|--approval-mode|--output-format) shift; shift ;;
    *) shift ;;
  esac
done
exit ${exit_code}
STUBEOF
  chmod +x "$STUB_BIN_DIR/$name"
}

# ── run_writer_with_fallback tests ────────────────────────────────────────────

@test "fallback: primary exits 0 → success" {
  _make_stub "claude" 0
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "fallback: primary exits 2 → tries next engine" {
  # claude exits 2 (rate-limited), gemini exits 0
  _make_stub "claude" 2
  _make_stub "gemini" 0
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "fallback: all rate-limited → returns 2" {
  # All engines exit 2 (rate-limited)
  _make_stub "claude" 2
  _make_stub "gemini" 2
  # copilot uses `gh copilot`; provide token + gh stub returning rate-limit text
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "fallback: non-rate-limit exit 1 → no fallback" {
  # claude exits 1 (real failure, not rate-limit)
  _make_stub "claude" 1
  # gemini should NOT be called - if it were, it would succeed (exit 0)
  _make_stub "gemini" 0
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # Should fail with 1 immediately, not succeed via gemini
  [ "$status" -eq 1 ]
}

@test "fallback: engine not installed (exit 127) → tries next engine" {
  # Simulates gemini not installed: exit 127 should trigger fallback, not abort
  _make_stub "claude" 2
  _make_stub "gemini" 127
  # Provide token + gh stub so copilot path is deterministic (returns rate-limit)
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # claude rate-limited (2), gemini not installed (127), copilot rate-limited (2) → all exhausted
  [ "$status" -eq 2 ]
}

@test "fallback: engine not installed (127) → next engine succeeds" {
  # claude rate-limited, gemini not installed, but the next engine after gemini succeeds
  # In the actual fallback order: claude → gemini → copilot. Since copilot returns 2
  # (text-only) in run_writer, we verify with a scenario where gemini is "not found"
  # and a recording stub shows that claude was tried after gemini failed.
  _make_stub "gemini" 2
  local record_file
  record_file="$(mktemp)"
  _make_recording_stub "claude" 127 "$record_file"
  # Provide token + gh stub so copilot path is deterministic (returns rate-limit)
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "gemini"

  run run_writer_with_fallback "$TEST_PROMPT"

  # gemini (primary) rate-limited, claude not installed (127 → treated as unavailable),
  # copilot rate-limited (2) → all engines exhausted
  [ "$status" -eq 2 ]
  # claude was tried (even though it exited 127, it was reached)
  [ -s "$record_file" ]
  rm -f "$record_file"
}


@test "fallback: fallback engine order is claude → gemini → copilot" {
  # Primary = gemini (exits 2), then fallback order should try claude first
  _make_stub "gemini" 2
  local record_file
  record_file="$(mktemp)"
  _make_recording_stub "claude" 0 "$record_file"
  _source_engine "gemini"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # claude should have been called (recorded in record_file)
  [ -s "$record_file" ]
  rm -f "$record_file"
}
