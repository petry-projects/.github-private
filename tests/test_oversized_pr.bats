#!/usr/bin/env bats
# Unit tests for is_diff_too_large in scripts/engine.sh.
# Validates that the 406 "diff too large" detection function correctly
# identifies GitHub's hard 300-file unified-diff cap error — distinct from
# rate-limit (429/529) and CLI invocation errors.
#
# Run with: bats tests/test_oversized_pr.bats

setup() {
  export REVIEW_ENGINE="claude"
  # Capture (and discard) the "engine: ..." echo that fires on source.
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/engine.sh" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# is_diff_too_large: must return TRUE (exit 0) for 406 "too many files" errors
# ---------------------------------------------------------------------------

@test "is_diff_too_large: 'HTTP 406' in error text returns true" {
  run is_diff_too_large "could not find pull request diff: HTTP 406"
  [ "$status" -eq 0 ]
}

@test "is_diff_too_large: 'exceeded the maximum number of files' returns true" {
  run is_diff_too_large "Sorry, the diff exceeded the maximum number of files (300)."
  [ "$status" -eq 0 ]
}

@test "is_diff_too_large: full GitHub 406 error message returns true" {
  run is_diff_too_large "could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum number of files (300). Consider using 'List pull requests files' API or locally cloning the repository instead."
  [ "$status" -eq 0 ]
}

@test "is_diff_too_large: 'diff exceeded the maximum' returns true" {
  run is_diff_too_large "the diff exceeded the maximum size limit"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# is_diff_too_large: must return FALSE (exit 1) to avoid false positives
# ---------------------------------------------------------------------------

@test "is_diff_too_large: rate-limit error returns false" {
  run is_diff_too_large "rate limit exceeded"
  [ "$status" -eq 1 ]
}

@test "is_diff_too_large: HTTP 429 error returns false" {
  run is_diff_too_large "Error: too many requests (429)"
  [ "$status" -eq 1 ]
}

@test "is_diff_too_large: CLI invocation error returns false" {
  run is_diff_too_large "error: Invalid command format."
  [ "$status" -eq 1 ]
}

@test "is_diff_too_large: generic diff failure returns false" {
  run is_diff_too_large "gh pr diff: diff not available for this PR"
  [ "$status" -eq 1 ]
}

@test "is_diff_too_large: empty string returns false" {
  run is_diff_too_large ""
  [ "$status" -eq 1 ]
}

@test "is_diff_too_large: unrelated 406 text without diff context returns false" {
  # Guard: a bare '406' not from the diff endpoint should not fire.
  run is_diff_too_large "request returned 406 for some other API"
  [ "$status" -eq 1 ]
}
