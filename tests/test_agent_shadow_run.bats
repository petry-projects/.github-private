#!/usr/bin/env bats
# Tests for scripts/agent-shadow-run.sh — the shadow-mode dual-run orchestrator
# (#605, prerequisite for #587).
#
# Contract: given the stable and next(shadow) verdict JSONs for one PR, the
# orchestrator posts ONLY stable's verdict, logs the shadow verdict (never
# posts it), compares the two, and emits the PASS/FAIL promotion signal to
# GITHUB_ENV. A broken/missing shadow verdict must never block the stable
# review.
#
# Run with: bats tests/test_agent_shadow_run.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/agent-shadow-run.sh"

_write_verdict() {
  local path="$1" decision="$2" risk="$3" body="$4"
  jq -n --arg d "$decision" --arg r "$risk" --arg b "$body" \
    '{decision: $d, risk: $r, summary: "s", findings: [], body: $b}' > "$path"
}

setup() {
  STABLE="$BATS_TEST_TMPDIR/stable.json"
  SHADOW="$BATS_TEST_TMPDIR/shadow.json"
  SHADOW_LOG="$BATS_TEST_TMPDIR/shadow.log"
  GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
  export SHADOW_LOG GITHUB_ENV
}

@test "posts only stable, logs shadow, flags a regression (DRY_RUN)" {
  _write_verdict "$STABLE" escalate HIGH "STABLE-BODY-MARKER"
  _write_verdict "$SHADOW" approve LOW "SHADOW-BODY-MARKER"

  run env PR_URL="https://github.com/o/r/pull/7" \
    STABLE_VERDICT="$STABLE" SHADOW_VERDICT="$SHADOW" \
    DRY_RUN=true PR_HEAD_SHA=abc123 \
    SHADOW_LOG="$SHADOW_LOG" GITHUB_ENV="$GITHUB_ENV" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # Stable's body is what would be posted; the shadow body must never surface
  # in the posted output.
  [[ "$output" == *"STABLE-BODY-MARKER"* ]]
  [[ "$output" != *"SHADOW-BODY-MARKER"* ]]

  # The shadow verdict is logged for audit, never posted.
  grep -qF "SHADOW-BODY-MARKER" "$SHADOW_LOG"

  # The required promotion signal is surfaced.
  grep -qF "SHADOW_CLASSIFICATION=REGRESSION" "$GITHUB_ENV"
  grep -qF "SHADOW_SIGNAL=FAIL" "$GITHUB_ENV"
  grep -qF "SHADOW_REGRESSION=true" "$GITHUB_ENV"
}

@test "a matching shadow emits PASS and sets no regression flag" {
  _write_verdict "$STABLE" approve LOW "STABLE-BODY-MARKER"
  _write_verdict "$SHADOW" approve LOW "SHADOW-BODY-MARKER"

  run env PR_URL="https://github.com/o/r/pull/8" \
    STABLE_VERDICT="$STABLE" SHADOW_VERDICT="$SHADOW" \
    DRY_RUN=true PR_HEAD_SHA=abc123 \
    SHADOW_LOG="$SHADOW_LOG" GITHUB_ENV="$GITHUB_ENV" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -qF "SHADOW_CLASSIFICATION=MATCH" "$GITHUB_ENV"
  grep -qF "SHADOW_SIGNAL=PASS" "$GITHUB_ENV"
  ! grep -qF "SHADOW_REGRESSION=true" "$GITHUB_ENV"
}

@test "a missing shadow verdict does not block the stable review (SKIPPED)" {
  _write_verdict "$STABLE" approve LOW "STABLE-BODY-MARKER"

  run env PR_URL="https://github.com/o/r/pull/9" \
    STABLE_VERDICT="$STABLE" SHADOW_VERDICT="/nonexistent/shadow.json" \
    DRY_RUN=true PR_HEAD_SHA=abc123 \
    SHADOW_LOG="$SHADOW_LOG" GITHUB_ENV="$GITHUB_ENV" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # Stable was still reviewed.
  [[ "$output" == *"STABLE-BODY-MARKER"* ]]
  # Shadow could not be compared → inconclusive, but PASS (never blocks).
  grep -qF "SHADOW_CLASSIFICATION=SKIPPED" "$GITHUB_ENV"
  grep -qF "SHADOW_SIGNAL=PASS" "$GITHUB_ENV"
}

@test "a missing required input (STABLE_VERDICT) fails fast" {
  _write_verdict "$SHADOW" approve LOW "SHADOW-BODY-MARKER"
  run env PR_URL="https://github.com/o/r/pull/10" \
    SHADOW_VERDICT="$SHADOW" \
    DRY_RUN=true PR_HEAD_SHA=abc123 \
    SHADOW_LOG="$SHADOW_LOG" GITHUB_ENV="$GITHUB_ENV" \
    bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "the shadow verdict is never handed to gh (only stable is posted)" {
  _write_verdict "$STABLE" approve LOW "STABLE-BODY-MARKER"
  _write_verdict "$SHADOW" approve LOW "SHADOW-BODY-MARKER"

  MOCK_BIN="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") echo "CLEAN" ;;
  "api "*)   echo "[]" ;;
  *)         echo "[]" ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/gh"

  run env PATH="$MOCK_BIN:$PATH" GH_LOG="$GH_LOG" \
    PR_URL="https://github.com/o/r/pull/11" \
    STABLE_VERDICT="$STABLE" SHADOW_VERDICT="$SHADOW" \
    DRY_RUN=false PR_HEAD_SHA=abc123 \
    SHADOW_LOG="$SHADOW_LOG" GITHUB_ENV="$GITHUB_ENV" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # gh was invoked with stable's body but never with the shadow body.
  grep -qF "STABLE-BODY-MARKER" "$GH_LOG"
  ! grep -qF "SHADOW-BODY-MARKER" "$GH_LOG"

  rm -rf "$MOCK_BIN"
  rm -f "$GH_LOG"
}
