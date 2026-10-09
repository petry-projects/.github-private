#!/usr/bin/env bats
# Unit tests for the retry cron's Claude usage-window hold (#2139).
#
# Once per cron run, dev-lead-retry.sh asks the usage endpoint (through
# lib/usage-telemetry.sh) whether an account-wide Claude window is exhausted, and
# holds status=rate-limited retries until that window's real resets_at. Window
# fields are read with the public library's arl_token_* helpers (the pinned copy
# in tests/fixtures/agent-rate-limit/). curl is mocked: no live network.

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"
FIXTURE_LIB="$SCRIPT_DIR/tests/fixtures/agent-rate-limit/agent-rate-limit.sh"

NOW="2026-06-19T00:00:00Z"
FUTURE_WEEKLY="2026-06-22T16:00:00Z"
FUTURE_SESSION="2026-06-19T03:00:00Z"
PAST="2026-06-18T20:00:00Z"

setup() {
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  export DRY_RUN="true"
  export NOW_ISO="$NOW"
  export DISPATCH_DELAY_SEC=0
  unset SWEEP_AGENT_REF
  export AGENT_RATE_LIMIT_LIB="$FIXTURE_LIB"
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-test"
  export CLAUDE_CODE_VERSION="9.9.9"

  # curl mock for the adapter: body then the trailing status line its -w adds.
  # Every invocation is counted so the once-per-run contract is assertable.
  export CURL_COUNT="$BATS_TEST_TMPDIR/curl-count"
  : > "$CURL_COUNT"
  cat > "$MOCK_BIN/curl-mock" <<'MOCK'
#!/usr/bin/env bash
echo x >> "$CURL_COUNT"
printf '%s' "${MOCK_BODY:-}"
printf '\n%s' "${MOCK_STATUS:-200}"
MOCK
  chmod +x "$MOCK_BIN/curl-mock"
  export USAGE_TELEMETRY_CURL="$MOCK_BIN/curl-mock"
  export MOCK_STATUS=200
  export MOCK_BODY='{"limits":[]}'

  # gh stub (post-jq values, as in test_dev_lead_retry.bats). Two repos, each with
  # two open dev-lead issues whose newest marker is rate-limited with no reset=
  # (the "unknown reset means retry" path).
  export COMMENTS_JSON
  COMMENTS_JSON="$(jq -nc --arg a "$(_issue_marker 478)" --arg b "$(_issue_marker 479)" '[$a, $b]')"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  "repo list"*)           echo '["petry-projects/a","petry-projects/b"]' ;;
  *"/comments"*)          printf '%s' "${COMMENTS_JSON}" ;;
  *"issues?state=open"*)  echo '[{"number":478},{"number":479}]' ;;
  *)                      echo '[]' ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  source "$RETRY_SCRIPT"
}

_issue_marker() {
  printf '<!-- dev-lead-issue %s status=rate-limited attempt=1 reason=rate-limited run=99 -->' "$1"
}

# _body <window> <percent> <resets_at> [is_active]
_body() {
  jq -cn --arg k "$1" --argjson p "$2" --arg r "$3" --argjson a "${4:-true}" \
    '{limits: [{kind: $k, percent: $p, is_active: $a, resets_at: $r}]}'
}

_curl_calls() { wc -l < "$CURL_COUNT" | tr -d ' '; }

# ── window decisions ─────────────────────────────────────────────────────────

@test "hold: weekly window at limit with a future resets_at suppresses the retry" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"held by the weekly window until 2026-06-22T16:00:00Z"* ]]
  [[ "$output" != *"would dispatch"* ]]
}

@test "hold: weekly window above its limit also suppresses the retry" {
  MOCK_BODY="$(_body weekly_all 104 "$FUTURE_WEEKLY")"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "0" ]
  [[ "$output" != *"would dispatch"* ]]
}

@test "hold: weekly window at limit with a past resets_at does not suppress" {
  MOCK_BODY="$(_body weekly_all 100 "$PAST")"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "hold: a 5-hour window at limit suppresses only until its own reset" {
  MOCK_BODY="$(_body session 100 "$FUTURE_SESSION")"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"held by the 5-hour window until 2026-06-19T03:00:00Z"* ]]

  # After that reset, the same recorded hold no longer applies.
  NOW_ISO="2026-06-19T03:00:01Z"
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "hold: below-limit windows do not suppress" {
  MOCK_BODY="$(jq -cn --arg w "$FUTURE_WEEKLY" --arg s "$FUTURE_SESSION" \
    '{limits: [{kind: "weekly_all", percent: 99.9, is_active: true, resets_at: $w},
               {kind: "session", percent: 42, is_active: true, resets_at: $s}]}')"
  run usage_hold_init
  [[ "$output" == *"no exhausted Claude window"* ]]
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
}

@test "hold: an inactive window at limit does not suppress" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY" false)"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
}

@test "hold: a per-model weekly_scoped window at limit does not suppress (not pause-worthy)" {
  MOCK_BODY="$(_body weekly_scoped 100 "$FUTURE_WEEKLY")"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
}

@test "hold: both windows exhausted honours the later reset" {
  MOCK_BODY="$(jq -cn --arg w "$FUTURE_WEEKLY" --arg s "$FUTURE_SESSION" \
    '{limits: [{kind: "session", percent: 100, is_active: true, resets_at: $s},
               {kind: "weekly_all", percent: 100, is_active: true, resets_at: $w}]}')"
  run usage_hold_init
  [[ "$output" == *"retry-cron: weekly window exhausted, holding retries until 2026-06-22T16:00:00Z"* ]]
}

@test "hold: the flattened seven_day shape is read through the public library too" {
  MOCK_BODY="$(jq -cn --arg w "$FUTURE_WEEKLY" '{seven_day: {percent: 100, resets_at: $w}}')"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "0" ]
}

