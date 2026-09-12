#!/usr/bin/env bats
# Unit tests for the stall-PR detection net (scripts/lib/pr-stall-detect.sh,
# issue #1410 — the instrument built BEFORE the Class-2 timers are narrowed).
#
# This is the mirror image of the runaway detector (#948): the runaway net flags
# a PR with too MUCH automated activity; this net flags a PR with too LITTLE — one
# that is stuck CI-green + REVIEW_REQUIRED with no agent activity and no pending
# triggering event past a configurable threshold. That is the exact failure mode
# the narrowed `dev-lead-retry` / `pr-review-sweep` timers could introduce: a
# genuinely un-eventable transition that no fast path re-fires and (once the cron
# backstop is narrowed) nothing sweeps.
#
# Detection only — the logic here never mutates a PR. The tests pin the boundary
# behaviour (strict >), the env overrides, the human-gate exclusions (AC#2 —
# fail-quiet on intentional stops), and the false-positive guards.
#
# Run with: bats tests/test_pr_stall_detect.bats

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-stall-detect.sh"
}

teardown() {
  :
}

# ---------------------------------------------------------------------------
# pr_stall_reasons — the actionable-but-unresolved stall (green + REVIEW_REQUIRED
# + not reviewed at head + idle past the threshold + not human-gated).
#   args: <ci_status> <review_decision> <reviewed_at_head> <mins_idle> <gated>
# ---------------------------------------------------------------------------

@test "a green REVIEW_REQUIRED PR idle past the threshold fires and names the stall" {
  run pr_stall_reasons passing REVIEW_REQUIRED 0 45 false
  [ "$status" -eq 0 ]
  [[ "$output" == *stall* ]]
  [[ "$output" == *45* ]]
}

@test "idle exactly at the threshold does NOT fire (strict >)" {
  # default STALL_MIN_AGE_MINUTES=30
  run pr_stall_reasons passing REVIEW_REQUIRED 0 30 false
  [ -z "$output" ]
}

