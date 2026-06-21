#!/usr/bin/env bats
# Regression guard for #871: the dev-lead feedback-applying prompts must instruct
# the agent NEVER to SHA-pin a first-party channel ref (the moving channel tags are
# the release/rollback mechanism — AGENTS.md mutable-ref exception). Without this,
# the agent applies a bot "pin this action to a SHA" finding and freezes the caller,
# breaking the ring/canary model (see TalkTerm #306 commit a27accce).

PROMPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/prompts/dev-lead"

# Every prompt that edits files in response to reviewer/bot/human feedback.
FEEDBACK_PROMPTS=(fix-reviews.md review-changes.md fix-bot-comment.md on-mention.md)

@test "channel-ref guardrail: present in every feedback-applying prompt (#871)" {
  for p in "${FEEDBACK_PROMPTS[@]}"; do
    run grep -qiE "never SHA-pin a first-party channel ref" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "missing channel-ref guardrail in prompts/dev-lead/$p"; return 1; }
  done
}

@test "channel-ref guardrail: names the channel pattern and the AGENTS.md exception" {
  for p in "${FEEDBACK_PROMPTS[@]}"; do
    run grep -qF 'dev-lead|pr-review)/(stable|next|ring' "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not name the channel pattern"; return 1; }
    run grep -qiE "mutable-ref exception|mutable ref" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not cite the AGENTS.md exception"; return 1; }
  done
}
