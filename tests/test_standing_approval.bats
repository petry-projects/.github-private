#!/usr/bin/env bats
# Unit tests for scripts/lib/standing-approval.sh (issue #1665).
#
# pr_standing_approval_count is the authoritative "does an approving review STAND
# at head?" primitive shared by the sweep (scripts/sweep-stuck-reviews.sh) and the
# stall detector. It must count ONLY a non-dismissed `state==APPROVED` review that
# carries the pr-review approval marker for the current head. The whole point of
# #1665 is that a `decision=approved` MARKER is NOT proof of a standing approval:
#   • a dismissed review (state != APPROVED) does not stand, and
#   • an approval marker in a plain issue comment is not a review at all.
# Either way the count must be 0, so the caller re-dispatches instead of stranding.
#
# Run with: bats tests/test_standing_approval.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/standing-approval.sh"
}

# snap <head> <reviews-json> [comments-json]
snap() {
  local head="$1" reviews="${2:-[]}" comments="${3:-[]}"
  jq -n --arg h "$head" --argjson rv "$reviews" --argjson cm "$comments" \
    '{headRefOid:$h, reviews:$rv, comments:$cm}'
}

APPROVAL_MARKER='<!-- pr-review-agent v1 sha=HEAD decision=approved risk=LOW -->'

@test "a non-dismissed APPROVED review with the head marker counts as standing" {
  local reviews='[{"state":"APPROVED","body":"<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->"}]'
  run pr_standing_approval_count "$(snap abc123 "$reviews")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "a DISMISSED review carrying the approval marker does NOT stand (#1665 AC2)" {
  local reviews='[{"state":"DISMISSED","body":"<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->"}]'
  run pr_standing_approval_count "$(snap abc123 "$reviews")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "an approval marker in an ISSUE COMMENT does NOT stand (#1665 AC3)" {
  local comments='[{"body":"<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->"}]'
  run pr_standing_approval_count "$(snap abc123 "[]" "$comments")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "an APPROVED review for a DIFFERENT (stale) head does not count" {
  local reviews='[{"state":"APPROVED","body":"<!-- pr-review-agent v1 sha=oldsha00 decision=approved risk=LOW -->"}]'
  run pr_standing_approval_count "$(snap abc123 "$reviews")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "sha match is space-delimited: one sha is never a prefix of another" {
  # Head is abc12; a marker for abc123 must not satisfy the abc12 approval.
  local reviews='[{"state":"APPROVED","body":"<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->"}]'
  run pr_standing_approval_count "$(snap abc12 "$reviews")" abc12
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "an APPROVED review WITHOUT the approval decision token does not count" {
  # e.g. a human approval or a bare-marker orphan in an APPROVED review.
  local reviews='[{"state":"APPROVED","body":"<!-- pr-review-agent v1 sha=abc123 -->"}]'
  run pr_standing_approval_count "$(snap abc123 "$reviews")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "an escalated/fix-requested marker is not an approval" {
  local reviews='[{"state":"COMMENTED","body":"<!-- pr-review-agent v1 sha=abc123 decision=escalated risk=HIGH -->"}]'
  run pr_standing_approval_count "$(snap abc123 "$reviews")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "a review with a MISSING state does not count as standing (fail open — #1665 AC5)" {
  # Indeterminate review state must never masquerade as a standing approval.
  local reviews='[{"body":"<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->"}]'
  run pr_standing_approval_count "$(snap abc123 "$reviews")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "malformed snapshot JSON degrades to 0 (fail open)" {
  run pr_standing_approval_count 'not json' abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "multiple standing approvals are counted" {
  local reviews='[
    {"state":"APPROVED","body":"<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->"},
    {"state":"APPROVED","body":"<!-- pr-review-agent v1 sha=abc123 decision=approved risk=MEDIUM -->"}
  ]'
  run pr_standing_approval_count "$(snap abc123 "$reviews")" abc123
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}
