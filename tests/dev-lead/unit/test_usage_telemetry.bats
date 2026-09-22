#!/usr/bin/env bats
# Unit tests for scripts/lib/usage-telemetry.sh (#1565).
#
# The adapter's only job is the TRANSPORT ENVELOPE the shipped public token-budget
# library consumes:
#   { "status": <http_status>, "retry_after": <int?>, "observed_at": <epoch?>, "body": <raw upstream> }
# It must NOT normalize the upstream body (the library owns field extraction — a
# second parser here is the drift failure the issue exists to avoid). These tests
# mock `curl` so no live network is touched, and cover 200 / 429-with-retry-after /
# other-non-200 / malformed / missing-window / missing-token.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/usage-telemetry.sh"

setup() {
  # shellcheck source=scripts/lib/usage-telemetry.sh
  source "$LIB"

  # Deterministic "now" so observed_at is assertable.
  export USAGE_TELEMETRY_NOW=1000000000
  # A non-empty token so the adapter attempts the (mocked) transport.
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-test"
  # Pin the User-Agent version so header assertions are stable.
  export CLAUDE_CODE_VERSION="9.9.9"

  # Install a curl mock that emulates the flags the adapter uses:
  #   -D <file>   → response headers written to <file>
  #   -w '\n%{http_code}' + no -o  → body then a trailing status line on stdout
  # Behavior is driven by MOCK_STATUS / MOCK_BODY / MOCK_RETRY_AFTER.
  MOCK_CURL="$BATS_TEST_TMPDIR/curl-mock.sh"
  cat > "$MOCK_CURL" << 'MOCK'
#!/usr/bin/env bash
set -euo pipefail
hdrfile=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-D" ]; then hdrfile="$arg"; fi
  prev="$arg"
done
status="${MOCK_STATUS:-200}"
if [ -n "$hdrfile" ]; then
  {
    printf 'HTTP/2 %s\r\n' "$status"
    printf 'content-type: application/json\r\n'
    if [ -n "${MOCK_RETRY_AFTER:-}" ]; then
      printf 'retry-after: %s\r\n' "$MOCK_RETRY_AFTER"
    fi
    printf '\r\n'
  } > "$hdrfile"
fi
# Body on stdout, then the trailing status line the adapter's -w produces.
printf '%s' "${MOCK_BODY:-}"
printf '\n%s' "$status"
MOCK
  chmod +x "$MOCK_CURL"
  export USAGE_TELEMETRY_CURL="$MOCK_CURL"
}

# A representative 200 body carrying the ADR §4.1 limits[] shape.
_ok_body() {
  cat << 'JSON'
{"limits":[{"kind":"session","percent":33,"is_active":true,"resets_at":"2026-09-21T05:20:00Z"},{"kind":"weekly_all","percent":79,"is_active":true,"resets_at":"2026-09-22T16:00:00Z"}]}
JSON
}

@test "200: envelope carries status, observed_at, and the body unmodified" {
  export MOCK_STATUS=200
  MOCK_BODY="$(_ok_body)"; export MOCK_BODY
  run usage_telemetry_fetch
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "200" ]
  [ "$(jq -r '.observed_at' <<<"$output")" = "1000000000" ]
  [ "$(jq -r '.retry_after // "absent"' <<<"$output")" = "absent" ]
  # body passes through byte-for-byte (compare canonicalized JSON).
  [ "$(jq -Sc '.body' <<<"$output")" = "$(jq -Sc '.' <<<"$(_ok_body)")" ]
}

@test "429 with retry-after: envelope carries status, retry_after, observed_at" {
  export MOCK_STATUS=429
  export MOCK_RETRY_AFTER=120
  export MOCK_BODY='{"error":"rate_limited"}'
  run usage_telemetry_fetch
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "429" ]
  [ "$(jq -r '.retry_after' <<<"$output")" = "120" ]
  [ "$(jq -r '.observed_at' <<<"$output")" = "1000000000" ]
}

@test "other non-200 (500): status set, no retry_after" {
  export MOCK_STATUS=500
  export MOCK_BODY='{"error":"server_error"}'
  run usage_telemetry_fetch
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "500" ]
  [ "$(jq -r '.retry_after // "absent"' <<<"$output")" = "absent" ]
}

@test "malformed body on a 200: body is omitted (library degrades to allow)" {
  export MOCK_STATUS=200
  export MOCK_BODY='this is not json <<<'
  run usage_telemetry_fetch
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "200" ]
  # A non-JSON upstream body must not corrupt the envelope; it is dropped so the
  # library sees `.body // {}` and fails safe.
  [ "$(jq -r 'has("body")' <<<"$output")" = "false" ]
}

@test "missing-window: a 200 body with no windows passes through unmodified" {
  export MOCK_STATUS=200
  export MOCK_BODY='{"account":"x","limits":[]}'
  run usage_telemetry_fetch
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "200" ]
  [ "$(jq -Sc '.body' <<<"$output")" = '{"account":"x","limits":[]}' ]
}

@test "missing token: status=0 envelope, transport never attempted" {
  unset CLAUDE_CODE_OAUTH_TOKEN
  export MOCK_STATUS=200
  export MOCK_BODY="$(_ok_body)"
  # The degraded path logs to stderr; capture stdout only so the envelope parses.
  local envelope
  envelope="$(usage_telemetry_fetch 2>/dev/null)"
  [ "$(jq -r '.status' <<<"$envelope")" = "0" ]
}

@test "user-agent resolves to claude-code/<version> (load-bearing header)" {
  run usage_telemetry_user_agent
  [ "$status" -eq 0 ]
  [ "$output" = "claude-code/9.9.9" ]
}

@test "publish_file writes the envelope and exports the library seam" {
  local env='{"status":200,"observed_at":1000000000,"body":{"limits":[]}}'
  local target="$BATS_TEST_TMPDIR/telemetry.json"
  run usage_telemetry_publish_file "$env" "$target"
  [ "$status" -eq 0 ]
  [ "$output" = "$target" ]
  [ "$(cat "$target")" = "$env" ]
  # Confirm the export happens (run in the current shell, not a subshell).
  usage_telemetry_publish_file "$env" "$target"
  [ "$AGENT_TOKEN_BUDGET_TELEMETRY_FILE" = "$target" ]
}
