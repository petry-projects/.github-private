#!/usr/bin/env bats
# Unit tests for the runaway-PR detection net (scripts/lib/pr-runaway-detect.sh,
# issue #948 — #860 follow-up).
#
# This is the DETECTION half of the #860 remediation: the per-PR budget (#926)
# and org self-trigger fix bound/prevent runaways; this flags any open PR that
# has already accumulated abnormal automated activity so the next novel runaway
# surface is caught on day one instead of running unseen (as #860 did for four
# days). Detection only — the logic here never mutates a PR.
#
# The thresholds are soft and env-overridable; a PR is a runaway CANDIDATE when
# it exceeds ANY of them. The tests pin the boundary behaviour (strict >), the
# env overrides, the multi-metric reason output, and — most importantly for
# AC#3 — that a normal, converging PR does NOT false-positive.
#
# Run with: bats tests/test_pr_runaway_detect.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-runaway-detect.sh"
}

# ---------------------------------------------------------------------------
# pr_runaway_reasons — commits threshold (default > 50)
# ---------------------------------------------------------------------------

@test "commits at the threshold do NOT fire (strict >)" {
  # commits=50 comments=0 cycles=0 age=0
  run pr_runaway_reasons 50 0 0 0
  [ -z "$output" ]
}

@test "commits over the threshold fire and name the metric" {
  run pr_runaway_reasons 51 0 0 0
  [ "$status" -eq 0 ]
  [[ "$output" == *commits* ]]
  [[ "$output" == *51* ]]
}

# ---------------------------------------------------------------------------
# pr_runaway_reasons — comments threshold (default > 200)
# ---------------------------------------------------------------------------

@test "comments at the threshold do NOT fire" {
  run pr_runaway_reasons 0 200 0 0
  [ -z "$output" ]
}

@test "comments over the threshold fire and name the metric" {
  run pr_runaway_reasons 0 201 0 0
  [[ "$output" == *comments* ]]
  [[ "$output" == *201* ]]
}

# ---------------------------------------------------------------------------
# pr_runaway_reasons — automated cycles threshold (default > 10)
# ---------------------------------------------------------------------------

@test "cycles at the threshold do NOT fire" {
  run pr_runaway_reasons 0 0 10 0
  [ -z "$output" ]
}

@test "cycles over the threshold fire and name the metric" {
  run pr_runaway_reasons 0 0 11 0
  [[ "$output" == *cycle* ]]
  [[ "$output" == *11* ]]
}

# ---------------------------------------------------------------------------
# pr_runaway_reasons — age-with-churn threshold (default > 48h AND churn)
# ---------------------------------------------------------------------------

@test "aged past 48h WITH agent churn fires" {
  # age=49h, cycles=3 (>= churn floor 1)
  run pr_runaway_reasons 0 0 3 49
  [[ "$output" == *48* ]] || [[ "$output" == *churn* ]]
}

@test "aged past 48h but QUIET (no churn) does NOT fire — the false-positive guard" {
  # A normal PR that merely sat open >48h with zero agent activity must not flag.
  run pr_runaway_reasons 0 0 0 72
  [ -z "$output" ]
}

@test "recent PR with churn does NOT fire on the age criterion" {
  # age=10h < 48h, churn present but PR is young -> no age reason
  run pr_runaway_reasons 0 0 3 10
  [ -z "$output" ]
}

