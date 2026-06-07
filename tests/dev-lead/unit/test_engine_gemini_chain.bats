#!/usr/bin/env bats
# Unit tests for engine.sh — Gemini per-tier model overrides + in-engine
# model-tier fallback chain. Mirrors the Claude chain semantics added in #206:
# on rate-limit, walk the chain before declaring the engine rate-limited
# (cross-provider fallback). Required for safe rollout of Gemini 3.5
# model IDs per #382.

bats_require_minimum_version 1.5.0

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

  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  MODEL_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"

  export DEV_LEAD_DRY_RUN="false"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$MODEL_RECORD"
  rm -rf "$STUB_BIN_DIR"
  unset STUB_ENGINE_EXIT_BY_MODEL STUB_ENGINE_RESPONSE_BY_MODEL
  unset STUB_ENGINE_RECORD_MODELS STUB_ENGINE_EXIT STUB_ENGINE_RESPONSE
  unset GEMINI_TRIAGE_MODEL GEMINI_DEEP_MODEL GEMINI_AUDIT_MODEL
  unset GEMINI_ACTION_MODEL GEMINI_SINGLE_MODEL
  unset GEMINI_TRIAGE_MODEL_CHAIN GEMINI_DEEP_MODEL_CHAIN
  unset GEMINI_AUDIT_MODEL_CHAIN GEMINI_ACTION_MODEL_CHAIN
  unset GEMINI_SINGLE_MODEL_CHAIN
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN
  unset CLAUDE_AUDIT_MODEL_CHAIN CLAUDE_ACTION_MODEL_CHAIN
  unset CLAUDE_SINGLE_MODEL_CHAIN
  unset _GEMINI_CHAIN_FB_PREFIX
}

_source_engine() {
  local engine="${1:-gemini}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# ── Per-tier model env overrides ─────────────────────────────────────────────

@test "gemini env: GEMINI_DEEP_MODEL override sets ENGINE_DEEP_MODEL" {
  export GEMINI_DEEP_MODEL="gemini-3.5-flash"
  _source_engine "gemini"

  [ "$ENGINE_DEEP_MODEL" = "gemini-3.5-flash" ]
}

@test "gemini env: GEMINI_TRIAGE_MODEL override sets ENGINE_TRIAGE_MODEL" {
  export GEMINI_TRIAGE_MODEL="gemini-3.5-flash"
  _source_engine "gemini"

  [ "$ENGINE_TRIAGE_MODEL" = "gemini-3.5-flash" ]
}

@test "gemini env: GEMINI_ACTION_MODEL override sets ENGINE_ACTION_MODEL" {
  export GEMINI_ACTION_MODEL="gemini-3.5-pro"
  _source_engine "gemini"

  [ "$ENGINE_ACTION_MODEL" = "gemini-3.5-pro" ]
}

@test "gemini env: GEMINI_AUDIT_MODEL override sets ENGINE_AUDIT_MODEL" {
  export GEMINI_AUDIT_MODEL="gemini-3.5-pro"
  _source_engine "gemini"

  [ "$ENGINE_AUDIT_MODEL" = "gemini-3.5-pro" ]
}

@test "gemini env: GEMINI_SINGLE_MODEL override sets ENGINE_SINGLE_MODEL" {
  export GEMINI_SINGLE_MODEL="gemini-3.5-pro"
  _source_engine "gemini"

  [ "$ENGINE_SINGLE_MODEL" = "gemini-3.5-pro" ]
}

@test "gemini env: defaults unchanged when no overrides set" {
  _source_engine "gemini"

  [ "$ENGINE_TRIAGE_MODEL" = "gemini-2.0-flash" ]
  [ "$ENGINE_DEEP_MODEL" = "gemini-2.5-pro" ]
  [ "$ENGINE_AUDIT_MODEL" = "gemini-2.5-pro" ]
  [ "$ENGINE_ACTION_MODEL" = "gemini-2.5-pro" ]
  [ "$ENGINE_SINGLE_MODEL" = "gemini-2.5-pro" ]
}

# ── _gemini_chain_invoke unit tests ──────────────────────────────────────────

@test "gemini chain: first model succeeds → no fallback attempted" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  ! grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini chain: first model rate-limited → falls through to second" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=pro response"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
  [[ "$output" == *"pro response"* ]]
  [[ "$output" != *"too many requests"* ]]
}

