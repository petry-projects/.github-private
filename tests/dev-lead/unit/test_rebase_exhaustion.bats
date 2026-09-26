#!/usr/bin/env bats
# Unit tests for scripts/lib/rebase-exhaustion.sh (#865)
#
# The dev-lead rebase handler resolves an auto-rebase conflict by invoking the
# engine. On a hard/unresolvable conflict the engine call runs to the per-tier
# `timeout` and is SIGTERM-killed (exit 124) instead of aborting cleanly, and the
# auto-rebase-conflict sentinel can re-fire repeatedly — a burst of runs each
# burning the full timeout (canary 2026-06-21 TalkTerm: 9 runs, all exit 124).
#
# These helpers are pure (no gh/git/network): they take already-fetched inputs
# and return a decision, so they can be tested in isolation here. The handler
# (dev-lead-fix-reviews.sh) wires the gh-api reads to them.
#
# Run with: bats tests/dev-lead/unit/test_rebase_exhaustion.bats

setup() {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/rebase-exhaustion.sh"
  PREFIX='<!-- dev-lead-fix-reviews pr='
}

# ── rebase_exhaustion_marker ──────────────────────────────────────────────────

@test "rebase_exhaustion_marker: builds a PR-level intent=rebase status=exhausted marker" {
  run rebase_exhaustion_marker "$PREFIX" "54"
  [ "$status" -eq 0 ]
  [ "$output" = '<!-- dev-lead-fix-reviews pr=54 intent=rebase status=exhausted -->' ]
}

# ── rebase_is_exhausted ───────────────────────────────────────────────────────

@test "rebase_is_exhausted: true when the marker is present in the bodies" {
  local marker bodies
  marker="$(rebase_exhaustion_marker "$PREFIX" "54")"
  bodies="some other comment
${marker}
## Dev-Lead — rebase (exhausted)"
  run rebase_is_exhausted "$marker" "$bodies"
  [ "$status" -eq 0 ]
}

@test "rebase_is_exhausted: false when the marker is absent" {
  local marker
  marker="$(rebase_exhaustion_marker "$PREFIX" "54")"
  run rebase_is_exhausted "$marker" "just a normal comment"
  [ "$status" -eq 1 ]
}

@test "rebase_is_exhausted: does not match another PR's exhaustion marker" {
  local marker other
  marker="$(rebase_exhaustion_marker "$PREFIX" "54")"
  other="$(rebase_exhaustion_marker "$PREFIX" "540")"
  run rebase_is_exhausted "$marker" "$other"
  [ "$status" -eq 1 ]
}

# ── rebase_count_failures ─────────────────────────────────────────────────────

