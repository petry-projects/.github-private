#!/usr/bin/env bats
# Unit tests for dev-lead-retry.sh — issue-retry scan/decision logic (#781)
#
# The script guards `main "$@"` behind a BASH_SOURCE check, so sourcing it here
# exposes scan_issue_for_retry / dispatch_issue_retry / open_issue_pr_exists
# without running the org-wide scan.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

setup() {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"

  # Defaults; individual tests override COMMENTS_JSON / OPEN_PR_COUNT / NOW_ISO.
  export COMMENTS_JSON='[]'
  export OPEN_PR_COUNT="0"
  export DRY_RUN="true"
  export NOW_ISO="2026-06-19T00:00:00Z"

  # gh stub: emulates the *post-jq* output the script expects (the real gh
  # applies --jq server/client-side; the stub returns the finished value).
  #   …/issues/<n>/comments  -> $COMMENTS_JSON   (array of comment bodies)
  #   …/pulls?state=open      -> $OPEN_PR_COUNT   (integer)
  #   …/dispatches            -> capture payload to $PAYLOAD_FILE (POST path)
  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*) cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *comments*)   printf '%s' "${COMMENTS_JSON}" ;;
  *pulls*)      printf '%s' "${OPEN_PR_COUNT}" ;;
  *)            echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  source "$RETRY_SCRIPT"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

_marker() {
  # _marker <status> <attempt> [reset]
  local status="$1" attempt="$2" reset="${3:-}"
  local r=""
  [ -n "$reset" ] && r=" reset=${reset}"
  printf '<!-- dev-lead-issue 478 status=%s attempt=%s reason=engine-error run=99%s -->' \
    "$status" "$attempt" "$r"
}

_wmarker() {
  # _wmarker <status> <attempt> <window> [reset]
  local status="$1" attempt="$2" window="$3" reset="${4:-}"
  local r=""
  [ -n "$reset" ] && r=" reset=${reset}"
  printf '<!-- dev-lead-issue 478 status=%s attempt=%s reason=rate-limited run=99%s window=%s -->' \
    "$status" "$attempt" "$r" "$window"
}

# ── scan_issue_for_retry decision matrix ──────────────────────────────────────

@test "retry: failed marker, attempt 1, no PR → dispatches" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 1)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" == *"attempt=1"* ]]
}

@test "retry: rate-limited marker with reset in the future → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker rate-limited 1 2026-06-19T06:00:00Z)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet cleared"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: rate-limited marker with reset in the past → dispatches" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker rate-limited 1 2026-06-18T00:00:00Z)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "retry: attempt at the ceiling (attempt=3, MAX=3) → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 3)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"attempts exhausted"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: newest marker wins (failed attempt=2 supersedes attempt=1)" {
  COMMENTS_JSON="$(jq -nc \
    --arg a "$(_marker failed 1)" \
    --arg b "$(_marker failed 2)" '[$a, $b]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
  [[ "$output" == *"attempt=2"* ]]
}

@test "retry: non-retryable marker (status=needs-human) → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker needs-human 2)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"not retryable"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: an open dev-lead PR already exists → skips" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker failed 1)" '[$m]')"
  OPEN_PR_COUNT="1"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"open dev-lead PR already exists"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: no failure marker → no dispatch (returns 0)" {
  COMMENTS_JSON='["just a normal human comment"]'

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── weekly-window fail-safe suppression (#1863) ───────────────────────────────

@test "reset_suppresses_retry: reset in the future suppresses (any window)" {
  run reset_suppresses_retry "2026-06-19T06:00:00Z" ""
  [ "$status" -eq 0 ]
}

@test "reset_suppresses_retry: empty reset with unknown window does NOT suppress (fail-open preserved)" {
  run reset_suppresses_retry "" ""
  [ "$status" -ne 0 ]
}

@test "reset_suppresses_retry: empty reset with weekly window suppresses (fail-safe)" {
  run reset_suppresses_retry "" "weekly"
  [ "$status" -eq 0 ]
}

@test "reset_suppresses_retry: past reset with weekly window does NOT suppress" {
  run reset_suppresses_retry "2026-06-18T00:00:00Z" "weekly"
  [ "$status" -ne 0 ]
}

@test "retry: weekly rate-limit with reset in the future → skips and logs the weekly window" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_wmarker rate-limited 1 weekly 2026-06-25T11:00:00Z)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"weekly"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "retry: weekly rate-limit with EMPTY reset → suppresses (does not re-dispatch)" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_wmarker rate-limited 1 weekly)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [[ "$output" == *"weekly"* ]]
}

@test "retry: rate-limit with EMPTY reset and no window → still dispatches (fail-open)" {
  COMMENTS_JSON="$(jq -nc --arg m "$(_marker rate-limited 1)" '[$m]')"

  run scan_issue_for_retry "petry-projects/.github" 478

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

# ── dispatch_issue_retry payload ──────────────────────────────────────────────

@test "dispatch: issue-retry payload carries event_type + issue_number + attempt" {
  export DRY_RUN="false"

  run dispatch_issue_retry "petry-projects/.github" 478 2

  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_FILE" ]
  [ "$(jq -r '.event_type' "$PAYLOAD_FILE")" = "dev-lead-issue-retry" ]
  [ "$(jq -r '.client_payload.issue_number' "$PAYLOAD_FILE")" = "478" ]
  [ "$(jq -r '.client_payload.attempt' "$PAYLOAD_FILE")" = "2" ]
}

@test "dispatch: DRY_RUN=true does not POST a dispatch" {
  export DRY_RUN="true"
  rm -f "$PAYLOAD_FILE"

  run dispatch_issue_retry "petry-projects/.github" 478 1

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] would dispatch"* ]]
  [ ! -f "$PAYLOAD_FILE" ]
}