@test "idle below the threshold does NOT fire — the in-flight guard" {
  # A PR that just went green 8 min ago is still within the sweep's normal
  # latency; it must not be called a stall.
  run pr_stall_reasons passing REVIEW_REQUIRED 0 8 false
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Only the actionable state can stall — the other states are not "awaiting an
# automated step", so an idle PR in them is not a stall.
# ---------------------------------------------------------------------------

@test "CI pending does NOT fire (still churning toward green)" {
  run pr_stall_reasons pending REVIEW_REQUIRED 0 120 false
  [ -z "$output" ]
}

@test "CI failing does NOT fire (correctly waiting on a fix, not stalled)" {
  run pr_stall_reasons failing REVIEW_REQUIRED 0 120 false
  [ -z "$output" ]
}

@test "already-APPROVED PR does NOT fire (review decision is resolved)" {
  run pr_stall_reasons passing APPROVED 0 120 false
  [ -z "$output" ]
}

@test "already-reviewed-at-head PR does NOT fire (the automated step ran)" {
  run pr_stall_reasons passing REVIEW_REQUIRED 1 120 false
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC#2 — fail-quiet on intentional stops. A human-gated PR is NEVER a stall.
# ---------------------------------------------------------------------------

@test "a human-gated PR does NOT fire even when otherwise stalling" {
  run pr_stall_reasons passing REVIEW_REQUIRED 0 999 true
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# is_pr_stall — boolean wrapper
# ---------------------------------------------------------------------------

@test "is_pr_stall exit 0 when the PR is stalled" {
  run is_pr_stall passing REVIEW_REQUIRED 0 45 false
  [ "$status" -eq 0 ]
}

@test "is_pr_stall exit 1 when the PR is healthy/in-flight" {
  run is_pr_stall passing REVIEW_REQUIRED 0 5 false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Env-overridable threshold (AC#1)
# ---------------------------------------------------------------------------

@test "STALL_MIN_AGE_MINUTES override is respected" {
  STALL_MIN_AGE_MINUTES=120 run pr_stall_reasons passing REVIEW_REQUIRED 0 60 false
  [ -z "$output" ]
  STALL_MIN_AGE_MINUTES=120 run pr_stall_reasons passing REVIEW_REQUIRED 0 121 false
  [[ "$output" == *stall* ]]
}

@test "a non-numeric STALL_MIN_AGE_MINUTES override falls back to the default (never 0)" {
  # A bad override must not silently set the threshold to 0 and flag every green PR.
  STALL_MIN_AGE_MINUTES=abc run pr_stall_reasons passing REVIEW_REQUIRED 0 5 false
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Defensive: non-numeric / missing inputs degrade to no-fire, never error
# ---------------------------------------------------------------------------

@test "non-numeric idle/reviewed inputs degrade to 0 (no crash, no false fire)" {
  run pr_stall_reasons passing REVIEW_REQUIRED "abc" "xyz" false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing arguments degrade to no-fire" {
  run pr_stall_reasons
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# pr_stall_is_gated — the human-gate exclusions (AC#2). Reuses the canonical
# pr_has_escalation_label (needs-human-review) and adds the never-release labels
# and the pr-automation-budget exhaustion marker.
# ---------------------------------------------------------------------------

@test "needs-human-review label is gated (reuses the canonical escalation check)" {
  run pr_stall_is_gated '["needs-human-review"]'
  [ "$status" -eq 0 ]
}

@test "dev-lead:hands-off label is gated" {
  run pr_stall_is_gated '["dev-lead:hands-off"]'
  [ "$status" -eq 0 ]
}

@test "initiative:hold label is gated" {
  run pr_stall_is_gated '["initiative:hold","something-else"]'
  [ "$status" -eq 0 ]
}

@test "the pr-automation-budget exhaustion marker alone does NOT gate stall detection" {
  # The marker is an immutable audit record tracked outside of labels and is
  # intentionally excluded from pr_stall_is_gated, which only inspects labels_json.
  # An empty label set (representing a PR with only the exhaustion marker and no
  # hold labels) must not gate stall detection.
  run pr_stall_is_gated '[]'
  [ "$status" -ne 0 ]
}

@test "a clean PR with no gate label or marker is NOT gated" {
  run pr_stall_is_gated '["enhancement","dev-lead"]' false
  [ "$status" -ne 0 ]
}

@test "empty / malformed labels degrade to not-gated" {
  run pr_stall_is_gated '[]'
  [ "$status" -ne 0 ]
  run pr_stall_is_gated 'not-json'
  [ "$status" -ne 0 ]
}

@test "STALL_HOLD_LABELS override is respected" {
  STALL_HOLD_LABELS="wip do-not-merge" run pr_stall_is_gated '["do-not-merge"]'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# pr_minutes_since — ISO-8601 -> integer minutes since (injected now)
# ---------------------------------------------------------------------------

@test "pr_minutes_since computes whole minutes against an injected now" {
  # last activity 2026-08-01T00:00:00Z, now 2026-08-01T00:45:00Z -> 45m.
  local now last
  last="2026-08-01T00:00:00Z"
  now=$(date -u -d "2026-08-01T00:45:00Z" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-08-01T00:45:00Z" +%s 2>/dev/null)
  run pr_minutes_since "$last" "$now"
  [ "$output" -eq 45 ]
}

@test "pr_minutes_since degrades to 0 on unparseable input" {
  run pr_minutes_since "not-a-date"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# generate_stall_report — renders a table with link + reason per candidate
# ---------------------------------------------------------------------------

@test "generate_stall_report renders each candidate with its link and reason" {
  local f
  f=$(mktemp "$STUB_DIR/tsv.XXXXXX")
  printf '%s\t%s\t%s\t%s\n' \
    "742" "https://github.com/o/r/pull/742" "Green but never re-reviewed" "stalled 90m: CI-green + REVIEW_REQUIRED, no agent activity or pending event (>30m)" \
    > "$f"
  run generate_stall_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#742"* ]]
  [[ "$output" == *"https://github.com/o/r/pull/742"* ]]
  [[ "$output" == *"stalled 90m"* ]]
}

@test "generate_stall_report on an empty file prints an all-clear line, not a table" {
  local f
  f=$(mktemp "$STUB_DIR/tsv.XXXXXX")
  : > "$f"
  run generate_stall_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| PR |"* ]]
  [[ "$output" == *"No open PR"* ]]
}

# ---------------------------------------------------------------------------
# pr_stranded_approval_reasons — the #1665 observability backstop (AC8).
#
# The dual of the stall net for the marker-vs-standing-approval bug: an open PR
# that is CI-green, has auto-merge ARMED, but carries NO standing approval (the
# only "approval" is a non-standing marker — dismissed review or issue comment),
# left idle with no sweep re-dispatch for over STRANDED_APPROVAL_MIN_HOURS. That
# is a green, auto-merge-armed PR that will never merge because nothing stands to
# satisfy the gate — the exact silent strand #1665 fixes in the sweep, surfaced
# here as a pushed signal in case a residual path still strands it.
# Detection only; fail-quiet on human-gated PRs.
#   args: <ci_status> <auto_merge_armed> <standing_approval> <hours_idle> <gated>
# ---------------------------------------------------------------------------

@test "green + auto-merge armed + no standing approval idle past the threshold fires and names it" {
  run pr_stranded_approval_reasons passing true 0 6 false
  [ "$status" -eq 0 ]
  [[ "$output" == *stranded* ]]
  [[ "$output" == *6* ]]
}

@test "stranded: idle exactly at the threshold does NOT fire (strict >)" {
  # default STRANDED_APPROVAL_MIN_HOURS=4
  run pr_stranded_approval_reasons passing true 0 4 false
  [ -z "$output" ]
}

@test "stranded: idle below the threshold does NOT fire (in-flight guard)" {
  run pr_stranded_approval_reasons passing true 0 2 false
  [ -z "$output" ]
}

@test "CI not passing does NOT fire (not yet a merge-ready strand)" {
  run pr_stranded_approval_reasons pending true 0 24 false
  [ -z "$output" ]
  run pr_stranded_approval_reasons failing true 0 24 false
  [ -z "$output" ]
}

@test "auto-merge NOT armed does NOT fire (no pending merge to strand)" {
  run pr_stranded_approval_reasons passing false 0 24 false
  [ -z "$output" ]
}

@test "a STANDING approval present does NOT fire (the merge can proceed)" {
  run pr_stranded_approval_reasons passing true 1 24 false
  [ -z "$output" ]
}

@test "a human-gated PR does NOT fire even when otherwise stranded (fail-quiet)" {
  run pr_stranded_approval_reasons passing true 0 999 true
  [ -z "$output" ]
}

@test "is_pr_stranded_approval exit 0 when stranded, 1 when healthy" {
  run is_pr_stranded_approval passing true 0 6 false
  [ "$status" -eq 0 ]
  run is_pr_stranded_approval passing true 0 1 false
  [ "$status" -ne 0 ]
}

@test "STRANDED_APPROVAL_MIN_HOURS override is respected" {
  STRANDED_APPROVAL_MIN_HOURS=12 run pr_stranded_approval_reasons passing true 0 8 false
  [ -z "$output" ]
  STRANDED_APPROVAL_MIN_HOURS=12 run pr_stranded_approval_reasons passing true 0 13 false
  [[ "$output" == *stranded* ]]
}

@test "a non-numeric STRANDED_APPROVAL_MIN_HOURS override falls back to the default (never 0)" {
  STRANDED_APPROVAL_MIN_HOURS=abc run pr_stranded_approval_reasons passing true 0 1 false
  [ -z "$output" ]
}

@test "non-numeric idle/standing inputs degrade to no-fire, never error" {
  run pr_stranded_approval_reasons passing true "xyz" "abc" false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "generate_stranded_approval_report renders each candidate with its link and reason" {
  local f
  f=$(mktemp "$STUB_DIR/tsv.XXXXXX")
  printf '%s\t%s\t%s\t%s\n' \
    "808" "https://github.com/o/r/pull/808" "Green + armed but never approved" "stranded 6h: CI-green + auto-merge armed, no standing approval (>4h)" \
    > "$f"
  run generate_stranded_approval_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#808"* ]]
  [[ "$output" == *"https://github.com/o/r/pull/808"* ]]
  [[ "$output" == *"stranded 6h"* ]]
}

@test "generate_stranded_approval_report on an empty file prints an all-clear line, not a table" {
  local f
  f=$(mktemp "$STUB_DIR/tsv.XXXXXX")
  : > "$f"
  run generate_stranded_approval_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| PR |"* ]]
  [[ "$output" == *"No open PR"* ]]
}
