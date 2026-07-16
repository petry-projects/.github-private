#!/usr/bin/env bats
# Tests for scripts/fleet_remediate_gate.sh — the pure go/no-go gate that wires
# the Actions Fleet Monitor's opt-in stub-drift remediation behind a human
# decision (#1152, epic #1148, Phase 4).
#
# The gate decides whether the remediation step runs LIVE or stays DRY_RUN from
# four inputs: the triggering event, the workflow_dispatch `remediate` mode, and
# whether the cross-repo write credential and a pilot repo are present. Live
# remediation requires ALL of: an explicit workflow_dispatch remediate=live, the
# credential, and a configured pilot repo. Any missing precondition degrades to
# dry-run with a ::warning:: and NEVER fails — the monitor must never go live by
# accident nor break on a missing credential.
#
# All assertions here are PURE (no network): they exercise remediate_dry_run over
# synthetic (event, mode, token_present, pilot_present) tuples. Run:
#   bats tests/fleet_remediate_gate.bats

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/fleet_remediate_gate.sh"

setup() {
  # shellcheck source=scripts/fleet_remediate_gate.sh
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Scheduled / workflow_call runs are ALWAYS dry-run (never go live by accident).
# ---------------------------------------------------------------------------

@test "schedule event is always dry-run, even if mode=live (AC #2)" {
  run remediate_dry_run "schedule" "live" "true" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "workflow_call event is always dry-run, even if mode=live (AC #2)" {
  run remediate_dry_run "workflow_call" "live" "true" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# ---------------------------------------------------------------------------
# workflow_dispatch defaults to dry-run; live requires the explicit opt-in.
# ---------------------------------------------------------------------------

@test "workflow_dispatch with mode=dry-run stays dry-run (AC #2)" {
  run remediate_dry_run "workflow_dispatch" "dry-run" "true" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "workflow_dispatch + remediate=live + token + pilot goes LIVE (AC #1/#2)" {
  run remediate_dry_run "workflow_dispatch" "live" "true" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# ---------------------------------------------------------------------------
# Missing precondition on a live request degrades to dry-run + ::warning::,
# never fails (AC #3).
# ---------------------------------------------------------------------------

@test "live requested but credential absent → dry-run + ::warning:: (AC #3)" {
  run remediate_dry_run "workflow_dispatch" "live" "false" "true"
  [ "$status" -eq 0 ]
  # stdout carries the DRY_RUN decision; the warning is on stderr — `run` merges them.
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"credential"* ]]
  # The final decision must still be dry-run.
  [[ "$output" == *"true"* ]]
}

@test "live requested but pilot repo absent → dry-run + ::warning:: (AC #3)" {
  run remediate_dry_run "workflow_dispatch" "live" "true" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"pilot"* ]]
  [[ "$output" == *"true"* ]]
}

@test "a live (false) decision emits NO warning" {
  run remediate_dry_run "workflow_dispatch" "live" "true" "true"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# The gate is usable both sourced (function) and executed (CLI) — the workflow
# step invokes it as `bash scripts/fleet_remediate_gate.sh ...` and captures the
# clean DRY_RUN decision from stdout.
# ---------------------------------------------------------------------------

@test "CLI: emits a clean true/false on stdout with warning routed to stderr" {
  run bash -c 'bash "$1" workflow_dispatch live false true 2>/dev/null' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  # With stderr suppressed, stdout must be exactly the DRY_RUN value.
  [ "$output" = "true" ]
}

@test "CLI: a live-eligible run prints exactly false on stdout" {
  run bash -c 'bash "$1" workflow_dispatch live true true 2>/dev/null' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "module is sourced (not executed): remediate_dry_run is a function" {
  run type -t remediate_dry_run
  [ "$output" = "function" ]
}
