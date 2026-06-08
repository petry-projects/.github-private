#!/usr/bin/env bats
# Unit tests for scripts/lib/push-protection.sh
#
# Run with: bats tests/test_push_protection.bats
# Install bats: https://github.com/bats-core/bats-core

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/push-protection.sh"
  # Capture API calls via a temp file so cross-subshell checks work.
  GH_LOG="$(mktemp)"
  gh() { echo "$*" >> "$GH_LOG"; }
  export -f gh
  export GH_LOG
  unset REPO
  unset DEV_LEAD_DRY_RUN
}

teardown() {
  rm -f "${GH_LOG:-}"
}

# ---------------------------------------------------------------------------
# PP_REQUIRED_SA_SETTINGS — the array must include every required key
# ---------------------------------------------------------------------------

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning_push_protection" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning_push_protection "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning_ai_detection" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning_ai_detection "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes secret_scanning_non_provider_patterns" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" secret_scanning_non_provider_patterns "* ]]
}

@test "PP_REQUIRED_SA_SETTINGS includes dependabot_security_updates" {
  [[ " ${PP_REQUIRED_SA_SETTINGS[*]} " == *" dependabot_security_updates "* ]]
}

# ---------------------------------------------------------------------------
# pp_apply_security_and_analysis — dry-run mode
# ---------------------------------------------------------------------------

@test "dry-run skips gh api call" {
  export DEV_LEAD_DRY_RUN=true
  export REPO="owner/repo"
  run pp_apply_security_and_analysis
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "dry-run prints what it would do" {
  export DEV_LEAD_DRY_RUN=true
  export REPO="owner/repo"
  run pp_apply_security_and_analysis
  [[ "$output" == *"dry-run"* ]]
}

# ---------------------------------------------------------------------------
# pp_apply_security_and_analysis — live mode
# ---------------------------------------------------------------------------

@test "live mode calls gh api PATCH for the repo" {
  export DEV_LEAD_DRY_RUN=false
  export REPO="owner/repo"
  run pp_apply_security_and_analysis
  [ "$status" -eq 0 ]
  [ -s "$GH_LOG" ]
  grep -q "api" "$GH_LOG"
  grep -q "PATCH" "$GH_LOG"
  grep -q "owner/repo" "$GH_LOG"
}

@test "live mode errors when REPO is unset" {
  export DEV_LEAD_DRY_RUN=false
  unset REPO
  run pp_apply_security_and_analysis
  [ "$status" -ne 0 ]
}