@test "gemini chain: all models rate-limited → returns exit 2" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=quota exceeded"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini chain: non-rate-limit failure → propagates immediately without trying next" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=unexpected internal error|gemini-2.5-pro=should not run"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" \
    "$TEST_PROMPT" 30

  [ "$status" -eq 1 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  ! grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini chain: whitespace and empty entries are tolerated" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=rate limit exceeded|gemini-2.5-pro=ok"

  run _gemini_chain_invoke "  gemini-3.5-flash , , gemini-2.5-pro " \
    "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MODEL_RECORD")" -eq 2 ]
}

@test "gemini chain: empty/whitespace-only chain → config error (rc=1), not rate-limited (rc=2)" {
  _source_engine "gemini"
  run _gemini_chain_invoke "  ,  ,  " "$TEST_PROMPT" 30
  [ "$status" -eq 1 ]
  [[ "$output" == *"no valid model entries"* ]] || [[ "$stderr" == *"no valid model entries"* ]]
}

@test "gemini chain: mktemp failure with rate-limited response → returns exit 2" {
  # Regression: when mktemp fails (full tmpfs, locked-down env), the chain
  # must still detect rate-limit indicators in the engine's output and exit 2
  # so the cross-provider fallback triggers. Without this scan, a 429 in the
  # degraded mktemp-failure branch would surface as a generic non-zero exit
  # and the engine fallback would never fire.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests"

  run _gemini_chain_invoke "gemini-3.5-flash" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
}

@test "gemini chain: mktemp+/tmp both unavailable with rate-limited response → returns exit 2" {
  # Hard-degraded regression: mktemp fails AND the /tmp fallback prefix is
  # unwritable, so the function lands in the last-resort branch with no temp
  # files at all. The branch must still scan the engine's combined output for
  # rate-limit indicators and exit 2 — otherwise a 429 would surface as a
  # generic non-zero exit and the cross-provider fallback never triggers.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  # Point the fallback path prefix at a directory that cannot be created,
  # forcing the `: > "$_fb_stdout"` write to fail and falling through to the
  # bare-passthrough branch.
  export _GEMINI_CHAIN_FB_PREFIX="/nonexistent/dir/gemini-chain"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded"

  run _gemini_chain_invoke "gemini-3.5-flash" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
}

@test "gemini chain: mktemp+/tmp both unavailable, rc=0 with rate-limit text → returns exit 2" {
  # Guard for thread 1 (PRRT_kwDOR9SdIs6EWQKB): rate-limit detection in the
  # last-resort branch must fire regardless of exit code. A provider can return
  # rc=0 with a rate-limit message in the body; without an output-only scan the
  # function would return 0 (false success) and the cross-provider fallback
  # would never trigger.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export _GEMINI_CHAIN_FB_PREFIX="/nonexistent/dir/gemini-chain"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests"

  run _gemini_chain_invoke "gemini-3.5-flash" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
}

@test "gemini chain: mktemp+/tmp both unavailable with non-rate-limit failure → propagates rc" {
  # Symmetric guard for the last-resort branch: a generic non-rate-limit
  # failure must propagate the engine's exit code unchanged. If we
  # mis-classified non-rate-limit errors as rate limits here, every
  # transient failure in the degraded path would falsely trigger the
  # cross-provider fallback.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export _GEMINI_CHAIN_FB_PREFIX="/nonexistent/dir/gemini-chain"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=unexpected internal error"

  run _gemini_chain_invoke "gemini-3.5-flash" "$TEST_PROMPT" 30

  [ "$status" -eq 1 ]
}

@test "gemini chain: mktemp failure, first model rate-limited → continues to second" {
  # Chain contract must hold even when mktemp fails. The fixed /tmp fallback
  # should route through the common loop path so subsequent models are tried
  # rather than returning early on the first rate-limited response.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=pro response"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
  [[ "$output" == *"pro response"* ]]
}

@test "gemini chain: mktemp failure, all models rate-limited → returns exit 2" {
  # Chain contract: return 2 only after exhausting all models, not on the first
  # rate-limit encountered in the mktemp-failure degraded path.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=quota exceeded"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini chain: mktemp+/tmp unavailable, first model rate-limited → continues to second" {
  # Chain contract in the last-resort (in-memory) branch: a rate-limited first
  # model must not short-circuit the chain; the second model must be attempted.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export _GEMINI_CHAIN_FB_PREFIX="/nonexistent/dir/gemini-chain"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded|gemini-2.5-pro=pro response"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
  [[ "$output" == *"pro response"* ]]
}

