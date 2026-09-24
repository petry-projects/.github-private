#!/usr/bin/env bats
# Regression guard for #1919: every dev-lead path that posts a PR *issue comment*
# must stamp a `<!-- dev-lead … -->` agent marker so the maintainer-comment gate
# (scripts/lib/maintainer-comment-gate.sh) recognises it as agent-authored and
# does NOT count it as an undispositioned finding.
#
# dev-lead commits and comments as `don-petry` (a human login), and the gate
# discriminates by MARKER, not author. So an UNMARKED acknowledgement/note is
# indistinguishable from a maintainer finding and becomes a fresh gate blocker on
# the very PR it was posted to unblock. The marker-prefixed paths (fix-reviews
# Phase 1b disposition, hold-notice, rate-limit-ack) are already correct; this
# guards the paths that historically bypassed the convention.

PROMPTS_DIR="$(cd "$BATS_TEST_DIRNAME"/../../.. && pwd)/prompts/dev-lead"

# The gate's agent-marker regex only matches HTML markers of the form
# `<!-- dev-lead … -->`. A prompt that tells the agent to `gh pr comment` must
# therefore also tell it to stamp such a marker.

@test "review-changes.md failing-check PR comment carries a dev-lead marker (#1919)" {
  # The failing-check fix note is posted as a PR issue comment; it must be marked.
  run grep -qF '<!-- dev-lead:check-fix -->' "$PROMPTS_DIR/review-changes.md"
  [ "$status" -eq 0 ]
}

@test "fix-bot-comment.md dispositions non-actionable bot-notice comments (#1919)" {
  # A non-actionable bot issue-comment notice (trial-ended, usage-limit, rate-limit)
  # is NOT auto-cleared by the info-status classifier, so a plain ack or suppression
  # leaves the ORIGINAL comment an undispositioned maintainer-gate blocker. The prompt
  # must instead disposition the original via the verified comment-disposition marker.
  run grep -qF '<!-- dev-lead:comment-disposition id=<comment_node_id> disposition=informational -->' "$PROMPTS_DIR/fix-bot-comment.md"
  [ "$status" -eq 0 ]
}

@test "fix-bot-comment.md cites the maintainer-comment gate rationale (#1919)" {
  run grep -qiE "maintainer-comment gate|undispositioned|#1919" "$PROMPTS_DIR/fix-bot-comment.md"
  [ "$status" -eq 0 ]
}

@test "review-changes.md cites the maintainer-comment gate rationale (#1919)" {
  run grep -qiE "maintainer-comment gate|undispositioned|#1919" "$PROMPTS_DIR/review-changes.md"
  [ "$status" -eq 0 ]
}
