#!/usr/bin/env bats
# Tests for scripts/lib/comment-noise.sh — the pure no-action agent-comment
# noise classifier (issue #1411, epic #1402). Covers every known no-action
# comment shape plus a genuinely-actionable control, the shared jq pre-classifier
# used by the report collection path, and the pure markdown renderer.
# Run locally: bats tests/comment_noise.bats

setup() {
  # shellcheck source=scripts/lib/comment-noise.sh
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/comment-noise.sh"
}

# ---------------------------------------------------------------------------
# cn_is_agent_comment — marker detection (the denominator)
# ---------------------------------------------------------------------------

@test "agent-comment: each automation marker is recognised" {
  run cn_is_agent_comment '<!-- pr-review-agent v1 sha=abc decision=approved risk=LOW -->'; [ "$status" -eq 0 ]
  run cn_is_agent_comment '<!-- dev-lead-fix-reviews pr=7 sha=abc intent=on-mention status=no-changes -->'; [ "$status" -eq 0 ]
  run cn_is_agent_comment '<!-- persona:security-sentinel -->'; [ "$status" -eq 0 ]
  run cn_is_agent_comment '<!-- dependency-advisory -->'; [ "$status" -eq 0 ]
}

@test "agent-comment: a plain human comment is NOT an agent comment" {
  run cn_is_agent_comment 'LGTM, thanks for the fix!'; [ "$status" -eq 1 ]
  run cn_is_agent_comment 'No actionable items found.'; [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# cn_classify — non-agent / no-action / actionable
# ---------------------------------------------------------------------------

@test "classify: post_no_changes 'No actionable items found.' is no-action" {
  run cn_classify '<!-- dev-lead-fix-reviews pr=7 sha=abc intent=on-mention status=no-changes -->
No actionable items found.'
  [ "$output" = "no-action" ]
}

@test "classify: fix-ci 'Engine ran but made no changes.' is no-action" {
  run cn_classify '<!-- dev-lead-fix-ci sha=abc status=no-changes -->
Engine ran but made no changes.'
  [ "$output" = "no-action" ]
}

@test "classify: 'No action required.' dependency advisory is no-action" {
  run cn_classify '<!-- dependency-advisory -->
All changes are LOW risk. No action required.'
  [ "$output" = "no-action" ]
}

@test "classify: a clean repeat approval (decision=approved) is no-action" {
  run cn_classify '<!-- pr-review-agent v1 sha=abc decision=approved risk=LOW -->
## APPROVED ✓'
  [ "$output" = "no-action" ]
}

@test "classify: a superseded agent comment is no-action regardless of embedded body" {
  run cn_classify '<!-- pr-review-agent superseded -->
<details><summary>Prior review</summary>
<!-- pr-review-agent v1 sha=old decision=escalated risk=HIGH -->
## NEEDS HUMAN REVIEW
</details>'
  [ "$output" = "no-action" ]
}

@test "classify: an escalated pr-review comment with findings is actionable" {
  run cn_classify '<!-- pr-review-agent v1 sha=abc decision=escalated risk=HIGH -->
## NEEDS HUMAN REVIEW
- Possible SQL injection on line 42.'
  [ "$output" = "actionable" ]
}

@test "classify: dev-lead status=applied (changes pushed) is actionable" {
  run cn_classify '<!-- dev-lead-fix-reviews pr=7 sha=abc intent=on-mention status=applied -->
Fix committed and pushed.'
  [ "$output" = "actionable" ]
}

@test "classify: the no-op guard human-attention comment is actionable" {
  run cn_classify '<!-- dev-lead-noop-guard pr=7 intent=on-mention -->
## No-op fix detected — human attention needed'
  [ "$output" = "actionable" ]
}

@test "classify: a non-agent comment is non-agent, never noise" {
  run cn_classify 'Thanks, merging now.'
  [ "$output" = "non-agent" ]
}

@test "classify: a human comment quoting a marker is non-agent (marker must lead the body)" {
  # Unanchored pattern would wrongly classify this as an agent comment.
  run cn_classify 'Comments carrying our markers — <!-- pr-review-agent v1 --> and <!-- dev-lead --> — are ours.'
  [ "$output" = "non-agent" ]
}

@test "classify: a comment quoting a no-action phrase mid-line is actionable, not noise" {
  # Unanchored pattern would wrongly classify this as no-action.
  run cn_classify '<!-- dev-lead-fix-reviews pr=7 sha=abc intent=on-mention status=applied -->
The engine says "No actionable items found." but that is wrong — please re-run.'
  [ "$output" = "actionable" ]
}

# ---------------------------------------------------------------------------
# CN_AGENT_COMMENT_JQ — shared pre-classifier over a GraphQL PR node
# (the exact program reviewer_report.sh applies during collection)
# ---------------------------------------------------------------------------

@test "jq pre-classifier: emits one agent_comment per marker-bearing body, pre-flagged no_action" {
  tmp="$(mktemp "$BATS_TEST_TMPDIR/node.XXXXXX.json")"
  cat > "$tmp" <<'JSON'
{"url":"o/r/1","createdAt":"2026-07-10T10:00:00Z",
 "reviews":{"nodes":[
   {"author":{"login":"donpetry-bot"},"bodyText":"<!-- pr-review-agent v1 sha=abc decision=escalated risk=HIGH -->\nNEEDS HUMAN REVIEW","submittedAt":"2026-07-10T10:00:00Z"},
   {"author":{"login":"donpetry-bot"},"bodyText":"<!-- pr-review-agent v1 sha=def decision=approved risk=LOW -->\nAPPROVED","submittedAt":"2026-07-10T10:00:00Z"}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[
   {"author":{"login":"don-petry"},"bodyText":"<!-- dev-lead-fix-reviews pr=1 sha=abc intent=on-mention status=no-changes -->\nNo actionable items found.","createdAt":"2026-07-10T10:00:00Z"},
   {"author":{"login":"alice"},"bodyText":"Looks good to me, no markers here.","createdAt":"2026-07-10T10:00:00Z"}]}}
JSON
  run jq -c --arg repo "o/r" --arg mark "$(cn_marker_pattern)" --arg noact "$(cn_no_action_pattern)" --arg cutoff "2026-07-01T00:00:00Z" \
    "[ $CN_AGENT_COMMENT_JQ ]" "$tmp"
  # 3 marker-bearing bodies (2 reviews + 1 dev-lead comment); human comment is dropped.
  # The approved review is sha=def — first (and only) approval for that SHA → actionable.
  # The no-changes dev-lead comment is no-action. The escalated review is actionable.
  echo "$output" | jq -e 'length == 3'
  echo "$output" | jq -e 'map(select(.no_action)) | length == 1'   # only the no-changes
  echo "$output" | jq -e 'all(.[]; .pr == "o/r/1" and .kind == "agent_comment")'
}

@test "jq pre-classifier: repeat approval of same SHA is no-action, first approval is actionable" {
  tmp="$(mktemp "$BATS_TEST_TMPDIR/repeat.XXXXXX.json")"
  cat > "$tmp" <<'JSON'
{"url":"o/r/3","createdAt":"2026-07-10T10:00:00Z",
 "reviews":{"nodes":[
   {"bodyText":"<!-- pr-review-agent v1 sha=aaa decision=approved risk=LOW -->\nAPPROVED","submittedAt":"2026-07-10T10:00:00Z"},
   {"bodyText":"<!-- pr-review-agent v1 sha=aaa decision=approved risk=LOW -->\nAPPROVED","submittedAt":"2026-07-10T11:00:00Z"},
   {"bodyText":"<!-- pr-review-agent v1 sha=bbb decision=approved risk=LOW -->\nAPPROVED","submittedAt":"2026-07-10T12:00:00Z"}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]}}
JSON
  run jq -c --arg repo "o/r" --arg mark "$(cn_marker_pattern)" --arg noact "$(cn_no_action_pattern)" --arg cutoff "2026-07-01T00:00:00Z" \
    "[ $CN_AGENT_COMMENT_JQ ]" "$tmp"
  [ "$status" -eq 0 ]
  # sha=aaa first → actionable; sha=aaa second → no-action (repeat); sha=bbb first → actionable.
  echo "$output" | jq -e 'length == 3'
  echo "$output" | jq -e 'map(select(.no_action)) | length == 1'
  echo "$output" | jq -e 'map(select(.no_action == false)) | length == 2'
}

@test "jq pre-classifier: old agent comments before cutoff are excluded even on a recently-updated PR" {
  tmp="$(mktemp "$BATS_TEST_TMPDIR/old.XXXXXX.json")"
  cat > "$tmp" <<'JSON'
{"url":"o/r/2","updatedAt":"2026-07-25T10:00:00Z",
 "reviews":{"nodes":[
   {"bodyText":"<!-- pr-review-agent v1 sha=old decision=approved -->","submittedAt":"2026-06-01T00:00:00Z"}]},
 "reviewThreads":{"nodes":[]},
 "comments":{"nodes":[]}}
JSON
  run jq -c --arg repo "o/r" --arg mark "$(cn_marker_pattern)" --arg noact "$(cn_no_action_pattern)" --arg cutoff "2026-07-10T00:00:00Z" \
    "[ $CN_AGENT_COMMENT_JQ ]" "$tmp"
  [ "$status" -eq 0 ]
  # Review submitted before the cutoff — excluded even though the PR's updatedAt is in-window.
  echo "$output" | jq -e 'length == 0'
}

# ---------------------------------------------------------------------------
# cn_render_noise_section — pure markdown renderer over agent_comment JSONL
# ---------------------------------------------------------------------------

@test "render: counts, share, per-PR, and empty-state" {
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/noise.XXXXXX")"
  cat > "$dir/a.jsonl" <<'JSON'
{"kind":"pr","repo":"o/r","pr":"o/r/1","created":"x","merged":null,"draft":false,"author":"h"}
{"kind":"pr","repo":"o/r","pr":"o/r/2","created":"x","merged":null,"draft":false,"author":"h"}
{"kind":"pr","repo":"o/r","pr":"o/r/3","created":"x","merged":null,"draft":false,"author":"h"}
{"kind":"agent_comment","repo":"o/r","pr":"o/r/1","no_action":true}
{"kind":"agent_comment","repo":"o/r","pr":"o/r/1","no_action":false}
{"kind":"agent_comment","repo":"o/r","pr":"o/r/2","no_action":true}
{"kind":"agent_comment","repo":"o/r","pr":"o/r/3","no_action":true}
{"kind":"pr","repo":"o/r","pr":"o/r/9","created":"x","merged":null,"draft":false,"author":"h"}
JSON
  run cn_render_noise_section "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent comments"* ]]
  # 4 agent comments (3 no-action = 75%) across 3 PRs with agent comments; 4 active PRs total.
  [[ "$output" == *"4"* ]]
  [[ "$output" == *"75%"* ]]
  [[ "$output" == *"Active PRs"* ]]
  [[ "$output" == *"Affected PRs"* ]]
  # 3 affected PRs (o/r/1, o/r/2, o/r/3 each have ≥1 no-action comment).
  [[ "$output" == *"3"* ]]
}

@test "render: empty dir yields a clean zero-state, never an error" {
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/empty.XXXXXX")"
  run cn_render_noise_section "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent comment noise"* ]]
}
