#!/usr/bin/env bats
# Round-trip proof (AC #7, #1565): the envelope produced by
# scripts/lib/usage-telemetry.sh must be readable by the SHIPPED public consumer
# `arl_token_budget_gate` / `arl_token_weekly_glide_gate`. An envelope the public
# library cannot read is the single most likely way this ships broken and nobody
# notices — so we feed a real adapter envelope, through the real file seam, into a
# pinned verbatim copy of that library and assert the expected decision=.
#
# No live network: `curl` is mocked and the telemetry is delivered via the
# AGENT_TOKEN_BUDGET_TELEMETRY_FILE seam the library already reads.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ADAPTER="$SCRIPT_DIR/scripts/lib/usage-telemetry.sh"
FIXTURE="$SCRIPT_DIR/tests/fixtures/agent-rate-limit"
CONSUMER="$FIXTURE/agent-rate-limit.sh"

setup() {
  # shellcheck source=scripts/lib/usage-telemetry.sh
  source "$ADAPTER"
  # shellcheck disable=SC1090
  source "$CONSUMER"

  # Point the consumer at the armed fixture config (weekly_all.enabled=true) so
  # both the session and weekly-glide gates are exercisable.
  export AGENT_RATE_LIMITS_CONFIG="$FIXTURE/agent-rate-limits.armed.json"

  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-test"
  export CLAUDE_CODE_VERSION="9.9.9"

  # Deterministic clock shared by the adapter (observed_at) and the consumer
  # (arl_now, honoring SOURCE_NOW). Anchor "now" 7 whole days before the weekly
  # reset so the glide threshold is exactly ceiling - reserve*7 = 100 - 14 = 86.
  WEEKLY_RESET="2026-09-22T16:00:00Z"
  NOW_EPOCH="$(( $(date -u -d "$WEEKLY_RESET" +%s) - 7 * 86400 ))"
  export USAGE_TELEMETRY_NOW="$NOW_EPOCH"
  export SOURCE_NOW="$NOW_EPOCH"

  MOCK_CURL="$BATS_TEST_TMPDIR/curl-mock.sh"
  cat > "$MOCK_CURL" << 'MOCK'
#!/usr/bin/env bash
set -euo pipefail
hdrfile=""; prev=""
for arg in "$@"; do
  if [ "$prev" = "-D" ]; then hdrfile="$arg"; fi
  prev="$arg"
done
status="${MOCK_STATUS:-200}"
if [ -n "$hdrfile" ]; then
  { printf 'HTTP/2 %s\r\n' "$status"
    if [ -n "${MOCK_RETRY_AFTER:-}" ]; then printf 'retry-after: %s\r\n' "$MOCK_RETRY_AFTER"; fi
    printf '\r\n'; } > "$hdrfile"
fi
printf '%s' "${MOCK_BODY:-}"
printf '\n%s' "$status"
MOCK
  chmod +x "$MOCK_CURL"
  export USAGE_TELEMETRY_CURL="$MOCK_CURL"

  TELE_FILE="$BATS_TEST_TMPDIR/telemetry.json"
}

# Fetch via the adapter (mocked curl) and publish to the library's file seam.
_fetch_and_publish() {
  local envelope
  envelope="$(usage_telemetry_fetch)"
  usage_telemetry_publish_file "$envelope" "$TELE_FILE" >/dev/null
}

_body_session() {
  # $1 = percent
  printf '{"limits":[{"kind":"session","percent":%s,"is_active":true,"resets_at":"2026-09-21T05:20:00Z"}]}' "$1"
}
_body_weekly() {
  # $1 = percent
  printf '{"limits":[{"kind":"weekly_all","percent":%s,"is_active":true,"resets_at":"%s"}]}' "$1" "$WEEKLY_RESET"
}

@test "session gate DEFERS when the adapter reports session >= 90%" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body_session 95)"; export MOCK_BODY
  _fetch_and_publish
  run arl_token_budget_gate session
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "session gate ALLOWS when the adapter reports session < 90%" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body_session 33)"; export MOCK_BODY
  _fetch_and_publish
  run arl_token_budget_gate session
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "weekly glide gate DEFERS when weekly_all >= glide threshold (86% at 7 days out)" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body_weekly 90)"; export MOCK_BODY
  _fetch_and_publish
  run arl_token_weekly_glide_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "weekly glide gate ALLOWS when weekly_all < glide threshold" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_body_weekly 80)"; export MOCK_BODY
  _fetch_and_publish
  run arl_token_weekly_glide_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "fresh 429 with retry-after DEFERS via the shared transport decision" {
  export MOCK_STATUS=429
  export MOCK_RETRY_AFTER=300
  export MOCK_BODY='{"error":"rate_limited"}'
  _fetch_and_publish
  run arl_token_budget_gate session
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "non-200 telemetry ALLOWS (fail-safe) — an endpoint outage never stops the fleet" {
  export MOCK_STATUS=503
  export MOCK_BODY='{"error":"unavailable"}'
  _fetch_and_publish
  run arl_token_budget_gate session
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "missing-window 200 body ALLOWS (fail-safe) — adapter passes it through, library degrades" {
  export MOCK_STATUS=200
  export MOCK_BODY='{"limits":[]}'
  _fetch_and_publish
  run arl_token_budget_gate session
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}
