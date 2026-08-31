#!/usr/bin/env bats
# Unit tests for scripts/lib/hold-gate.sh — the single "human hold" predicate.
#
# A held issue/PR (carrying a fleet hold label) must never be auto-released to
# dev-lead nor auto-picked-up by the agent. This library is the one source of
# truth for that label set, consulted by the initiative driver and the dev-lead
# intent classifier so the check is not re-implemented per caller (#1595).
#
# Run with: bats tests/test_hold_gate.bats

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/hold-gate.sh"

setup() {
  # Start each test from a clean override state.
  unset HOLD_GATE_LABELS
  # shellcheck source=scripts/lib/hold-gate.sh
  source "$LIB"
}

# ── default set ───────────────────────────────────────────────────────────────

@test "default hold set includes needs-human-review (the #1532 label)" {
  run hold_gate_labels
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs-human-review"* ]]
}

@test "default hold set includes the dev-lead stop markers" {
  run hold_gate_labels
  [[ "$output" == *"dev-lead:needs-human"* ]]
  [[ "$output" == *"dev-lead:hands-off"* ]]
}

# ── first-match: present ──────────────────────────────────────────────────────

@test "first_match returns the blocking label and status 0 when held" {
  run hold_gate_first_match $'enhancement\nneeds-human-review\ndev-lead'
  [ "$status" -eq 0 ]
  [ "$output" = "needs-human-review" ]
}

@test "first_match reports a hands-off hold" {
  run hold_gate_first_match $'dev-lead:hands-off\nbug'
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead:hands-off" ]
}

# ── first-match: absent ───────────────────────────────────────────────────────

@test "first_match returns non-zero and no output when not held" {
  run hold_gate_first_match $'enhancement\ndev-lead\ninitiative'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "first_match on an empty label list is not held" {
  run hold_gate_first_match ""
  [ "$status" -ne 0 ]
}

# ── exact-line matching (no substring / regex bleed) ──────────────────────────

@test "first_match does not match a substring of a hold label" {
  # 'needs-human' must NOT match against the distinct label 'needs-humanization'
  run hold_gate_first_match $'needs-humanization\ndev-lead'
  [ "$status" -ne 0 ]
}

@test "first_match treats a hold label literally (dot is not a wildcard)" {
  # A configured hold label containing a regex metachar must match literally.
  HOLD_GATE_LABELS='a.b'
  run hold_gate_first_match $'axb\nother'
  [ "$status" -ne 0 ]
}

# ── override ──────────────────────────────────────────────────────────────────

@test "HOLD_GATE_LABELS override replaces the default set" {
  HOLD_GATE_LABELS='custom:hold another:hold'
  run hold_gate_first_match $'needs-human-review\ndev-lead'
  # needs-human-review is no longer in the (overridden) set
  [ "$status" -ne 0 ]
  run hold_gate_first_match $'custom:hold\ndev-lead'
  [ "$status" -eq 0 ]
  [ "$output" = "custom:hold" ]
}
