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
# compute_review_cycle: approvals reset the count (defect 1 in #467)
# ---------------------------------------------------------------------------

@test "approval marker itself never counts as a cycle" {
  run compute_review_cycle "$(items "$(approval 2026-06-07T01:00:00Z aaa111)")"
  [ "$output" = "0" ]
}

@test "PR #458 shape: fix, fix, approve counts 0 (was 3 — escalated wrongly)" {
  local j
  j=$(items \
    "$(fix_request 2026-06-07T04:11:06Z 05ae5d9)" \
    "$(fix_request 2026-06-07T04:20:56Z 0655052)" \
    "$(approval    2026-06-07T05:01:52Z 022cecf)")
  run compute_review_cycle "$j"
  [ "$output" = "0" ]
}

@test "fix-requests after an approval count from the approval, not from zero history" {
  local j
  j=$(items \
    "$(fix_request 2026-06-07T01:00:00Z aaa111)" \
    "$(fix_request 2026-06-07T02:00:00Z bbb222)" \
    "$(approval    2026-06-07T03:00:00Z ccc333)" \
    "$(fix_request 2026-06-07T04:00:00Z ddd444)")
  run compute_review_cycle "$j"
  [ "$output" = "1" ]
}

@test "approval preserved inside a superseded <details> wrapper still resets" {
  # mark_prior_agent_items_obsolete edits comments in place, preserving
  # createdAt and the original marker inside a <details> block.
  local wrapped j
  wrapped=$(jq -n '{when: "2026-06-07T03:00:00Z", body: "<!-- pr-review-agent superseded -->\n<details><summary>prior</summary>\n<!-- pr-review-agent v1 sha=ccc333 decision=approved risk=LOW -->\n</details>"}')
  j=$(items \
    "$(fix_request 2026-06-07T01:00:00Z aaa111)" \
    "$wrapped" \
    "$(fix_request 2026-06-07T04:00:00Z ddd444)")
  run compute_review_cycle "$j"
  [ "$output" = "1" ]
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

@test "newest reset event wins: approval after escalation resets again" {
  local j
  j=$(items \
    "$(escalation_comment 2026-06-07T01:00:00Z)" \
    "$(fix_request 2026-06-07T02:00:00Z aaa111)" \
    "$(approval    2026-06-07T03:00:00Z bbb222)" \
    "$(fix_request 2026-06-07T04:00:00Z ccc333)")
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
