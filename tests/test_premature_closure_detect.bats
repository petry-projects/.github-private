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
  STUB_BIN_DIR=$(mktemp -d "$BATS_TEST_TMPDIR/stub_bin.XXXXXX")
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

# ---------------------------------------------------------------------------
# Unbacked completion-claim detection (issue #1445) — the OPEN-issue analogue.
# An issue that stays OPEN but carries a "Completed" claim with no merged
# closing/linked PR reads as delivered while nothing landed. premature_closure_*
# only inspects CLOSED issues, so this is a distinct signal.
# ---------------------------------------------------------------------------

@test "unbacked claim: completion claim + no backing PR fires and names the cause" {
  run unbacked_completion_claim_reasons true false
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"no backing PR"* ]]
}

@test "unbacked claim: a merged closing PR suppresses the flag (claim is backed)" {
  run unbacked_completion_claim_reasons true true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unbacked claim: no completion claim never fires" {
  run unbacked_completion_claim_reasons false false
  [ -z "$output" ]
}

@test "unbacked claim: unknown PR state is fail-safe (caller passes true) and suppresses" {
  # The audit passes has_pr=true when it cannot determine the PR state, so an
  # undeterminable lookup never flags — mirror the closed-path fail-safe.
  run unbacked_completion_claim_reasons true unknown
  [ "$status" -eq 0 ]
  # 'unknown' is not truthy, so on its own it would FIRE — proving the caller,
  # not the predicate, must supply the fail-safe. This pins that contract.
  [ -n "$output" ]
}

@test "is_unbacked_completion_claim exit 0 on a candidate, 1 when backed" {
  run is_unbacked_completion_claim true false
  [ "$status" -eq 0 ]
  run is_unbacked_completion_claim true true
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# body_has_completion_claim / claim_is_retracted — comment-body predicates
# ---------------------------------------------------------------------------

@test "body_has_completion_claim matches the durable status=completed marker" {
  run body_has_completion_claim "<!-- dev-lead-issue 100 status=completed pr=42 sha=abc run=9 -->"
  [ "$status" -eq 0 ]
}

@test "body_has_completion_claim matches a legacy '## Completed' heading" {
  run body_has_completion_claim "## Completed — event-first resume for blocked states"
  [ "$status" -eq 0 ]
}

@test "body_has_completion_claim matches a legacy 'Implementation Complete' heading" {
  run body_has_completion_claim "## Dev-Lead: Implementation Complete"
  [ "$status" -eq 0 ]
}

@test "body_has_completion_claim ignores an unrelated comment" {
  run body_has_completion_claim "## Dev-Lead Implementation Plan (in progress)"
  [ "$status" -ne 0 ]
}

@test "claim_is_retracted detects an already-superseded claim" {
  run claim_is_retracted "<!-- dev-lead-claim-retracted -->
> **[Retracted 2026-08-03 — superseded]** ...
## ~~Completed~~ [RETRACTED]"
  [ "$status" -eq 0 ]
  run claim_is_retracted "## Completed — still standing"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# supersede_claim_body — strike-through + dated banner, in place, idempotent
# ---------------------------------------------------------------------------

@test "supersede_claim_body prepends the banner and strikes the first heading" {
  local banner="<!-- dev-lead-claim-retracted -->
> **[Retracted 2026-08-03 — superseded]** claim withdrawn."
  local body="## Completed — event-first resume
all 5 ACs done
726/726 pass"
  run supersede_claim_body "$body" "$banner"
  [ "$status" -eq 0 ]
  # Banner (with machine marker) is prepended
  [[ "$output" == *"<!-- dev-lead-claim-retracted -->"* ]]
  [[ "$output" == *"[Retracted 2026-08-03"* ]]
  # First heading struck in place, body preserved below (record stays legible)
  [[ "$output" == *"~~Completed — event-first resume~~ [RETRACTED]"* ]]
  [[ "$output" == *"726/726 pass"* ]]
}

@test "supersede_claim_body strikes the first heading even when a marker line precedes it" {
  local banner="<!-- dev-lead-claim-retracted -->"
  local body="<!-- dev-lead-issue 100 status=completed pr=42 sha=abc run=9 -->
## Dev-Lead: Implementation Complete — PR #42
durable"
  run supersede_claim_body "$body" "$banner"
  [ "$status" -eq 0 ]
  # The HTML-comment marker line is preserved (not mistaken for the heading)
  [[ "$output" == *"status=completed pr=42"* ]]
  [[ "$output" == *"~~Dev-Lead: Implementation Complete — PR #42~~ [RETRACTED]"* ]]
}

@test "supersede_claim_body result is itself a retracted claim (idempotency guard)" {
  local banner="<!-- dev-lead-claim-retracted -->
> **[Retracted 2026-08-03 — superseded]** withdrawn."
  local out
  out=$(supersede_claim_body "## Completed" "$banner")
  run claim_is_retracted "$out"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# generate_unbacked_claim_report — markdown table / all-clear line
# ---------------------------------------------------------------------------

@test "unbacked report renders each candidate with its link and reason" {
  local f
  f=$(mktemp "$STUB_BIN_DIR/tsv.XXXXXX")
  printf '%s\t%s\t%s\t%s\n' \
    "1407" "https://github.com/o/r/issues/1407" "event-first resume" \
    "carries a completion claim with no merged closing PR (unbacked)" > "$f"
  run generate_unbacked_claim_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#1407"* ]]
  [[ "$output" == *"unbacked"* ]]
}

@test "unbacked report on an empty file prints an all-clear line, not a table" {
  local f
  f=$(mktemp "$STUB_BIN_DIR/tsv.XXXXXX")
  : > "$f"
  run generate_unbacked_claim_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| Issue |"* ]]
}
