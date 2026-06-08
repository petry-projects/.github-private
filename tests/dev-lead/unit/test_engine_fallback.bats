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
  export GEMINI_API_KEY="dummy-test-key"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT"
  rm -f /tmp/dev-lead-failure-reason /tmp/dev-lead-session-output.txt /tmp/dev-lead-rate-limit-reset
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

  # claude rate-limited (2), gemini not installed (127), copilot rate-limited (2) → all exhausted.
  # any_missing=1 (gemini returned 127) → hard failure exit 1 so infra problems surface loudly.
  [ "$status" -eq 1 ]
}

@test "fallback: engine not installed (127) → remaining engines still tried" {
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
  # copilot rate-limited (2) → all engines exhausted.
  # any_missing=1 (claude returned 127) → hard failure exit 1 so infra problems surface loudly.
  [ "$status" -eq 1 ]
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

@test "fallback: gemini skipped when no auth env vars set → falls through to copilot" {
  # claude exits 2 (rate-limited), no GEMINI_API_KEY/GOOGLE_API_KEY set.
  # gemini should be skipped entirely (not called); copilot should succeed.
  _make_stub "claude" 2
  local gemini_record
  gemini_record="$(mktemp)"
  _make_recording_stub "gemini" 1 "$gemini_record"
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "success output"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # gemini must NOT have been called (file should be empty)
  [ ! -s "$gemini_record" ]
  rm -f "$gemini_record"
}

@test "fallback: gemini used normally when GEMINI_API_KEY is set" {
  # claude exits 2 (rate-limited), GEMINI_API_KEY is set → gemini should be tried and succeed.
  # Copilot (now the 1st fallback) is forced to skip so gemini is the one reached.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-api-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  unset GEMINI_API_KEY
}

# ── failure-reason sidecar tests (#781) ───────────────────────────────────────
# run_writer_with_fallback writes a one-line cause class to
# /tmp/dev-lead-failure-reason before each terminal failure return, so callers
# can classify the failure. Because `run` executes in a subshell, the sidecar
# file (not the function's environment) is the contract we assert on.

@test "sidecar: all rate-limited → reason=rate-limited" {
  _make_stub "claude" 2
  _make_stub "gemini" 2
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
  [ "$(cat /tmp/dev-lead-failure-reason)" = "rate-limited" ]
}

@test "sidecar: missing binary (127) → reason=missing-binary" {
  # claude not installed (127); gemini skipped (no key); copilot skipped (classic PAT).
  _make_stub "claude" 127
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 1 ]
  [ "$(cat /tmp/dev-lead-failure-reason)" = "missing-binary" ]
}

@test "sidecar: generic engine error (exit 1) → reason=engine-error" {
  _make_stub "claude" 1
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 1 ]
  [ "$(cat /tmp/dev-lead-failure-reason)" = "engine-error" ]
}

@test "sidecar: stale reason cleared on success" {
  printf 'engine-error\n' > /tmp/dev-lead-failure-reason
  _make_stub "claude" 0
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # The sidecar is removed at the start of every call → no stale reason survives.
  [ ! -f /tmp/dev-lead-failure-reason ]
}

# ── session-output persistence on the rate-limit path (#781, Phase 1A.2) ──────
# Previously run_writer's rate-limit early-return happened BEFORE the
# redact/persist/STEP_SUMMARY block, so a rate-limited run left no session
# output on the run page. The block now runs first, covering all exit paths.

@test "rate-limit path: session output is persisted + written to step summary" {
  # claude detected as rate-limited by CONTENT (exit 1 + rate-limit phrase),
  # which forces run_writer's is_rate_limited early-return path. gemini/copilot
  # are skipped so claude is the only engine and its output is the persisted one.
  cat > "$STUB_BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "RLPROBE: You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"
  unset GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
  export GITHUB_STEP_SUMMARY="$(mktemp)"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  # Persisted session output exists and contains the engine output
  [ -s /tmp/dev-lead-session-output.txt ]
  grep -q "RLPROBE" /tmp/dev-lead-session-output.txt
  # Step summary received the session-output block even on the rate-limit path
  grep -q "Dev-Lead session output" "$GITHUB_STEP_SUMMARY"

  rm -f "$GITHUB_STEP_SUMMARY"
}
