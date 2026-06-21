#!/usr/bin/env bats
# Regression tests for engine.sh — COPILOT_API_MODEL must stay bound for the
# cross-engine rubber-duck path even when copilot is NOT the primary engine.
#
# Bug (#881): the claude) branch wires the duck to copilot (DUCK_ENGINE=copilot)
# but COPILOT_API_MODEL's default was assigned ONLY inside the copilot) branch.
# Under a claude-primary review (the default), COPILOT_API_MODEL stayed unset, so
# copilot_chat's bare `$COPILOT_API_MODEL` reference (engine.sh:431/436) aborted
# under `set -u` → invalid duck JSON → tier-2 silently skipped.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"

setup() {
  # Clear any inherited value so engine.sh defaults are evaluated fresh.
  unset COPILOT_API_MODEL
}

teardown() {
  unset COPILOT_API_MODEL
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

@test "duck-model: claude-primary config leaves COPILOT_API_MODEL bound to default" {
  _source_engine "claude"
  # ${VAR-x} (no colon) distinguishes unset from empty: unset → marker.
  [ "${COPILOT_API_MODEL-__UNSET__}" = "openai/o4-mini" ]
}

@test "duck-model: sourcing as claude under set -u does not trip on COPILOT_API_MODEL (engine.sh:431 regression)" {
  # Reproduce the production failure: a bare reference to $COPILOT_API_MODEL
  # under `set -u` (which engine.sh enables) must not abort.
  run bash -c "set -euo pipefail; unset COPILOT_API_MODEL; REVIEW_ENGINE=claude; source '$ENGINE_SCRIPT'; echo \"model=\$COPILOT_API_MODEL\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=openai/o4-mini"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

@test "duck-model: explicit COPILOT_API_MODEL override is honored under claude" {
  export COPILOT_API_MODEL="openai/gpt-5-mini"
  _source_engine "claude"
  [ "$COPILOT_API_MODEL" = "openai/gpt-5-mini" ]
}

@test "duck-model: copilot-primary still binds COPILOT_API_MODEL to default (no regression)" {
  _source_engine "copilot"
  [ "${COPILOT_API_MODEL-__UNSET__}" = "openai/o4-mini" ]
}

@test "duck-model: gemini-primary also leaves COPILOT_API_MODEL bound (latent non-copilot duck path)" {
  _source_engine "gemini"
  [ "${COPILOT_API_MODEL-__UNSET__}" = "openai/o4-mini" ]
}