@test "age exactly at 48h does NOT fire (strict >)" {
  run pr_runaway_reasons 0 0 5 48
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC#3 — a normal, converging PR does not false-positive on ANY metric
# ---------------------------------------------------------------------------

@test "a normal converging PR yields no reasons" {
  # 8 commits, 15 comments, 2 cycles, 6h old
  run pr_runaway_reasons 8 15 2 6
  [ -z "$output" ]
  run is_pr_runaway 8 15 2 6
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Multiple metrics — every triggering reason is reported
# ---------------------------------------------------------------------------

@test "a PR over several thresholds reports each triggering metric" {
  # commits=100 (>50), comments=300 (>200), cycles=20 (>10), age=60h+churn
  run pr_runaway_reasons 100 300 20 60
  [[ "$output" == *commits* ]]
  [[ "$output" == *comments* ]]
  [[ "$output" == *cycle* ]]
  # 4 reasons -> 4 non-empty lines
  n=$(printf '%s\n' "$output" | grep -c .)
  [ "$n" -eq 4 ]
}

# ---------------------------------------------------------------------------
# is_pr_runaway — boolean wrapper
# ---------------------------------------------------------------------------

@test "is_pr_runaway exit 0 when any metric fires" {
  run is_pr_runaway 51 0 0 0
  [ "$status" -eq 0 ]
}

@test "is_pr_runaway exit 1 when clean" {
  run is_pr_runaway 1 1 1 1
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Env-overridable thresholds (AC#2)
# ---------------------------------------------------------------------------

@test "RUNAWAY_MAX_COMMITS override is respected" {
  RUNAWAY_MAX_COMMITS=5 run pr_runaway_reasons 6 0 0 0
  [[ "$output" == *commits* ]]
  RUNAWAY_MAX_COMMITS=5 run pr_runaway_reasons 5 0 0 0
  [ -z "$output" ]
}

@test "RUNAWAY_MAX_COMMENTS override is respected" {
  RUNAWAY_MAX_COMMENTS=10 run pr_runaway_reasons 0 11 0 0
  [[ "$output" == *comments* ]]
}

@test "RUNAWAY_MAX_CYCLES override is respected" {
  RUNAWAY_MAX_CYCLES=3 run pr_runaway_reasons 0 0 4 0
  [[ "$output" == *cycle* ]]
}

@test "RUNAWAY_MIN_AGE_HOURS override is respected" {
  RUNAWAY_MIN_AGE_HOURS=1 run pr_runaway_reasons 0 0 2 2
  [[ "$output" == *churn* ]] || [[ "$output" == *1* ]]
}

@test "RUNAWAY_CHURN_MIN_CYCLES override gates the age criterion" {
  # With a higher churn floor, 2 cycles is not 'active churn' -> no age reason.
  RUNAWAY_CHURN_MIN_CYCLES=5 run pr_runaway_reasons 0 0 2 72
  [ -z "$output" ]
  RUNAWAY_CHURN_MIN_CYCLES=5 run pr_runaway_reasons 0 0 5 72
  [[ "$output" == *churn* ]]
}

# ---------------------------------------------------------------------------
# Defensive: non-numeric / empty inputs degrade to 0, never error
# ---------------------------------------------------------------------------

@test "non-numeric inputs degrade to 0 (no crash, no false fire)" {
  run pr_runaway_reasons "" "abc" "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing arguments degrade to 0" {
  run pr_runaway_reasons
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# pr_age_hours — ISO-8601 created_at -> integer hours since (injected now)
# ---------------------------------------------------------------------------

@test "pr_age_hours computes whole hours against an injected now" {
  # created 2026-06-24T00:00:00Z, now 2026-06-24T50:00:00 -> 50h.
  local now created
  created="2026-06-24T00:00:00Z"
  now=$(date -u -d "2026-06-26T02:00:00Z" +%s)   # 50h later
  run pr_age_hours "$created" "$now"
  [ "$output" -eq 50 ]
}

@test "pr_age_hours degrades to 0 on unparseable input" {
  run pr_age_hours "not-a-date"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# generate_runaway_report — renders a table with link + metric per candidate
# ---------------------------------------------------------------------------

@test "generate_runaway_report renders each candidate with its link and reason" {
  local f
  f=$(mktemp)
  printf '%s\t%s\t%s\t%s\n' \
    "860" "https://github.com/o/r/pull/860" "Runaway PR" "commits: 378 (>50); comments: 1582 (>200)" \
    > "$f"
  run generate_runaway_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#860"* ]]
  [[ "$output" == *"https://github.com/o/r/pull/860"* ]]
  [[ "$output" == *"commits: 378"* ]]
  rm -f "$f"
}

@test "generate_runaway_report on an empty file prints an all-clear line, not a table" {
  local f
  f=$(mktemp)
  : > "$f"
  run generate_runaway_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| PR |"* ]]
  rm -f "$f"
}
