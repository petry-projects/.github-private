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
  rm -f /tmp/dev-lead-timeout-tier /tmp/dev-lead-timeout-budget /tmp/dev-lead-timeout-elapsed
  rm -rf "$STUB_BIN_DIR"
}

# Helper: source engine with a given engine type (suppresses info line)
_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
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
  # claude exits 2 (rate-limited), gemini exits 0. Copilot (now the 1st fallback)
  # is forced to skip via a classic-PAT token so gemini remains the tested fallback.
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export COPILOT_GITHUB_TOKEN="ghp_stub"  # ghp_* → copilot fallback is skipped
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
  # In the actual fallback order: claude → copilot → gemini. Since copilot returns 2
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


@test "fallback: fallback engine order is claude → copilot → gemini" {
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

# ── timeout classification (#1018) ───────────────────────────────────────────
# A per-tier stage timeout (exit 124 from GNU `timeout`) must be classified as a
# distinct, NON-retryable reason=timeout — not engine-error — and must NOT drive
# a same-budget retry on another engine. The tier/budget/elapsed sidecars carry
# the context the needs-human escalation comment surfaces.

@test "sidecar: stage timeout (exit 124) → reason=timeout + tier/budget/elapsed sidecars" {
  _make_stub "claude" 124
  export ACTION_TIMEOUT_SEC=2100
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  # 124 propagates immediately (distinct from engine-error)
  [ "$status" -eq 124 ]
  [ "$(cat /tmp/dev-lead-failure-reason)" = "timeout" ]
  [ "$(cat /tmp/dev-lead-timeout-tier)" = "action" ]
  [ "$(cat /tmp/dev-lead-timeout-budget)" = "2100" ]
  [ -f /tmp/dev-lead-timeout-elapsed ]
}

@test "sidecar: timeout (124) does NOT fall through to another engine (no same-budget retry)" {
  # claude times out (124); NEITHER copilot nor gemini (the remaining engines in
  # the claude→copilot→gemini order) may be tried — each would succeed here if
  # wrongly invoked, so record both and assert neither ran.
  _make_stub "claude" 124
  local gemini_record copilot_record
  gemini_record="$(mktemp)"; copilot_record="$(mktemp)"
  _make_recording_stub "gemini" 0 "$gemini_record"
  # Enable copilot (non-ghp token) and record any `gh copilot` invocation.
  export COPILOT_GITHUB_TOKEN="stub-token"
  cat > "$STUB_BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"copilot"*) echo "\$*" >> "$copilot_record"; echo "success output"; exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN_DIR/gh"
  _source_engine "claude"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 124 ]
  [ "$(cat /tmp/dev-lead-failure-reason)" = "timeout" ]
  # Same-budget retry on ANY fallback engine must NOT happen.
  [ ! -s "$copilot_record" ]
  [ ! -s "$gemini_record" ]
  rm -f "$gemini_record" "$copilot_record"
}

# ── engine-level retry classification (#1028) ─────────────────────────────────
# A per-tier stage timeout (exit 124 from GNU `timeout`) is deterministic — the
# model used its whole budget, so re-running at the SAME budget just times out
# again. is_transient_failure() must therefore NOT classify 124 as retryable,
# while signal kills (137/143) keep their retry behavior. run_triage is the
# in-run retry loop that consumes this classifier; run_writer/run_agentic do not
# retry at all, so dropping 124 from the shared classifier makes every caller
# consistent (no engine-level same-budget retry on a timeout anywhere).

@test "retry: is_transient_failure does NOT classify 124 (timeout) as retryable" {
  _source_engine "claude"

  run is_transient_failure 124
  [ "$status" -ne 0 ]
}

@test "retry: is_transient_failure still classifies 137/143 (signal kills) as retryable" {
  _source_engine "claude"

  run is_transient_failure 137
  [ "$status" -eq 0 ]
  run is_transient_failure 143
  [ "$status" -eq 0 ]
}

@test "retry: stubbed 124 in the retry loop → engine invoked exactly once (no in-run retry)" {
  local record_file
  record_file="$(mktemp)"
  _make_recording_stub "claude" 124 "$record_file"
  export RETRY_BASE_DELAY_SEC=0   # no backoff sleep in tests
  _source_engine "claude"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 124 ]
  # A deterministic per-tier timeout must not be re-run at the same budget.
  [ "$(wc -l < "$record_file")" -eq 1 ]
  rm -f "$record_file"
}

