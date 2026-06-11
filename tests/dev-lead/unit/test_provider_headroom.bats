#!/usr/bin/env bats
# Unit tests for engine.sh — check_provider_headroom()

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  STUB_BIN_DIR="$(mktemp -d)"
  export STUB_BIN_DIR
  export PATH="$STUB_BIN_DIR:$PATH"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
  rm -rf "$STUB_BIN_DIR"
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# Helper: install a curl stub that outputs given headers and exits with given code
_make_curl_stub() {
  local headers="$1" exit_code="${2:-0}"
  cat > "$STUB_BIN_DIR/curl" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "$headers"
exit $exit_code
STUBEOF
  chmod +x "$STUB_BIN_DIR/curl"
}

# ── fail-open behavior ────────────────────────────────────────────────────────

@test "headroom: returns 0 (proceed) when curl fails entirely" {
  _source_engine "claude"
  # curl returns empty output and exits 1 (network error)
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/curl"

  run check_provider_headroom "claude"
  [ "$status" -eq 0 ]
}

@test "headroom: returns 0 (proceed) when headers are absent" {
  _source_engine "claude"
  # curl succeeds but returns no rate-limit headers
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"

  run check_provider_headroom "claude"
  [ "$status" -eq 0 ]
}

# ── gemini always proceeds ────────────────────────────────────────────────────

@test "headroom: gemini returns 0 unconditionally (no headroom API)" {
  _source_engine "gemini"
  # Even if curl would fail, gemini should short-circuit and return 0
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/curl"

  run check_provider_headroom "gemini"
  [ "$status" -eq 0 ]
}

# ── claude headroom threshold ─────────────────────────────────────────────────

@test "headroom: claude returns 0 when usage is below threshold" {
  _source_engine "claude"
  # remaining=80000, limit=100000 → used_pct=20 < 75 threshold
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-tokens: 80000\r\nx-ratelimit-limit-tokens: 100000\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export ANTHROPIC_API_KEY="dummy"

  run check_provider_headroom "claude"
  [ "$status" -eq 0 ]
}

@test "headroom: claude returns 1 when usage is at or above threshold" {
  _source_engine "claude"
  # remaining=10000, limit=100000 → used_pct=90 >= 75 threshold
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-tokens: 10000\r\nx-ratelimit-limit-tokens: 100000\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export ANTHROPIC_API_KEY="dummy"

  run check_provider_headroom "claude"
  [ "$status" -eq 1 ]
}

@test "headroom: claude returns 1 when usage is exactly at threshold" {
  _source_engine "claude"
  # remaining=25000, limit=100000 → used_pct=75 = threshold
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-tokens: 25000\r\nx-ratelimit-limit-tokens: 100000\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export ANTHROPIC_API_KEY="dummy"

  run check_provider_headroom "claude"
  [ "$status" -eq 1 ]
}

# ── copilot headroom threshold ────────────────────────────────────────────────

@test "headroom: copilot returns 0 when usage is below threshold" {
  _source_engine "copilot"
  # remaining=100, limit=200 → used_pct=50 < 75 threshold
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-requests: 100\r\nx-ratelimit-limit-requests: 200\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export COPILOT_GITHUB_TOKEN="github_pat_testdummyvalue123"

  run check_provider_headroom "copilot"
  [ "$status" -eq 0 ]
}

@test "headroom: copilot returns 1 when usage is above threshold" {
  _source_engine "copilot"
  # remaining=10, limit=200 → used_pct=95 >= 75 threshold
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-requests: 10\r\nx-ratelimit-limit-requests: 200\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export COPILOT_GITHUB_TOKEN="github_pat_testdummyvalue123"

  run check_provider_headroom "copilot"
  [ "$status" -eq 1 ]
}

@test "headroom: copilot returns 0 (proceed) when COPILOT_GITHUB_TOKEN is unset" {
  _source_engine "copilot"
  unset COPILOT_GITHUB_TOKEN
  # curl stub fails so an accidental call would be caught
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/curl"

  run check_provider_headroom "copilot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no valid token"* ]]
}

@test "headroom: copilot returns 0 (proceed) when COPILOT_GITHUB_TOKEN is a placeholder" {
  _source_engine "copilot"
  export COPILOT_GITHUB_TOKEN="dummy"
  # curl stub fails so an accidental call would be caught
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN_DIR/curl"

  run check_provider_headroom "copilot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no valid token"* ]]
}

# ── configurable threshold ────────────────────────────────────────────────────

@test "headroom: DEV_LEAD_USAGE_THRESHOLD=50 skips claude at 60% usage" {
  _source_engine "claude"
  # remaining=40000, limit=100000 → used_pct=60 >= threshold 50
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-tokens: 40000\r\nx-ratelimit-limit-tokens: 100000\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export ANTHROPIC_API_KEY="dummy"
  export DEV_LEAD_USAGE_THRESHOLD=50

  run check_provider_headroom "claude"
  [ "$status" -eq 1 ]
  unset DEV_LEAD_USAGE_THRESHOLD
}

@test "headroom: DEV_LEAD_USAGE_THRESHOLD=90 allows claude at 80% usage" {
  _source_engine "claude"
  # remaining=20000, limit=100000 → used_pct=80 < threshold 90
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nx-ratelimit-remaining-tokens: 20000\r\nx-ratelimit-limit-tokens: 100000\r\n\r\n'
STUB
  chmod +x "$STUB_BIN_DIR/curl"
  export ANTHROPIC_API_KEY="dummy"
  export DEV_LEAD_USAGE_THRESHOLD=90

  run check_provider_headroom "claude"
  [ "$status" -eq 0 ]
  unset DEV_LEAD_USAGE_THRESHOLD
}

# ── headroom check skips engine in run_writer_with_fallback ──────────────────

@test "headroom: exhausted-claude skips to gemini in run_writer_with_fallback" {
  _source_engine "claude"
  export DEV_LEAD_DRY_RUN=false

  # Stub curl: report 95% usage for claude (returns 1 → skip), 0% for others
  cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# claude probe hits api.anthropic.com; gemini/copilot use models.github.ai
if printf '%s' "$*" | grep -q "anthropic.com"; then
  printf 'HTTP/2 200\r\nx-ratelimit-remaining-tokens: 5000\r\nx-ratelimit-limit-tokens: 100000\r\n\r\n'
else
  printf 'HTTP/2 200\r\n\r\n'
fi
STUB
  chmod +x "$STUB_BIN_DIR/curl"

  # Gemini stub succeeds
  cp "$SCRIPT_DIR/tests/dev-lead/fixtures/engines/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/gemini"
  export STUB_ENGINE_EXIT=0
  export GEMINI_API_KEY="dummy-key"
  export ANTHROPIC_API_KEY="dummy"

  local prompt
  prompt="$(mktemp)"
  echo "test" > "$prompt"

  run run_writer_with_fallback "$prompt"

  [ "$status" -eq 0 ]
  rm -f "$prompt"
}