@test "gemini chain: mktemp+/tmp unavailable, all models rate-limited → returns exit 2" {
  # Last-resort branch must still honor the chain contract: return 2 only after
  # all models in the chain are exhausted, not on the first rate-limit hit.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export _GEMINI_CHAIN_FB_PREFIX="/nonexistent/dir/gemini-chain"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=quota exceeded"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini chain: mktemp+/tmp unavailable, all throttled → output contains rate-limit text for caller detection" {
  # Guard for PRRT_kwDOR9SdIs6FgOrJ: when all models are throttled in the
  # last-resort (in-memory) branch, the function must emit the final throttled
  # response to stdout so callers scanning for rate-limit text can detect the
  # condition and trigger engine fallback rather than treating it as a hard
  # cascade failure.
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export _GEMINI_CHAIN_FB_PREFIX="/nonexistent/dir/gemini-chain"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded|gemini-2.5-pro=429 too many requests"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
  [[ "$output" == *"429 too many requests"* ]] || [[ "$output" == *"quota exceeded"* ]]
}

@test "gemini chain: mktemp+/tmp unavailable, all throttled → reset file not clobbered" {
  # Guard for PRRT_kwDOR9SdIs6FgOrH: parse_reset_time is called inside the loop
  # for each last-resort rate-limited response; the post-loop call to
  # parse_reset_time_files must NOT clobber that written timestamp by passing
  # empty file arguments (which would clear the reset file).
  _source_engine "gemini"
  cat > "$STUB_BIN_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN_DIR/mktemp"
  export _GEMINI_CHAIN_FB_PREFIX="/nonexistent/dir/gemini-chain"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded resets 11:20pm (UTC)"

  rm -f /tmp/dev-lead-rate-limit-reset

  run _gemini_chain_invoke "gemini-3.5-flash" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
  # parse_reset_time was called in the loop and wrote the reset file; it must
  # not be cleared by a post-loop parse_reset_time_files call with no files.
  [ -f /tmp/dev-lead-rate-limit-reset ]
  [ -s /tmp/dev-lead-rate-limit-reset ]
}

@test "gemini chain: multi-model all throttled, earlier reset time preserved when final attempt has none" {
  # Guard for PRRT_kwDOR9SdIs6HokhZ: when the first throttled model includes a
  # reset timestamp ("resets 11:20pm (UTC)") but the final throttled model does
  # not, the function must retain the first model's reset time in
  # /tmp/dev-lead-rate-limit-reset rather than overwriting it with an empty value.
  # An empty reset file causes dev-lead-retry.sh:is_reset_in_future to treat the
  # limit as already cleared and re-dispatch before the quota has actually reset.
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded resets 11:20pm (UTC)|gemini-2.5-pro=quota exceeded"

  rm -f /tmp/dev-lead-rate-limit-reset

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 2 ]
  # The first model's reset time must survive the second model's parse attempt
  # (which would write empty because its output has no reset timestamp).
  [ -f /tmp/dev-lead-rate-limit-reset ]
  [ -s /tmp/dev-lead-rate-limit-reset ]
}

@test "gemini chain: rc=0 with rate-limit body in normal mktemp path → accepted as success" {
  # Guard for comment 3320377426: a valid review response may legitimately contain
  # "429", "quota exceeded", or other rate-limit terms in its findings (e.g. a review
  # of HTTP error-handling code). Scanning rc=0 output would discard valid reviews as
  # false throttles. Only rc!=0 outputs are scanned for rate-limit patterns.
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=0|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=pro response"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  # First model wins immediately on rc=0 — no rate-limit scan for successful exits.
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  [[ "$output" == *"429 too many requests"* ]]
}

@test "gemini chain: all models rc=0 with rate-limit body → first model accepted, returns exit 0" {
  # Follow-on to the rc=0 guard: since rc=0 is accepted without scanning, the first
  # model wins even if its body contains throttle text. This prevents false-positive
  # engine fallbacks for reviews that mention rate-limiting in their findings.
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=0|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.5-pro=quota exceeded"

  run _gemini_chain_invoke "gemini-3.5-flash,gemini-2.5-pro" "$TEST_PROMPT" 30

  [ "$status" -eq 0 ]
  [[ "$output" == *"429 too many requests"* ]]
}

