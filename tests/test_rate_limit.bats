#!/usr/bin/env bats
# Unit tests for is_rate_limited and is_cli_error in scripts/engine.sh.
#
# Run with: bats tests/test_rate_limit.bats
# Install bats: https://github.com/bats-core/bats-core

setup() {
  # Source engine.sh to load the functions under test.
  # Set REVIEW_ENGINE to avoid the "unknown engine" error branch.
  export REVIEW_ENGINE="claude"
  # Capture (and discard) the "engine: ..." echo that fires on source.
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# is_rate_limited: must return FALSE (exit 1) for CLI format errors
# ---------------------------------------------------------------------------

@test "is_rate_limited: 'error: Invalid command format.' returns false" {
  run is_rate_limited "error: Invalid command format."
  [ "$status" -eq 1 ]
}

@test "is_rate_limited: 'Did you mean: copilot -i ...' returns false" {
  run is_rate_limited 'Did you mean: copilot -i "suggest -p ..."'
  [ "$status" -eq 1 ]
}

@test "is_rate_limited: 'unknown flag: --foo' returns false" {
  run is_rate_limited "unknown flag: --foo"
  [ "$status" -eq 1 ]
}

@test "is_rate_limited: 'command not found' returns false" {
  run is_rate_limited "command not found"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# is_rate_limited: must return TRUE (exit 0) for actual rate-limit strings
# ---------------------------------------------------------------------------

@test "is_rate_limited: 'overloaded_error' returns true" {
  run is_rate_limited "overloaded_error"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'service overloaded' returns true" {
  run is_rate_limited "service overloaded, please retry"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'overload error' returns true" {
  run is_rate_limited "overload error: backend capacity exceeded"
  [ "$status" -eq 0 ]
}

# Confirm function-overloading terminology does NOT trigger a false positive.
@test "is_rate_limited: 'overloaded operator' returns false (code terminology)" {
  run is_rate_limited "The class has an overloaded operator."
  [ "$status" -eq 1 ]
}

@test "is_rate_limited: 'overloaded methods' returns false (code terminology)" {
  run is_rate_limited "This library supports overloaded methods."
  [ "$status" -eq 1 ]
}

@test "is_rate_limited: 'HTTP 529' returns true" {
  run is_rate_limited "HTTP 529"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: '529' standalone returns true" {
  run is_rate_limited "529"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'rate limit exceeded' returns true" {
  run is_rate_limited "rate limit exceeded"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'quota exceeded' returns true" {
  run is_rate_limited "quota exceeded"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'usage limit reached' returns true" {
  run is_rate_limited "usage limit reached"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'hit your limit' returns true" {
  run is_rate_limited "You have hit your limit for today."
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'too many requests' returns true" {
  run is_rate_limited "Error: too many requests (429)"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: '429' HTTP status returns true" {
  run is_rate_limited "status 429"
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'out of tokens' returns true" {
  run is_rate_limited "You are out of tokens for this period."
  [ "$status" -eq 0 ]
}

@test "is_rate_limited: 'token exhausted' returns true" {
  run is_rate_limited "token budget exhausted"
  [ "$status" -eq 0 ]
}

# Confirm standalone 'exhausted' no longer causes a false positive
@test "is_rate_limited: bare 'exhausted' returns false (was too broad)" {
  run is_rate_limited "retry attempts exhausted"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# is_cli_error: must return TRUE (exit 0) for CLI invocation errors
# ---------------------------------------------------------------------------

@test "is_cli_error: 'error: Invalid command format.' returns true" {
  run is_cli_error "error: Invalid command format."
  [ "$status" -eq 0 ]
}

@test "is_cli_error: 'Did you mean: copilot -i ...' returns true" {
  run is_cli_error 'Did you mean: copilot -i "suggest -p ..."'
  [ "$status" -eq 0 ]
}

@test "is_cli_error: 'unknown flag: --foo' returns true" {
  run is_cli_error "unknown flag: --foo"
  [ "$status" -eq 0 ]
}

@test "is_cli_error: 'command not found' returns true" {
  run is_cli_error "bash: gh: command not found"
  [ "$status" -eq 0 ]
}

@test "is_cli_error: 'unrecognized option' returns true" {
  run is_cli_error "unrecognized option '--verbose'"
  [ "$status" -eq 0 ]
}

@test "is_cli_error: 'invalid argument' returns true" {
  run is_cli_error "invalid argument: 'foobar'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# is_cli_error: must return FALSE (exit 1) for rate-limit strings
# ---------------------------------------------------------------------------

@test "is_cli_error: 'rate limit exceeded' returns false" {
  run is_cli_error "rate limit exceeded"
  [ "$status" -eq 1 ]
}

@test "is_cli_error: 'overloaded_error' returns false" {
  run is_cli_error "overloaded_error"
  [ "$status" -eq 1 ]
}

@test "is_cli_error: 'quota exceeded' returns false" {
  run is_cli_error "quota exceeded"
  [ "$status" -eq 1 ]
}
