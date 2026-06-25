#!/usr/bin/env bats
# Unit tests for the cycle-cap helpers in scripts/lib/review-cycle.sh
# (issue #467: cap must break fix-request ping-pong loops without punishing
# converging PRs, and escalation must be recoverable).
#
# Run with: bats tests/test_review_cycle.bats
# Install bats: https://github.com/bats-core/bats-core

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/review-cycle.sh"
}

# Helpers to build {when, body} items.
fix_request() {  # fix_request <when> <sha>
  jq -n --arg when "$1" --arg sha "$2" \
    '{when: $when, body: ("<!-- pr-review-agent v1 sha=" + $sha + " --> <!-- decision=fix-requested risk=LOW -->\n\n## Review — fix requested")}'
}
approval() {  # approval <when> <sha>
  jq -n --arg when "$1" --arg sha "$2" \
    '{when: $when, body: ("<!-- pr-review-agent v1 sha=" + $sha + " decision=approved risk=LOW -->\n\n## Automated review — APPROVED ✓")}'
}
escalated_review() {  # escalated_review <when> <sha>
  jq -n --arg when "$1" --arg sha "$2" \
    '{when: $when, body: ("<!-- pr-review-agent v1 sha=" + $sha + " decision=escalated risk=MEDIUM -->\n\n## Automated review — NEEDS HUMAN REVIEW")}'
}
escalation_comment() {  # escalation_comment <when>
  jq -n --arg when "$1" \
    '{when: $when, body: "<!-- pr-review-agent escalation -->\n\n## Automated review — human attention needed"}'
}
# A human clicking "Approve" in the GitHub UI: a review with state=APPROVED and a
# non-bot author, carrying NO agent marker. Only this resets the cap (#926).
human_approval() {  # human_approval <when>
  jq -n --arg when "$1" '{when: $when, body: "LGTM", author: "don-the-human", state: "APPROVED"}'
}
# A machine approval: a bot-authored APPROVED review (e.g. repair-pr-approvals or
# a bot approval). Must NOT reset the cap (#926).
bot_approval() {  # bot_approval <when> [login]
  jq -n --arg when "$1" --arg login "${2:-donpetry-bot}" \
    '{when: $when, body: "", author: $login, state: "APPROVED"}'
}
items() {  # items <item-json>...
  printf '%s\n' "$@" | jq -s '.'
}

# ---------------------------------------------------------------------------
# compute_review_cycle: basics
# ---------------------------------------------------------------------------

@test "no markers at all counts 0" {
  run compute_review_cycle '[{"when":"2026-06-07T01:00:00Z","body":"just a human comment"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "empty array counts 0" {
  run compute_review_cycle '[]'
  [ "$output" = "0" ]
}

@test "missing argument counts 0" {
  run compute_review_cycle
  [ "$output" = "0" ]
}

