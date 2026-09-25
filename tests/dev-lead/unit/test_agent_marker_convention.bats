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
#
# These assertions tie the marker to the comment-emitting instruction by scanning
# the context window around EACH `gh pr comment` line independently — every
# occurrence must carry the marker within its own window. A whole-file grep (or one
# that concatenates every window before matching) would let a single marked example
# vouch for an unmarked sibling instruction: a later prompt change could add a new
# unmarked `gh pr comment` and the assertion would stay green because some other
# block still holds the marker — the exact regression #1919 guards against.

# assert_each_pr_comment_marked FILE MARKER
# Fails unless there is at least one `gh pr comment` occurrence AND every one has
# MARKER within its surrounding context window (2 lines before, 6 after), checked
# per occurrence so no single marked block can vouch for an unmarked sibling.
assert_each_pr_comment_marked() {
  local file="$1" marker="$2"
  local found=0 lineno start end total
  total=$(wc -l < "$file")
  while IFS=: read -r lineno _; do
    [ -n "$lineno" ] || continue
    found=1
    start=$(( lineno - 2 < 1 ? 1 : lineno - 2 ))
    end=$(( lineno + 6 > total ? total : lineno + 6 ))
    sed -n "${start},${end}p" "$file" | grep -qF "$marker" || return 1
  done < <(grep -nF 'gh pr comment' "$file")
  [ "$found" -eq 1 ]
}

@test "review-changes.md failing-check PR comment instruction carries a dev-lead marker (#1919)" {
  # The failing-check fix note is posted as a PR issue comment; every gh pr comment
  # instruction that emits it must carry the check-fix marker in its own window.
  run assert_each_pr_comment_marked "$PROMPTS_DIR/review-changes.md" '<!-- dev-lead:check-fix -->'
  [ "$status" -eq 0 ]
}

@test "fix-bot-comment.md dispositions non-actionable bot-notice comments (#1919)" {
  # A non-actionable bot issue-comment notice (trial-ended, usage-limit, rate-limit)
  # is NOT auto-cleared by the info-status classifier, so a plain ack or suppression
  # leaves the ORIGINAL comment an undispositioned maintainer-gate blocker. The prompt
  # must instead disposition the original via the verified comment-disposition marker,
  # stamped on each gh pr comment instruction that emits the disposition reply.
  run assert_each_pr_comment_marked "$PROMPTS_DIR/fix-bot-comment.md" '<!-- dev-lead:comment-disposition'
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

# #1919 (Codex P1 on PR #1920): the triggering bot comment's body is untrusted text.
# It must never be interpolated into a shell command the agent is told to run,
# because quotes, backticks or $(…) in it would break the command or execute. The
# prompt targets the notice by COMMENT_NODE_ID instead.
@test "fix-bot-comment: COMMENT_NODE_ID is a declared template variable" {
  head -1 "$PROMPTS_DIR/fix-bot-comment.md" | grep -qF 'COMMENT_NODE_ID'
}

@test "fix-bot-comment: no fenced bash block interpolates COMMENT_BODY" {
  run awk '/^[[:space:]]*```bash/{inb=1; next} /^[[:space:]]*```/{inb=0} inb && /COMMENT_BODY/{print NR": "$0; bad=1} END{exit bad}' "$PROMPTS_DIR/fix-bot-comment.md"
  [ "$status" -eq 0 ] || { echo "COMMENT_BODY inside a bash block: $output"; return 1; }
}

@test "fix-bot-comment: the reusable validates and forwards the comment node id" {
  local wf; wf="$(cd "$BATS_TEST_DIRNAME"/../../.. && pwd)/.github/workflows/dev-lead-reusable.yml"
  grep -qF 'INTENT_COMMENT_NODE_ID=' "$wf"
  grep -qE '\[\[ "\$_cnid" =~ \^\[A-Za-z0-9_-\]\+\$ \]\]' "$wf"
  grep -qF 'COMMENT_NODE_ID: ${{ env.INTENT_COMMENT_NODE_ID }}' "$wf"
}
