#!/usr/bin/env bats
# Regression guard for #1254 (#1052 part C): the dev-lead feedback/implementation
# prompts must instruct the agent NEVER to add or modify a `with:` forward on a
# channel-pinned caller stub to pass an input the pinned channel does not yet
# declare. A caller stub pins the reusable at a moving channel tag; forwarding an
# input the channel's commit has not landed makes the reusable call fail at
# runtime (unknown input) — the channel-skew defect (#1052). The prompt must also
# encode the safe sequencing: (1) land the input in the reusable, (2) promote the
# pinned channel via `cut-release.sh --channel` to a commit that declares it,
# (3) only THEN teach the stub to forward it. Mirrors the channel-ref guardrail
# guarded by tests/dev-lead/unit/test_channel_ref_guardrail.bats.

PROMPTS_DIR="$(cd "$BATS_TEST_DIRNAME"/../../.. && pwd)/prompts/dev-lead"

# Every prompt that edits files in response to an issue, CI failure, or
# reviewer/bot/human feedback and could therefore touch a caller stub.
RELEVANT_PROMPTS=(fix-issue.md fix-ci.md fix-reviews.md review-changes.md fix-bot-comment.md on-mention.md)

@test "channel-stub-forward guardrail: present in every relevant prompt (#1254)" {
  for p in "${RELEVANT_PROMPTS[@]}"; do
    run grep -qiE "never (add|forward).*undeclared input" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "missing channel-stub-forward guardrail in prompts/dev-lead/$p"; return 1; }
  done
}

@test "channel-stub-forward guardrail: names the land -> promote -> forward sequencing (#1254)" {
  for p in "${RELEVANT_PROMPTS[@]}"; do
    run grep -qE 'cut-release\.sh .*--channel' "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not name the cut-release.sh --channel promotion step"; return 1; }
  done
}

@test "channel-stub-forward guardrail: cross-references the AGENTS.md subsection (#1254)" {
  for p in "${RELEVANT_PROMPTS[@]}"; do
    run grep -qF 'Caller-stub input forwarding across channel pins' "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not cite the AGENTS.md subsection"; return 1; }
  done
}
