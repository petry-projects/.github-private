#!/usr/bin/env bats
# Unit + fixture tests for scripts/validate-workflow-schedules.sh (#724, epic #722).
#
# The schedule-lint enforces the repo-local off-peak scheduling standard
# (AGENTS.md § "Scheduled workflows"): no scheduled workflow may run at minute 0
# (`0 * * * *`). It scans this repo's own workflow/agentic sources
# (.github/workflows/*.yml, .github/workflows/*.md, docs/aw/*.md) and flags any
# schedule.cron whose minute (first) field is 0.
#
# Run with: bats tests/test_validate_workflow_schedules.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/validate-workflow-schedules.sh"
  FIXTURES="$REPO_ROOT/tests/fixtures/schedule-lint"
  # shellcheck source=/dev/null
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# slint_extract_cron — pull the cron string out of a source line
# ---------------------------------------------------------------------------

@test "slint_extract_cron reads a single-quoted cron value" {
  run slint_extract_cron "    - cron: '11 9 * * 1'"
  [ "$status" -eq 0 ]
  [ "$output" = "11 9 * * 1" ]
}

@test "slint_extract_cron reads a double-quoted cron value with trailing comment" {
  run slint_extract_cron '    - cron: "23 */6 * * *" # safety net'
  [ "$status" -eq 0 ]
  [ "$output" = "23 */6 * * *" ]
}

@test "slint_extract_cron reads an unquoted cron value" {
  run slint_extract_cron "    - cron: 0 * * * *"
  [ "$status" -eq 0 ]
  [ "$output" = "0 * * * *" ]
}

@test "slint_extract_cron emits nothing for a line without a cron" {
  run slint_extract_cron "  workflow_dispatch: {}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# slint_minute_is_zero — minute (first) field detection
# ---------------------------------------------------------------------------

@test "slint_minute_is_zero flags a top-of-hour cron" {
  run slint_minute_is_zero "0 * * * *"
  [ "$status" -eq 0 ]
}

@test "slint_minute_is_zero flags minute 0 on any schedule" {
  run slint_minute_is_zero "0 2 * * 0"
  [ "$status" -eq 0 ]
}

@test "slint_minute_is_zero flags minute 00" {
  run slint_minute_is_zero "00 12 * * *"
  [ "$status" -eq 0 ]
}

@test "slint_minute_is_zero flags minute 0 in a list" {
  run slint_minute_is_zero "0,30 12 * * *"
  [ "$status" -eq 0 ]
}

@test "slint_minute_is_zero passes a staggered off-peak minute" {
  run slint_minute_is_zero "11 9 * * 1"
  [ "$status" -ne 0 ]
}

@test "slint_minute_is_zero passes a stepped minute field" {
  run slint_minute_is_zero "2,17,32,47 * * * *"
  [ "$status" -ne 0 ]
}

@test "slint_minute_is_zero passes a step-value minute like */6" {
  run slint_minute_is_zero "*/6 * * * *"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# End-to-end scan over fixture trees (AC #4)
# ---------------------------------------------------------------------------

@test "clean fixture tree passes" {
  run env SCHEDULE_LINT_ROOT="$FIXTURES/clean" bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "reintroduced 0 * * * * cron in a workflow yml is flagged" {
  run env SCHEDULE_LINT_ROOT="$FIXTURES/dirty" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad.yml"* ]]
  [[ "$output" == *"0 * * * *"* ]]
}

@test "minute-0 cron in an agentic *.md source is flagged" {
  run env SCHEDULE_LINT_ROOT="$FIXTURES/dirty-md" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad.md"* ]]
}

# ---------------------------------------------------------------------------
# The live repo tree must pass — Story 1 already moved every cron off minute 0
# ---------------------------------------------------------------------------

@test "the current repository tree passes the schedule-lint" {
  run env SCHEDULE_LINT_ROOT="$REPO_ROOT" bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