@test "rebase_count_failures: zero when there are no failed markers" {
  run rebase_count_failures "$PREFIX" "54" "some unrelated comment"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "rebase_count_failures: counts failed markers with a sha field" {
  local bodies
  bodies='<!-- dev-lead-fix-reviews pr=54 sha=aaa intent=rebase status=failed -->
<!-- dev-lead-fix-reviews pr=54 sha=bbb intent=rebase status=failed -->'
  run rebase_count_failures "$PREFIX" "54" "$bodies"
  [ "$output" = "2" ]
}

@test "rebase_count_failures: counts a failed marker without a sha field" {
  local bodies
  bodies='<!-- dev-lead-fix-reviews pr=54 intent=rebase status=failed -->'
  run rebase_count_failures "$PREFIX" "54" "$bodies"
  [ "$output" = "1" ]
}

@test "rebase_count_failures: excludes rate-limited and applied markers" {
  local bodies
  bodies='<!-- dev-lead-fix-reviews pr=54 sha=aaa intent=rebase status=rate-limited -->
<!-- dev-lead-fix-reviews pr=54 sha=bbb intent=rebase status=applied -->
<!-- dev-lead-fix-reviews pr=54 sha=ccc intent=rebase status=failed -->'
  run rebase_count_failures "$PREFIX" "54" "$bodies"
  [ "$output" = "1" ]
}

@test "rebase_count_failures: excludes a failed marker for a different intent" {
  local bodies
  bodies='<!-- dev-lead-fix-reviews pr=54 sha=aaa intent=fix-reviews status=failed -->'
  run rebase_count_failures "$PREFIX" "54" "$bodies"
  [ "$output" = "0" ]
}

@test "rebase_count_failures: does not miscount a superset PR number (54 vs 549)" {
  local bodies
  bodies='<!-- dev-lead-fix-reviews pr=549 sha=aaa intent=rebase status=failed -->'
  run rebase_count_failures "$PREFIX" "54" "$bodies"
  [ "$output" = "0" ]
}

# ── rebase_conflict_too_large ─────────────────────────────────────────────────

@test "rebase_conflict_too_large: true when count exceeds the limit" {
  run rebase_conflict_too_large 41 40
  [ "$status" -eq 0 ]
}

@test "rebase_conflict_too_large: false when count equals the limit" {
  run rebase_conflict_too_large 40 40
  [ "$status" -eq 1 ]
}

@test "rebase_conflict_too_large: false when count is below the limit" {
  run rebase_conflict_too_large 5 40
  [ "$status" -eq 1 ]
}

@test "rebase_conflict_too_large: disabled (never true) when the limit is 0" {
  run rebase_conflict_too_large 999 0
  [ "$status" -eq 1 ]
}

# ── rebase_should_exhaust ─────────────────────────────────────────────────────

@test "rebase_should_exhaust: true when failures reach the threshold" {
  run rebase_should_exhaust 2 2
  [ "$status" -eq 0 ]
}

@test "rebase_should_exhaust: true when failures exceed the threshold" {
  run rebase_should_exhaust 3 2
  [ "$status" -eq 0 ]
}

@test "rebase_should_exhaust: false below the threshold" {
  run rebase_should_exhaust 1 2
  [ "$status" -eq 1 ]
}

@test "rebase_should_exhaust: disabled (never true) when the threshold is 0" {
  run rebase_should_exhaust 5 0
  [ "$status" -eq 1 ]
}

# ── rebase_conflict_state ─────────────────────────────────────────────────────
# The authoritative post-condition check (#1890 AC #2): the rebase intent must
# not report success from its exit code / a local trial-merge — it must assert
# the PR's real GitHub mergeable state. rebase_conflict_state is the pure decision
# over the (mergeable, mergeStateStatus) pair `gh pr view` returns.

@test "rebase_conflict_state: CONFLICTING + DIRTY is conflicting" {
  run rebase_conflict_state "CONFLICTING" "DIRTY"
  [ "$status" -eq 0 ]
  [ "$output" = "conflicting" ]
}

@test "rebase_conflict_state: mergeable CONFLICTING is conflicting regardless of state status" {
  run rebase_conflict_state "CONFLICTING" "UNKNOWN"
  [ "$output" = "conflicting" ]
}

@test "rebase_conflict_state: mergeStateStatus DIRTY is conflicting even if mergeable says MERGEABLE" {
  run rebase_conflict_state "MERGEABLE" "DIRTY"
  [ "$output" = "conflicting" ]
}

@test "rebase_conflict_state: MERGEABLE + CLEAN is resolved" {
  run rebase_conflict_state "MERGEABLE" "CLEAN"
  [ "$status" -eq 0 ]
  [ "$output" = "resolved" ]
}

@test "rebase_conflict_state: MERGEABLE + BEHIND is resolved (base moved, not a conflict)" {
  run rebase_conflict_state "MERGEABLE" "BEHIND"
  [ "$output" = "resolved" ]
}

@test "rebase_conflict_state: MERGEABLE + BLOCKED is resolved (held by review, not a conflict)" {
  run rebase_conflict_state "MERGEABLE" "BLOCKED"
  [ "$output" = "resolved" ]
}

@test "rebase_conflict_state: UNKNOWN mergeable is indeterminate (GitHub still computing)" {
  run rebase_conflict_state "UNKNOWN" "UNKNOWN"
  [ "$output" = "indeterminate" ]
}

@test "rebase_conflict_state: empty inputs are indeterminate" {
  run rebase_conflict_state "" ""
  [ "$output" = "indeterminate" ]
}

@test "rebase_conflict_state: MERGEABLE + UNKNOWN is resolved (mergeable is a positive no-conflict signal)" {
  run rebase_conflict_state "MERGEABLE" "UNKNOWN"
  [ "$output" = "resolved" ]
}

# ── rebase_failure_reason ─────────────────────────────────────────────────────

@test "rebase_failure_reason: exit 124 is described as a timeout on an unresolvable conflict" {
  run rebase_failure_reason 124
  [ "$status" -eq 0 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" == *"124"* ]]
  [[ "$output" == *"unresolvable"* ]]
}

@test "rebase_failure_reason: a non-124 exit is described as a generic engine failure" {
  run rebase_failure_reason 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed"* ]]
  [[ "$output" == *"1"* ]]
  [[ "$output" != *"timed out"* ]]
}
