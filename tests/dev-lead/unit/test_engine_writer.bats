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
  if [ -n "${TEST_OWNED_TOKEN_LOG:-}" ] && [ "${TOKEN_LOG_FILE:-}" = "$TEST_OWNED_TOKEN_LOG" ]; then
    rm -f "$TEST_OWNED_TOKEN_LOG"
  fi
  unset TOKEN_LOG_FILE TEST_OWNED_TOKEN_LOG
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
  # When REVIEW_ENGINE=copilot, run_writer calls copilot_chat → gh copilot
  _source_engine "copilot"
  export DEV_LEAD_DRY_RUN=false
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run run_writer "$TEST_PROMPT"

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

# ── rate-limit detection tests ────────────────────────────────────────────────

@test "writer: run_writer returns exit 2 when claude outputs rate-limit text" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # Stub claude: exits 1 and outputs a rate-limit message to stdout
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 2 when gemini outputs rate-limit text" {
  _source_engine "gemini"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/gemini" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded for today"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/gemini"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 2 when gemini writes rate-limit text to stderr" {
  _source_engine "gemini"
  export DEV_LEAD_DRY_RUN=false
  cat > "$STUB_BIN_DIR/gemini" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded for today" >&2
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/gemini"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer returns exit 1 (not 2) for non-rate-limit failure" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  export STUB_ENGINE_EXIT=1
  # Deliberately avoid any rate-limit vocabulary so is_rate_limited returns false
  export STUB_ENGINE_RESPONSE="compilation failed: syntax error on line 42"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 1 ]
}

@test "writer: run_writer writes reset time to /tmp/dev-lead-rate-limit-reset on rate-limit" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  rm -f /tmp/dev-lead-rate-limit-reset
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "You've hit your limit · resets 11:20pm (UTC)"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  [ -f /tmp/dev-lead-rate-limit-reset ]
}

@test "writer: run_writer_with_fallback retries all engines and returns 2 when all rate-limited" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # All engines output rate-limit text and exit 1 → run_writer returns 2 for each
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "rate limit exceeded"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done
  # copilot uses `gh copilot`; provide token + gh stub returning rate-limit text
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"copilot"*) echo "rate limit exceeded"; exit 1 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer_with_fallback skips copilot when token is classic PAT" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  export COPILOT_GITHUB_TOKEN="ghp_classic_token"

  # Claude and Gemini both rate-limit.
  for engine in claude gemini; do
    cat > "$STUB_BIN_DIR/$engine" << 'STUB'
#!/usr/bin/env bash
echo "quota exceeded" >&2
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/$engine"
  done

  # If copilot is invoked, this stub would fail the test via status 1 path.
  cat > "$STUB_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
echo "copilot should have been skipped" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "writer: run_writer_with_fallback succeeds on second engine if first rate-limited" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  # claude is rate-limited; gemini succeeds
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="gemini response ok"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

# ── parse_reset_time tests ─────────────────────────────────────────────────────

@test "parse_reset_time: extracts H:MMpm from 'resets 11:20pm (UTC)'" {
  _source_engine "claude"
  rm -f /tmp/dev-lead-rate-limit-reset

  parse_reset_time "You've hit your limit · resets 11:20pm (UTC)"

  [ -f /tmp/dev-lead-rate-limit-reset ]
  # Should contain a non-empty ISO timestamp
  local result
  result=$(cat /tmp/dev-lead-rate-limit-reset)
  [ -n "$result" ]
  [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "parse_reset_time: writes empty string when no reset time found" {
  _source_engine "claude"
  rm -f /tmp/dev-lead-rate-limit-reset

  parse_reset_time "some error without a reset time"

  [ -f /tmp/dev-lead-rate-limit-reset ]
  local result
  result=$(cat /tmp/dev-lead-rate-limit-reset)
  [ -z "$result" ]
}

# ── token logging tests ───────────────────────────────────────────────────────

@test "token: run_writer writes a record to TOKEN_LOG_FILE when set" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="fixed the bug"
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ -s "$log" ]
  jq empty < "$log"
}

@test "token: run_writer record contains tier=writer" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run_writer "$TEST_PROMPT"

  local tier; tier=$(jq -r '.tier' < "$log")
  [ "$tier" = "writer" ]
}

@test "token: run_writer record contains correct engine and model" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run_writer "$TEST_PROMPT"

  local engine model
  engine=$(jq -r '.engine' < "$log")
  model=$(jq -r '.model' < "$log")
  [ "$engine" = "claude" ]
  [ "$model" = "$ENGINE_ACTION_MODEL" ]
}

@test "token: run_writer is a no-op for token logging when TOKEN_LOG_FILE unset" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  unset TOKEN_LOG_FILE

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "token: dry-run does not write a token record" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=true
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Log should remain empty (dry-run produces no engine call)
  [ ! -s "$log" ]
}

@test "token: run_writer token capture is non-fatal on unwritable log path" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export DEV_LEAD_DRY_RUN=false
  export TOKEN_LOG_FILE="/proc/nonexistent-readonly-path/token.jsonl"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "token: run_triage writes a record to TOKEN_LOG_FILE when set" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="LOW risk verdict"
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  [ -s "$log" ]
  jq empty < "$log"
  local tier; tier=$(jq -r '.tier' < "$log")
  [ "$tier" = "triage" ]
}

@test "token: run_triage is a no-op for token logging when TOKEN_LOG_FILE unset" {
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0
  unset TOKEN_LOG_FILE

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
}

@test "token: run_writer_with_fallback logs the fallback engine (not rate-limited primary)" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  # Make claude output rate-limit text (exit 1 → is_rate_limited → returns 2)
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  # Gemini stub succeeds
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="gemini fixed it"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Token record must exist and belong to the gemini fallback, not claude
  [ -s "$log" ]
  jq empty < "$log"
  local engine tier
  engine=$(jq -r '.engine' < "$log")
  tier=$(jq -r '.tier' < "$log")
  [ "$engine" = "gemini" ]
  [ "$tier" = "writer" ]
}

@test "token: rate-limited primary engine writes NO token record" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false
  local log; log=$(mktemp)
  export TOKEN_LOG_FILE="$log"
  export TEST_OWNED_TOKEN_LOG="$log"

  # Claude outputs rate-limit text → run_writer returns 2 and must not log tokens
  cat > "$STUB_BIN_DIR/claude" << 'STUB'
#!/usr/bin/env bash
echo "hit your limit"
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/claude"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
  # Rate-limited → no successful completion → token log must be empty
  [ ! -s "$log" ]
}