# ── End-to-end: writer uses the chain via GEMINI_ACTION_MODEL_CHAIN ──────────

@test "gemini writer: flash rate-limited → pro tried via GEMINI_ACTION_MODEL_CHAIN" {
  export GEMINI_ACTION_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=too many requests (429)|gemini-2.5-pro=pro did the work"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini writer: both models rate-limited → exit 2 (cross-provider fallback signal)" {
  export GEMINI_ACTION_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=1"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=quota exceeded|gemini-2.5-pro=quota exceeded"

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 2 ]
}

@test "gemini writer: no chain set → single-model behavior unchanged" {
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Exactly one invocation, using the action default
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

# ── End-to-end: agentic respects per-tier chain selection ───────────────────

@test "gemini agentic: deep tier flash rate-limited → pro tried (GEMINI_DEEP_MODEL_CHAIN)" {
  # Override the tier default so the caller's model matches it and chain
  # expansion fires (otherwise the pin-vs-chain rule treats a mismatched
  # model arg as an explicit pin — see "passing tier default model still
  # expands to full chain on rate-limit" guard for the claude branch).
  export GEMINI_DEEP_MODEL="gemini-3.5-flash"
  export GEMINI_DEEP_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=service overload|gemini-2.5-pro=deep result"

  run run_agentic "$TEST_PROMPT" "$ENGINE_DEEP_MODEL" "deep"

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "gemini agentic: explicit model arg differing from tier default is honored (no chain expansion)" {
  export GEMINI_DEEP_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"
  # Tier default stays at the gemini-2.5-pro default (no GEMINI_DEEP_MODEL override).
  _source_engine "gemini"
  export STUB_ENGINE_EXIT=0

  # Caller pins gemini-1.5-pro for deep tier — chain expansion must NOT apply.
  run run_agentic "$TEST_PROMPT" "gemini-1.5-pro" "deep"

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MODEL_RECORD")" -eq 1 ]
  grep -q "gemini-1.5-pro" "$MODEL_RECORD"
  ! grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  ! grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

# ── Triage: gemini chain wiring ─────────────────────────────────────────────

@test "gemini triage: flash rate-limited → pro tried via GEMINI_TRIAGE_MODEL_CHAIN" {
  export GEMINI_TRIAGE_MODEL_CHAIN="gemini-3.5-flash,gemini-2.0-flash"
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.0-flash=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.0-flash=triage clean"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "gemini-3.5-flash" "$MODEL_RECORD"
  grep -q "gemini-2.0-flash" "$MODEL_RECORD"
  [[ "$output" == *"triage clean"* ]]
}

@test "gemini triage: chain fallback warning does not appear in stdout when TOKEN_LOG_FILE is set" {
  # Guard for PRRT_kwDOR9SdIs6GAItQ: when TOKEN_LOG_FILE is set, run_triage
  # redirects _gemini_chain_invoke stdout to a temp file for token logging, then
  # cats it to stdout. If stderr (which carries ::warning:: throttle messages)
  # is also redirected into that file (via 2>&1), the warning prefix is emitted
  # on stdout and corrupts the JSON that review-one-pr.sh captures into
  # TRIAGE_RESULT and then parses with jq. Only stdout must flow to the caller;
  # stderr warnings must stay on stderr.
  #
  # Uses --separate-stderr so $output reflects only stdout (not the merged
  # stdout+stderr that BATS captures by default), making the assertion precise.
  local tok_log
  tok_log="$(mktemp)"
  export TOKEN_LOG_FILE="$tok_log"
  export GEMINI_TRIAGE_MODEL_CHAIN="gemini-3.5-flash,gemini-2.0-flash"
  _source_engine "gemini"
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.5-flash=1|gemini-2.0-flash=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.5-flash=429 too many requests|gemini-2.0-flash=triage result"

  run --separate-stderr run_triage "$TEST_PROMPT"
  rm -f "$tok_log"
  unset TOKEN_LOG_FILE

  [ "$status" -eq 0 ]
  [[ "$output" == *"triage result"* ]]
  [[ "$output" != *"::warning::"* ]]
  [[ "$stderr" == *"::warning::"* ]]
}

# ── Symmetry guard: claude engine doesn't accidentally inherit gemini chains ──

@test "claude engine: GEMINI_*_MODEL_CHAIN does not affect claude invocations" {
  export GEMINI_ACTION_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"
  _source_engine "claude"
  export STUB_ENGINE_EXIT=0

  run run_writer "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  # Should record a claude-family model, never a gemini one
  grep -q "claude-" "$MODEL_RECORD"
  ! grep -q "gemini-" "$MODEL_RECORD"
}

# ── Cross-engine config switch preserves the other engine's chain env ──────

@test "set_engine_config: switching to claude preserves GEMINI_*_MODEL_CHAIN" {
  # Regression guard: run_writer_with_fallback temporarily flips REVIEW_ENGINE
  # to a non-gemini engine and re-runs set_engine_config. If that pass blanks
  # GEMINI_*_MODEL_CHAIN, the staged rollout silently dies for the rest of the
  # session once the engine flips back to gemini.
  export GEMINI_TRIAGE_MODEL_CHAIN="gemini-3.5-flash,gemini-2.0-flash"
  export GEMINI_DEEP_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"
  export GEMINI_AUDIT_MODEL_CHAIN="gemini-3.5-pro,gemini-2.5-pro"
  export GEMINI_ACTION_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"
  export GEMINI_SINGLE_MODEL_CHAIN="gemini-3.5-pro,gemini-2.5-pro"

  _source_engine "gemini"
  export REVIEW_ENGINE="claude"
  set_engine_config

  [ "$GEMINI_TRIAGE_MODEL_CHAIN" = "gemini-3.5-flash,gemini-2.0-flash" ]
  [ "$GEMINI_DEEP_MODEL_CHAIN" = "gemini-3.5-flash,gemini-2.5-pro" ]
  [ "$GEMINI_AUDIT_MODEL_CHAIN" = "gemini-3.5-pro,gemini-2.5-pro" ]
  [ "$GEMINI_ACTION_MODEL_CHAIN" = "gemini-3.5-flash,gemini-2.5-pro" ]
  [ "$GEMINI_SINGLE_MODEL_CHAIN" = "gemini-3.5-pro,gemini-2.5-pro" ]
}

@test "set_engine_config: switching to copilot preserves GEMINI_*_MODEL_CHAIN" {
  export GEMINI_ACTION_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"

  _source_engine "gemini"
  export REVIEW_ENGINE="copilot"
  set_engine_config

  [ "$GEMINI_ACTION_MODEL_CHAIN" = "gemini-3.5-flash,gemini-2.5-pro" ]
}

@test "set_engine_config: gemini→claude→gemini round trip keeps user-set chain intact" {
  # End-to-end mirror of the run_writer_with_fallback sequence: gemini config,
  # transient switch to claude, restore back to gemini. After the round trip
  # the user-configured chain must still drive _gemini_chain_invoke.
  export GEMINI_ACTION_MODEL_CHAIN="gemini-3.5-flash,gemini-2.5-pro"

  _source_engine "gemini"
  export REVIEW_ENGINE="claude"
  set_engine_config
  export REVIEW_ENGINE="gemini"
  set_engine_config

  [ "$GEMINI_ACTION_MODEL_CHAIN" = "gemini-3.5-flash,gemini-2.5-pro" ]
}

@test "set_engine_config: switching to gemini preserves CLAUDE_*_MODEL_CHAIN" {
  # Symmetric guard for the reverse direction: a session that starts on claude
  # with custom CLAUDE_*_MODEL_CHAIN values and falls back to gemini must not
  # have its claude chains silently reset to the defaults on the way back.
  export CLAUDE_TRIAGE_MODEL_CHAIN="claude-haiku-4-5-20251001"
  export CLAUDE_DEEP_MODEL_CHAIN="claude-opus-4-7"
  export CLAUDE_ACTION_MODEL_CHAIN="claude-opus-4-7"

  _source_engine "claude"
  export REVIEW_ENGINE="gemini"
  set_engine_config

  [ "$CLAUDE_TRIAGE_MODEL_CHAIN" = "claude-haiku-4-5-20251001" ]
  [ "$CLAUDE_DEEP_MODEL_CHAIN" = "claude-opus-4-7" ]
  [ "$CLAUDE_ACTION_MODEL_CHAIN" = "claude-opus-4-7" ]
}
