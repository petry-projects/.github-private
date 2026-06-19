#!/usr/bin/env bats
# Unit tests for scripts/apply-repo-settings.sh
#
# Run with: bats tests/test_apply_repo_settings.bats
# Install bats: https://github.com/bats-core/bats-core

SCRIPT="$(dirname "$BATS_TEST_FILENAME")/../scripts/apply-repo-settings.sh"

setup() {
  source "$SCRIPT"
  GH_LOG="$(mktemp)"

  # Preference JSON fixtures
  PREFS_BOTH_ENABLED='{"preferences":{"auto_trigger_checks":[{"app_id":1236702,"setting":true},{"app_id":347564,"setting":true}]}}'
  PREFS_BOTH_DISABLED='{"preferences":{"auto_trigger_checks":[{"app_id":1236702,"setting":false},{"app_id":347564,"setting":false}]}}'
  PREFS_MIXED='{"preferences":{"auto_trigger_checks":[{"app_id":1236702,"setting":true},{"app_id":347564,"setting":false}]}}'
  PREFS_EMPTY_ARRAY='{"preferences":{"auto_trigger_checks":[]}}'
  PREFS_EMPTY_OBJ='{}'

  # Default: return empty prefs for GET; override MOCK_PREFS per-test
  MOCK_PREFS="$PREFS_EMPTY_ARRAY"

  # Mock gh: log all calls, return MOCK_PREFS for GET check-suites calls,
  # MOCK_REPOS for repo-list calls.
  # Only consume stdin for PATCH calls (--input -); GET calls must not read
  # stdin because they may be called inside a while loop whose stdin is a
  # process-substitution pipe — consuming it would swallow subsequent lines.
  # Conditionally read stdin only when available (not a TTY) to prevent hangs.
  gh() {
    local stdin_body=""
    if [[ "$*" == *"--input -"* ]] && [[ ! -t 0 ]]; then
      stdin_body=$(cat)
    fi
    printf '%s STDIN=%s\n' "$*" "$stdin_body" >> "$GH_LOG"
    # $2 == "-X" means a method flag follows (e.g. -X PATCH) — skip returning body
    if [[ "${2:-}" != "-X" ]] && [[ "$*" == *"check-suites/preferences"* ]]; then
      printf '%s\n' "${MOCK_PREFS}"
    elif [[ "${1:-}" == "repo" ]] && [[ "${2:-}" == "list" ]]; then
      printf '%s\n' "${MOCK_REPOS:-}"
    fi
  }
  export -f gh
  export GH_LOG PREFS_BOTH_ENABLED PREFS_BOTH_DISABLED PREFS_MIXED
  export PREFS_EMPTY_ARRAY PREFS_EMPTY_OBJ MOCK_PREFS

  ORG="test-org"
  unset REPO
  unset DEV_LEAD_DRY_RUN
}

teardown() {
  rm -f "${GH_LOG:-}"
}

# ---------------------------------------------------------------------------
# RS_DISABLE_APP_IDS — must include both target apps
# ---------------------------------------------------------------------------

@test "RS_DISABLE_APP_IDS includes Claude app_id 1236702" {
  [[ " ${RS_DISABLE_APP_IDS[*]} " == *" 1236702 "* ]]
}

@test "RS_DISABLE_APP_IDS includes CodeRabbit app_id 347564" {
  [[ " ${RS_DISABLE_APP_IDS[*]} " == *" 347564 "* ]]
}

# ---------------------------------------------------------------------------
# rs_auto_trigger_status — pure JSON parser
# ---------------------------------------------------------------------------

