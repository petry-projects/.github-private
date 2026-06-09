#!/usr/bin/env bats
# Unit tests for the pure decision helpers in scripts/initiative-driver.sh
# (has_label, release_decision, slots_available). The gh-backed flow in main()
# is not exercised here — these cover the gate/blocker/cap logic that decides
# whether a sub-issue is released to dev-lead.
#
# Run with: bats tests/test_initiative_driver.bats

setup() {
  # Sourcing must NOT run main() (source-guard); it only defines the helpers.
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/initiative-driver.sh"
}

# ---------------------------------------------------------------------------
# has_label — exact, comma-separated matching
# ---------------------------------------------------------------------------

@test "has_label: matches an exact label in a CSV list" {
  run has_label "initiative,dev-lead,enhancement" "dev-lead"
  [ "$status" -eq 0 ]
}

@test "has_label: no match returns non-zero" {
  run has_label "initiative,enhancement" "dev-lead"
  [ "$status" -ne 0 ]
}

@test "has_label: is exact, not substring (dev-lead != dev-lead:hands-off)" {
  run has_label "dev-lead:hands-off" "dev-lead"
  [ "$status" -ne 0 ]
}

@test "has_label: empty label set returns non-zero" {
  run has_label "" "dev-lead"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# release_decision — the core gate/blocker logic
# ---------------------------------------------------------------------------

@test "release_decision: no blockers, no special labels => ready" {
  run release_decision "initiative" "" "dev-lead:hands-off" "initiative:hold"
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]
}

@test "release_decision: open blockers => blocked with the list" {
  run release_decision "initiative" "496,505" "dev-lead:hands-off" "initiative:hold"
  [ "$status" -ne 0 ]
  [ "$output" = "blocked:496,505" ]
}

@test "release_decision: hands-off wins even with no blockers" {
  run release_decision "initiative,dev-lead:hands-off" "" "dev-lead:hands-off" "initiative:hold"
  [ "$status" -ne 0 ]
  [ "$output" = "hands-off" ]
}

@test "release_decision: hold wins even with no blockers" {
  run release_decision "initiative,initiative:hold" "" "dev-lead:hands-off" "initiative:hold"
  [ "$status" -ne 0 ]
  [ "$output" = "hold" ]
}

@test "release_decision: hands-off takes precedence over a blocker" {
  run release_decision "dev-lead:hands-off" "496" "dev-lead:hands-off" "initiative:hold"
  [ "$status" -ne 0 ]
  [ "$output" = "hands-off" ]
}

# ---------------------------------------------------------------------------
# slots_available — the max-in-flight cap
# ---------------------------------------------------------------------------

@test "slots_available: cap 2, none in flight => 2" {
  run slots_available 2 0
  [ "$output" = "2" ]
}

@test "slots_available: cap 2, one in flight => 1" {
  run slots_available 2 1
  [ "$output" = "1" ]
}

@test "slots_available: at cap => 0" {
  run slots_available 2 2
  [ "$output" = "0" ]
}

@test "slots_available: over cap never goes negative => 0" {
  run slots_available 2 5
  [ "$output" = "0" ]
}