@test "hold: an unparseable resets_at does not suppress" {
  MOCK_BODY="$(_body weekly_all 100 "not-a-time")"
  usage_hold_init 2>/dev/null
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
}

@test "hold: a failed (non-quota) issue marker is not held" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  usage_hold_init 2>/dev/null
  COMMENTS_JSON="$(jq -nc '["<!-- dev-lead-issue 478 status=failed attempt=1 reason=engine-error run=99 -->"]')"
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
}

# ── PR rate-limit paths ──────────────────────────────────────────────────────

# _scan_pr <json-array-of-bodies>: scan PR 2000 whose comments are exactly those.
_scan_pr() {
  export MARKERS_JSON="$1"
  gh() {
    case "$*" in
      *"/pulls/2000"*) echo '{"state":"open","head":{"sha":"abc"},"labels":[]}' ;;
      *"/comments"*) echo "$MARKERS_JSON" ;;
      *) echo '[]' ;;
    esac
  }
  pr_resume_suppressed() { return 1; }
  post_dispatch_guard() { :; }
  fetch_pr_comment_nodes() { echo '[{"id":"IC_cr"}]'; }
  stale_disposition_needs_dispatch() { return 0; }
  dispatch_reviews_retry() { echo "DISPATCH intent=$4" >&2; }
  dispatch_ci_retry() { echo "DISPATCH ci" >&2; }
  run scan_pr_for_rate_limits "petry-projects/.github-private" 2000
}

@test "hold: a rate-limited fix-reviews marker is held, and so is the #2008 edit re-dispatch" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  usage_hold_init 2>/dev/null
  _scan_pr '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited -->"]'
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"held by the weekly window"* ]]
  [[ "$output" != *"DISPATCH"* ]]
}

@test "hold: a rate-limited fix-ci marker is held" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  usage_hold_init 2>/dev/null
  _scan_pr '["<!-- dev-lead-fix-ci sha=abc status=rate-limited check=lint -->"]'
  [ "${lines[-1]}" = "0" ]
  [[ "$output" == *"fix-ci rate-limit for PR 2000 held by the weekly window"* ]]
  [[ "$output" != *"DISPATCH"* ]]
}

@test "hold: a status=blocked (non-quota) review marker is not held" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  usage_hold_init 2>/dev/null
  _scan_pr '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=blocked reason=checks-pending -->"]'
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

@test "hold: with no hold recorded the PR rate-limit path is unchanged" {
  _scan_pr '["<!-- dev-lead-fix-reviews pr=2000 sha=abc intent=fix-reviews status=rate-limited reason=rate-limited -->"]'
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"DISPATCH intent=fix-reviews"* ]]
}

# ── fail open ────────────────────────────────────────────────────────────────

_assert_fail_open() {
  usage_hold_init 2>/dev/null
  ! usage_hold_active
  run scan_issue_for_retry petry-projects/a 478
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-issue-retry"* ]]
}

@test "fail open: no token" {
  unset CLAUDE_CODE_OAUTH_TOKEN
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  _assert_fail_open
  [ "$(_curl_calls)" = "0" ]
}

@test "fail open: HTTP 429" {
  MOCK_STATUS=429
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  _assert_fail_open
}

@test "fail open: HTTP 500" {
  MOCK_STATUS=500
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  _assert_fail_open
}

@test "fail open: malformed JSON body" {
  MOCK_BODY='{"limits":[{"kind":"weekly_all","percent":100,'
  _assert_fail_open
}

@test "fail open: missing windows" {
  MOCK_BODY='{"limits":[]}'
  _assert_fail_open
  MOCK_BODY='{}'
  _assert_fail_open
}

@test "fail open: public reader library unavailable (no request made)" {
  AGENT_RATE_LIMIT_LIB="$BATS_TEST_TMPDIR/missing.sh"
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  run usage_hold_init
  [[ "$output" == *"usage telemetry reader unavailable"* ]]
  _assert_fail_open
  [ "$(_curl_calls)" = "0" ]
}

@test "fail open: an unknown marker reset still retries (is_reset_in_future default unchanged)" {
  run is_reset_in_future ""
  [ "$status" -eq 1 ]
  run is_reset_in_future "garbage"
  [ "$status" -eq 1 ]
}

# ── once per cron run + log line ─────────────────────────────────────────────

@test "run: the adapter is invoked once per cron run however many items are retried" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  run main
  [ "$status" -eq 0 ]
  [ "$(_curl_calls)" = "1" ]
  [ "$(grep -c 'held by the weekly window' <<< "$output")" -eq 4 ]
  [[ "$output" != *"would dispatch"* ]]

  # Telemetry clear: all four items are retried, still on one request.
  : > "$CURL_COUNT"
  MOCK_BODY="$(_body weekly_all 10 "$FUTURE_WEEKLY")"
  run main
  [ "$status" -eq 0 ]
  [ "$(_curl_calls)" = "1" ]
  [ "$(grep -c 'would dispatch dev-lead-issue-retry' <<< "$output")" -eq 4 ]
}

@test "run: logs the honoured window and its reset once per run" {
  MOCK_BODY="$(_body weekly_all 100 "$FUTURE_WEEKLY")"
  run main
  [ "$status" -eq 0 ]
  [ "$(grep -c '^retry-cron: weekly window exhausted, holding retries until 2026-06-22T16:00:00Z$' <<< "$output")" -eq 1 ]
}

@test "change: no weekday literal in the hold (reset day comes from telemetry)" {
  run grep -niE '(mon|tues|wednes|thurs|fri|satur|sun)day' "$RETRY_SCRIPT" "$BATS_TEST_FILENAME"
  [ "$status" -eq 1 ]
}