@test "malformed JSON degrades to 0, not an error" {
  run compute_review_cycle 'not-json at all'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "three consecutive fix-requests count 3" {
  local j
  j=$(items \
    "$(fix_request 2026-06-07T01:00:00Z aaa111)" \
    "$(fix_request 2026-06-07T02:00:00Z bbb222)" \
    "$(fix_request 2026-06-07T03:00:00Z ccc333)")
  run compute_review_cycle "$j"
  [ "$output" = "3" ]
}

@test "escalated (needs-human) reviews count as non-converging cycles" {
  local j
  j=$(items \
    "$(escalated_review 2026-06-07T01:00:00Z aaa111)" \
    "$(escalated_review 2026-06-07T02:00:00Z bbb222)")
  run compute_review_cycle "$j"
  [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# compute_review_cycle: only HUMAN approvals reset the count (#926).
# The cap's reset must be unreachable by the runaway agent: machine approvals
# (the cascade's own approval marker, repair-pr-approvals, bot approvals) must
# NOT reset, otherwise the loop re-arms its own cap (the #860 failure mode).
# ---------------------------------------------------------------------------

@test "approval marker itself never counts as a cycle" {
  run compute_review_cycle "$(items "$(approval 2026-06-07T01:00:00Z aaa111)")"
  [ "$output" = "0" ]
}

@test "a HUMAN approval resets the count (fix, fix, human-approve = 0)" {
  local j
  j=$(items \
    "$(fix_request    2026-06-07T04:11:06Z 05ae5d9)" \
    "$(fix_request    2026-06-07T04:20:56Z 0655052)" \
    "$(human_approval 2026-06-07T05:01:52Z)")
  run compute_review_cycle "$j"
  [ "$output" = "0" ]
}

@test "fix-requests after a HUMAN approval count from that approval" {
  local j
  j=$(items \
    "$(fix_request    2026-06-07T01:00:00Z aaa111)" \
    "$(fix_request    2026-06-07T02:00:00Z bbb222)" \
    "$(human_approval 2026-06-07T03:00:00Z)" \
    "$(fix_request    2026-06-07T04:00:00Z ddd444)")
  run compute_review_cycle "$j"
  [ "$output" = "1" ]
}

@test "the cascade's own approval MARKER does NOT reset the count (#926)" {
  # fix, fix, machine-approval-marker, fix -> all 3 fix-requests still count,
  # because a machine approval can no longer re-arm the cap.
  local j
  j=$(items \
    "$(fix_request 2026-06-07T01:00:00Z aaa111)" \
    "$(fix_request 2026-06-07T02:00:00Z bbb222)" \
    "$(approval    2026-06-07T03:00:00Z ccc333)" \
    "$(fix_request 2026-06-07T04:00:00Z ddd444)")
  run compute_review_cycle "$j"
  [ "$output" = "3" ]
}

@test "a bot GitHub approval (repair-pr-approvals) does NOT reset the count (#926)" {
  local j
  j=$(items \
    "$(fix_request  2026-06-07T01:00:00Z aaa111)" \
    "$(fix_request  2026-06-07T02:00:00Z bbb222)" \
    "$(bot_approval 2026-06-07T03:00:00Z repair-pr-approvals)" \
    "$(fix_request  2026-06-07T04:00:00Z ddd444)")
  run compute_review_cycle "$j"
  [ "$output" = "3" ]
}

# ---------------------------------------------------------------------------
# compute_review_cycle: escalation comments reset the count (defect 3 in #467)
# ---------------------------------------------------------------------------

@test "markers older than the escalation comment do not count (re-engagement gets a fresh budget)" {
  local j
  j=$(items \
    "$(fix_request 2026-06-07T01:00:00Z aaa111)" \
    "$(fix_request 2026-06-07T02:00:00Z bbb222)" \
    "$(fix_request 2026-06-07T03:00:00Z ccc333)" \
    "$(escalation_comment 2026-06-07T04:00:00Z)")
  run compute_review_cycle "$j"
  [ "$output" = "0" ]
}

@test "cycles after re-engagement count from the escalation comment" {
  local j
  j=$(items \
    "$(fix_request 2026-06-07T01:00:00Z aaa111)" \
    "$(fix_request 2026-06-07T02:00:00Z bbb222)" \
    "$(fix_request 2026-06-07T03:00:00Z ccc333)" \
    "$(escalation_comment 2026-06-07T04:00:00Z)" \
    "$(fix_request 2026-06-07T05:00:00Z ddd444)" \
    "$(fix_request 2026-06-07T06:00:00Z eee555)")
  run compute_review_cycle "$j"
  [ "$output" = "2" ]
}

@test "newest reset event wins: HUMAN approval after escalation resets again" {
  local j
  j=$(items \
    "$(escalation_comment 2026-06-07T01:00:00Z)" \
    "$(fix_request    2026-06-07T02:00:00Z aaa111)" \
    "$(human_approval 2026-06-07T03:00:00Z)" \
    "$(fix_request    2026-06-07T04:00:00Z ccc333)")
  run compute_review_cycle "$j"
  [ "$output" = "1" ]
}

@test "items with null/missing timestamps are ignored rather than fatal" {
  local pending j
  # A PENDING review has submittedAt=null; it must not break counting.
  pending=$(jq -n '{when: null, body: "<!-- pr-review-agent v1 sha=fff666 --> <!-- decision=fix-requested risk=LOW -->"}')
  j=$(items "$pending" "$(fix_request 2026-06-07T01:00:00Z aaa111)")
  run compute_review_cycle "$j"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# has_escalation_marker
# ---------------------------------------------------------------------------

@test "has_escalation_marker: true when an escalation comment exists" {
  run has_escalation_marker "$(items "$(escalation_comment 2026-06-07T01:00:00Z)")"
  [ "$status" -eq 0 ]
}

@test "has_escalation_marker: false for plain review markers" {
  run has_escalation_marker "$(items "$(fix_request 2026-06-07T01:00:00Z aaa111)")"
  [ "$status" -ne 0 ]
}

@test "has_escalation_marker: false on empty/malformed input" {
  run has_escalation_marker '[]'
  [ "$status" -ne 0 ]
  run has_escalation_marker 'garbage'
  [ "$status" -ne 0 ]
}