@test "retry: stubbed 137 in the retry loop → still retries (invoked twice), regression guard" {
  local record_file
  record_file="$(mktemp)"
  _make_recording_stub "claude" 137 "$record_file"
  export RETRY_BASE_DELAY_SEC=0   # no backoff sleep in tests
  _source_engine "claude"

  run run_triage "$TEST_PROMPT"

  [ "$status" -eq 137 ]
  # Signal kills stay transient: RETRY_MAX_ATTEMPTS=2 → one retry → two invocations.
  [ "$(wc -l < "$record_file")" -eq 2 ]
  rm -f "$record_file"
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

# ── run-scoped engine exhaustion (#947) ───────────────────────────────────────
# Once an engine is found rate-limited/unavailable during a run, it must NOT be
# re-invoked on later run_writer_with_fallback calls in the same run (the #860
# fix-ci-cycle re-burn), and it must emit AT MOST ONE exhaustion notice per
# engine per run. These tests call the function twice+ in the SAME shell (no
# bats `run`, which forks a subshell) so the process-scoped registry persists.

@test "exhaustion: rate-limited engine is not re-invoked on a later call in the same run" {
  local claude_record gemini_record
  claude_record="$(mktemp "$STUB_BIN_DIR/claude_record.XXXXXX")"
  gemini_record="$(mktemp "$STUB_BIN_DIR/gemini_record.XXXXXX")"
  _make_recording_stub "claude" 2 "$claude_record"   # rate-limited (exit 2)
  _make_recording_stub "gemini" 0 "$gemini_record"   # succeeds
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"              # ghp_* → copilot skipped
  _source_engine "claude"

  local rc1=0 rc2=0
  run_writer_with_fallback "$TEST_PROMPT" || rc1=$?
  run_writer_with_fallback "$TEST_PROMPT" || rc2=$?

  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  # claude invoked once (call 1), then skipped as exhausted on call 2
  [ "$(wc -l < "$claude_record")" -eq 1 ]
  # gemini served both calls
  [ "$(wc -l < "$gemini_record")" -eq 2 ]
}

@test "exhaustion: at most one exhaustion notice per engine across calls in a run" {
  _make_stub "claude" 2
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  _source_engine "claude"

  local errlog
  errlog="$(mktemp "$STUB_BIN_DIR/errlog.XXXXXX")"
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || true
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || true
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || true

  # Exactly one "marked exhausted" notice for claude across all three calls.
  local n
  n=$(grep -c 'claude marked exhausted' "$errlog" || true)
  [ "$n" -eq 1 ]
}

@test "exhaustion: all-engines-exhausted second call still returns 2 (rate-limited)" {
  _make_stub "claude" 2
  _make_stub "gemini" 2
  export GEMINI_API_KEY="test-key"
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

  local rc1=0 rc2=0
  run_writer_with_fallback "$TEST_PROMPT" || rc1=$?
  run_writer_with_fallback "$TEST_PROMPT" || rc2=$?

  [ "$rc1" -eq 2 ]
  [ "$rc2" -eq 2 ]
  [ "$(cat /tmp/dev-lead-failure-reason)" = "rate-limited" ]
}

@test "exhaustion: reset_engine_exhaustion clears the registry" {
  local claude_record
  claude_record="$(mktemp "$STUB_BIN_DIR/claude_record.XXXXXX")"
  _make_recording_stub "claude" 2 "$claude_record"
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  _source_engine "claude"

  run_writer_with_fallback "$TEST_PROMPT" || true    # claude recorded (1), exhausted
  reset_engine_exhaustion
  run_writer_with_fallback "$TEST_PROMPT" || true    # claude re-invoked after reset

  [ "$(wc -l < "$claude_record")" -eq 2 ]
}

@test "exhaustion: headroom-threshold breach exhausts engine permanently" {
  _make_stub "gemini" 0
  export GEMINI_API_KEY="test-key"
  export COPILOT_GITHUB_TOKEN="ghp_stub"
  _source_engine "claude"
  # Override headroom check: claude is always at/above threshold; others have headroom
  check_provider_headroom() { [ "$1" = "claude" ] && return 1; return 0; }

  local errlog
  errlog="$(mktemp "$STUB_BIN_DIR/errlog.XXXXXX")"
  local rc1=0 rc2=0
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || rc1=$?
  run_writer_with_fallback "$TEST_PROMPT" 2>>"$errlog" || rc2=$?

  # gemini serves both calls despite claude's headroom failure
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  # Exactly one exhaustion notice for claude across both calls
  local n
  n=$(grep -c 'claude marked exhausted' "$errlog" || true)
  [ "$n" -eq 1 ]
}
