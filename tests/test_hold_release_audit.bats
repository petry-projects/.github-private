#!/usr/bin/env bats
# Unit tests for scripts/lib/hold-release-audit.sh — the pure scanner behind the
# bounded "released while held" audit (#1595 AC #5).
#
# Given one issue's label-event stream, it detects whether the `dev-lead` label
# was applied WHILE `needs-human-review` was attached (a silent release), bounded
# to releases at/after a --since date. #1532 is the known case.
#
# Run with: bats tests/test_hold_release_audit.bats

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/hold-release-audit.sh"

setup() {
  # shellcheck source=scripts/lib/hold-release-audit.sh
  source "$LIB"
}

# needs-human-review applied, THEN dev-lead applied while still held → violation.
@test "scan flags a dev-lead release while needs-human-review was attached (#1532)" {
  events='[
    {"event":"labeled","label":{"name":"needs-human-review"},"created_at":"2026-08-18T22:39:04Z"},
    {"event":"labeled","label":{"name":"dev-lead"},"created_at":"2026-08-30T22:36:54Z"}
  ]'
  run bash -c "source '$LIB'; printf '%s' '$events' | hold_release_audit_scan 2026-08-18"
  [ "$status" -eq 0 ]
  [[ "$output" == *"released_at=2026-08-30T22:36:54Z"* ]]
  [[ "$output" == *"held_since=2026-08-18T22:39:04Z"* ]]
}

# The hold label was removed BEFORE the release → not a violation.
@test "scan does not flag a release after the hold label was removed" {
  events='[
    {"event":"labeled","label":{"name":"needs-human-review"},"created_at":"2026-08-18T22:39:04Z"},
    {"event":"unlabeled","label":{"name":"needs-human-review"},"created_at":"2026-08-20T10:00:00Z"},
    {"event":"labeled","label":{"name":"dev-lead"},"created_at":"2026-08-30T22:36:54Z"}
  ]'
  run bash -c "source '$LIB'; printf '%s' '$events' | hold_release_audit_scan 2026-08-18"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A release that predates the --since window is out of scope (bounded audit).
@test "scan ignores a held release that predates --since" {
  events='[
    {"event":"labeled","label":{"name":"needs-human-review"},"created_at":"2026-08-01T00:00:00Z"},
    {"event":"labeled","label":{"name":"dev-lead"},"created_at":"2026-08-05T00:00:00Z"}
  ]'
  run bash -c "source '$LIB'; printf '%s' '$events' | hold_release_audit_scan 2026-08-18"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# dev-lead applied but the hold label was never present → not a violation.
@test "scan does not flag an ordinary release with no hold label" {
  events='[
    {"event":"labeled","label":{"name":"dev-lead"},"created_at":"2026-08-30T22:36:54Z"}
  ]'
  run bash -c "source '$LIB'; printf '%s' '$events' | hold_release_audit_scan 2026-08-18"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