@test "rs_auto_trigger_status: returns true for enabled app" {
  run rs_auto_trigger_status \
    '{"preferences":{"auto_trigger_checks":[{"app_id":1236702,"setting":true}]}}' \
    1236702
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "rs_auto_trigger_status: returns false for disabled app" {
  run rs_auto_trigger_status \
    '{"preferences":{"auto_trigger_checks":[{"app_id":1236702,"setting":false}]}}' \
    1236702
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "rs_auto_trigger_status: returns missing when app absent" {
  run rs_auto_trigger_status \
    '{"preferences":{"auto_trigger_checks":[{"app_id":347564,"setting":true}]}}' \
    1236702
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "rs_auto_trigger_status: returns missing for empty array" {
  run rs_auto_trigger_status "$PREFS_EMPTY_ARRAY" 1236702
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "rs_auto_trigger_status: returns missing for empty object" {
  run rs_auto_trigger_status "$PREFS_EMPTY_OBJ" 1236702
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

# ---------------------------------------------------------------------------
# rs_apply_repo — parameter guard
# ---------------------------------------------------------------------------

@test "rs_apply_repo: returns non-zero when called with empty repo argument" {
  run rs_apply_repo ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# rs_apply_repo — dry-run mode
# ---------------------------------------------------------------------------

@test "rs_apply_repo dry-run: exits 0" {
  export DEV_LEAD_DRY_RUN=true
  run rs_apply_repo "test-org/myrepo"
  [ "$status" -eq 0 ]
}

@test "rs_apply_repo dry-run: makes no API calls" {
  export DEV_LEAD_DRY_RUN=true
  run rs_apply_repo "test-org/myrepo"
  [ ! -s "$GH_LOG" ]
}

@test "rs_apply_repo dry-run: prints intent mentioning the repo" {
  export DEV_LEAD_DRY_RUN=true
  run rs_apply_repo "test-org/myrepo"
  [[ "$output" == *"myrepo"* ]]
}

# ---------------------------------------------------------------------------
# rs_apply_repo — live mode, both apps enabled
# ---------------------------------------------------------------------------

@test "rs_apply_repo live: calls GET preferences for the repo" {
  export MOCK_PREFS="$PREFS_BOTH_ENABLED"
  run rs_apply_repo "test-org/myrepo"
  grep -q "check-suites/preferences" "$GH_LOG"
}

@test "rs_apply_repo live: calls PATCH when app has setting=true" {
  export MOCK_PREFS="$PREFS_BOTH_ENABLED"
  run rs_apply_repo "test-org/myrepo"
  grep -q "PATCH" "$GH_LOG"
}

@test "rs_apply_repo live: PATCH body sets setting to false" {
  export MOCK_PREFS="$PREFS_BOTH_ENABLED"
  run rs_apply_repo "test-org/myrepo"
  grep -q '"setting":false' "$GH_LOG"
}

@test "rs_apply_repo live: PATCH body includes Claude app_id 1236702" {
  export MOCK_PREFS="$PREFS_BOTH_ENABLED"
  run rs_apply_repo "test-org/myrepo"
  grep "PATCH" "$GH_LOG" | grep -q "1236702"
}

# ---------------------------------------------------------------------------
# rs_apply_repo — live mode, API failure
# ---------------------------------------------------------------------------

@test "rs_apply_repo live: returns 1 when GET check-suite preferences fails" {
  gh() {
    if [[ "$*" == *"check-suites/preferences"* ]]; then
      echo "[error] API failure" >&2
      return 1
    fi
  }
  export -f gh
  run rs_apply_repo "test-org/myrepo"
  [ "$status" -eq 1 ]
}

@test "rs_apply_repo live: unreadable preferences warning names repo scope and accessibility" {
  gh() {
    if [[ "$*" == *"check-suites/preferences"* ]]; then
      echo "[error] HTTP 404" >&2
      return 1
    fi
  }
  export -f gh
  run rs_apply_repo "test-org/myrepo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'repo' scope"* ]]
  [[ "$output" == *"accessible"* ]]
}

# ---------------------------------------------------------------------------
# rs_apply_repo — live mode, already compliant
# ---------------------------------------------------------------------------

@test "rs_apply_repo live: no PATCH when both apps already disabled" {
  export MOCK_PREFS="$PREFS_BOTH_DISABLED"
  run rs_apply_repo "test-org/myrepo"
  ! grep -q "PATCH" "$GH_LOG"
}

@test "rs_apply_repo live: no PATCH when apps missing from preferences" {
  export MOCK_PREFS="$PREFS_EMPTY_ARRAY"
  run rs_apply_repo "test-org/myrepo"
  ! grep -q "PATCH" "$GH_LOG"
}

# ---------------------------------------------------------------------------
# rs_apply_repo — live mode, mixed state (one enabled, one disabled)
# ---------------------------------------------------------------------------

@test "rs_apply_repo live: PATCHes only the enabled app in mixed state" {
  export MOCK_PREFS="$PREFS_MIXED"
  run rs_apply_repo "test-org/myrepo"
  # Claude (1236702) is enabled → must appear in PATCH
  grep "PATCH" "$GH_LOG" | grep -q "1236702"
  # CodeRabbit (347564) is disabled → must NOT appear in PATCH
  ! ( grep "PATCH" "$GH_LOG" | grep -q "347564" )
}

# ---------------------------------------------------------------------------
# rs_apply_all
# ---------------------------------------------------------------------------

@test "rs_apply_all: calls gh repo list for ORG" {
  export MOCK_REPOS="repo-a
repo-b"
  run rs_apply_all
  grep -q "repo list" "$GH_LOG"
  grep -q "test-org" "$GH_LOG"
}

@test "rs_apply_all: calls check-suites/preferences for each repo" {
  export MOCK_REPOS="repo-a
repo-b"
  run rs_apply_all
  local pref_calls
  pref_calls=$(grep -c "check-suites/preferences" "$GH_LOG")
  [ "$pref_calls" -eq 2 ]
}

@test "rs_apply_all: returns 1 and prints error when gh repo list fails" {
  gh() {
    if [[ "${1:-}" == "repo" ]] && [[ "${2:-}" == "list" ]]; then
      echo "[error] network failure" >&2
      return 1
    fi
  }
  export -f gh
  run rs_apply_all
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to list"* ]]
}

@test "rs_auto_trigger_status: returns missing for empty json string" {
  run rs_auto_trigger_status "" 1236702
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

# ---------------------------------------------------------------------------
# Argument / env-var handling
# ---------------------------------------------------------------------------

@test "exits non-zero when REPO is not set and no positional arg given" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "accepts REPO via environment variable" {
  export REPO="owner/repo"
  export DEV_LEAD_DRY_RUN=true
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "accepts REPO as positional argument" {
  export DEV_LEAD_DRY_RUN=true
  run bash "$SCRIPT" "owner/repo"
  [ "$status" -eq 0 ]
}

@test "positional argument takes precedence over REPO env var" {
  export REPO="env/repo"
  export DEV_LEAD_DRY_RUN=true
  run bash "$SCRIPT" "arg/repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arg/repo"* ]]
}

# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------

@test "dry-run mode prints intent without calling gh api" {
  export REPO="owner/repo"
  export DEV_LEAD_DRY_RUN=true
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ ! -s "$GH_LOG" ]
}

# ---------------------------------------------------------------------------
# Live mode delegates to pp_apply_security_and_analysis
# ---------------------------------------------------------------------------

@test "live mode calls gh api PATCH for the repo" {
  export REPO="owner/repo"
  export DEV_LEAD_DRY_RUN=false
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$GH_LOG" ]
  grep -q "PATCH" "$GH_LOG"
  grep -q "owner/repo" "$GH_LOG"
}

@test "live mode enables vulnerability-alerts prerequisite for dependabot" {
  export REPO="owner/repo"
  export DEV_LEAD_DRY_RUN=false
  run bash "$SCRIPT"
  grep -q "vulnerability-alerts" "$GH_LOG"
}

@test "live mode makes one PATCH call per required setting" {
  export REPO="owner/repo"
  export DEV_LEAD_DRY_RUN=false
  gh() {
    local stdin_body=""
    if [[ "$*" == *"--input -"* ]] && [[ ! -t 0 ]]; then
      stdin_body=$(cat)
    fi
    printf '%s BODY=%s\n' "$*" "$stdin_body" >> "$GH_LOG"
  }
  export -f gh
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  local patch_count
  patch_count=$(grep -c "PATCH" "$GH_LOG")
  # setup() sources apply-repo-settings.sh which lazy-loads push-protection.sh;
  # call the loader here so PP_REQUIRED_SA_SETTINGS is available for comparison.
  # _ensure_push_protection_sourced guards against re-declaring the readonly array.
  _ensure_push_protection_sourced
  local expected_settings_count=${#PP_REQUIRED_SA_SETTINGS[@]}
  [ "$patch_count" -eq "$expected_settings_count" ]
}
