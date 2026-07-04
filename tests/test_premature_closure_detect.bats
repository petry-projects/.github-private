#!/usr/bin/env bats
# Unit tests for the premature-closure detector
# (scripts/lib/premature-closure-detect.sh, issue #1077).
#
# #1077: the dev-lead agent closed tracking issues as `completed` without the
# fix actually landing on main — the issue closed, but the problem it described
# was still present, with NO merged PR that resolved it. This library is the
# machine-checkable backstop (recommended action #3): given an issue's already
# gathered close metadata, decide whether it is a premature-closure CANDIDATE.
#
# The signal is the conjunction of THREE conditions — a genuine dev-lead
# premature close, not a normal human close:
#   1. state_reason == completed   (closed as "done", not "not planned")
#   2. no merged closing PR         (nothing actually landed the fix)
#   3. closed within N minutes of open (the fast task-attempt tell)
# All three must hold; the tests pin each boundary and, most importantly, that a
# legitimately-resolved issue (merged closing PR) or a not_planned close does
# NOT false-positive. Detection only — this logic never mutates an issue.
#
# Run with: bats tests/test_premature_closure_detect.bats

setup() {
  STUB_BIN_DIR=$(mktemp -d)
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/premature-closure-detect.sh"
}

teardown() {
  rm -rf "$STUB_BIN_DIR"
}

# ---------------------------------------------------------------------------
# premature_closure_reasons <state_reason> <minutes_open> <has_merged_closing_pr>
# The core three-condition conjunction.
# ---------------------------------------------------------------------------

@test "completed + no merged PR + fast close fires and names the cause" {
  # completed, closed 5 min after open, no merged closing PR
  run premature_closure_reasons completed 5 false
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"no merged closing PR"* ]]
  [[ "$output" == *5* ]]
}

@test "a merged closing PR suppresses the flag (the fix actually landed)" {
  run premature_closure_reasons completed 5 true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "not_planned close never fires (only 'completed' is premature)" {
  run premature_closure_reasons not_planned 5 false
  [ -z "$output" ]
}

@test "empty/unknown state_reason does not fire" {
  run premature_closure_reasons "" 5 false
  [ -z "$output" ]
  run premature_closure_reasons null 5 false
  [ -z "$output" ]
}

@test "closed long after open does NOT fire even without a merged PR" {
  # 240 min open, past the default 30-min window -> not the fast task-attempt tell
  run premature_closure_reasons completed 240 false
  [ -z "$output" ]
}

@test "open time exactly at the window does NOT fire (strict <)" {
  run premature_closure_reasons completed 30 false
  [ -z "$output" ]
}

@test "open time one minute under the window fires" {
  run premature_closure_reasons completed 29 false
  [ -n "$output" ]
}

@test "state_reason matching is case-insensitive" {
  run premature_closure_reasons COMPLETED 5 false
  [ -n "$output" ]
}

@test "has_merged_closing_pr accepts 1/yes as truthy (suppresses)" {
  run premature_closure_reasons completed 5 1
  [ -z "$output" ]
  run premature_closure_reasons completed 5 yes
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# is_premature_closure — boolean wrapper
# ---------------------------------------------------------------------------

@test "is_premature_closure exit 0 on a candidate" {
  run is_premature_closure completed 5 false
  [ "$status" -eq 0 ]
}

@test "is_premature_closure exit 1 when a fix landed" {
  run is_premature_closure completed 5 true
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Env-overridable window (PC_MAX_OPEN_MINUTES)
# ---------------------------------------------------------------------------

@test "PC_MAX_OPEN_MINUTES override widens the window" {
  # Default 30 would not fire at 120 min; a 180-min window does.
  PC_MAX_OPEN_MINUTES=180 run premature_closure_reasons completed 120 false
  [ -n "$output" ]
}

@test "PC_MAX_OPEN_MINUTES override narrows the window" {
  PC_MAX_OPEN_MINUTES=3 run premature_closure_reasons completed 5 false
  [ -z "$output" ]
}

@test "a non-numeric PC_MAX_OPEN_MINUTES falls back to the default (does not zero the window)" {
  # A bad override must not silently set the window to 0 and suppress every flag.
  PC_MAX_OPEN_MINUTES=abc run premature_closure_reasons completed 5 false
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# Defensive: non-numeric / missing inputs degrade, never crash or false-fire
# ---------------------------------------------------------------------------

@test "non-numeric minutes degrades to 0 (still within window -> fires)" {
  run premature_closure_reasons completed "abc" false
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "missing arguments do not crash" {
  run premature_closure_reasons
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# minutes_between <iso_from> <iso_to> — whole minutes, deterministic
# ---------------------------------------------------------------------------

@test "minutes_between computes whole minutes between two ISO timestamps" {
  run minutes_between "2026-07-04T00:00:00Z" "2026-07-04T00:07:00Z"
  [ "$output" -eq 7 ]
}

@test "minutes_between clamps a negative interval to 0" {
  run minutes_between "2026-07-04T01:00:00Z" "2026-07-04T00:00:00Z"
  [ "$output" -eq 0 ]
}

@test "minutes_between degrades to 0 on unparseable input" {
  run minutes_between "not-a-date" "also-bad"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# generate_premature_closure_report — markdown table / all-clear line
# ---------------------------------------------------------------------------

@test "report renders each candidate with its link and reason" {
  local f
  f=$(mktemp "$STUB_BIN_DIR/tsv.XXXXXX")
  printf '%s\t%s\t%s\t%s\n' \
    "421" "https://github.com/o/r/issues/421" "JS modernization" \
    "closed as completed 4m after open with no merged closing PR" > "$f"
  run generate_premature_closure_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#421"* ]]
  [[ "$output" == *"https://github.com/o/r/issues/421"* ]]
  [[ "$output" == *"no merged closing PR"* ]]
}

@test "report on an empty file prints an all-clear line, not a table" {
  local f
  f=$(mktemp "$STUB_BIN_DIR/tsv.XXXXXX")
  : > "$f"
  run generate_premature_closure_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| Issue |"* ]]
}
