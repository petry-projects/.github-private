#!/usr/bin/env bats
# Regression guard for #1052 (Part C): the dev-lead feedback + implementation
# prompts must instruct the agent NEVER to add/modify a `with:` forward on a
# channel-pinned caller stub for an input the pinned channel does not yet declare,
# and must encode the input-change sequencing (land in reusable → promote channel
# → forward in stub). Without this, an agent applying a "wire this input" request
# reintroduces the #1034 startup_failure class at the source.

PROMPTS_DIR="$(cd "$BATS_TEST_DIRNAME"/../../.. && pwd)/prompts/dev-lead"

# Feedback-applying prompts PLUS the implementation prompt (fix-issue.md) — every
# prompt where the agent may edit a caller stub's forwarding.
FORWARD_GUARD_PROMPTS=(fix-reviews.md review-changes.md fix-bot-comment.md on-mention.md fix-issue.md)

@test "forward guardrail: present in every feedback + implementation prompt (#1052)" {
  for p in "${FORWARD_GUARD_PROMPTS[@]}"; do
    run grep -qiF "channel-pin input forwarding" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "missing forwarding guardrail in prompts/dev-lead/$p"; return 1; }
    run grep -qiF "channel-pinned caller stub" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not name the channel-pinned caller stub"; return 1; }
  done
}

@test "forward guardrail: names the startup_failure failure mode (#1034)" {
  for p in "${FORWARD_GUARD_PROMPTS[@]}"; do
    run grep -qF "startup_failure" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not name startup_failure"; return 1; }
  done
}

@test "forward guardrail: encodes the input-change sequencing (reusable → channel → stub)" {
  for p in "${FORWARD_GUARD_PROMPTS[@]}"; do
    run grep -qiF "land the input in the reusable" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not encode step (1) land in reusable"; return 1; }
    run grep -qiF "promote the pinned channel" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not encode step (2) promote the channel"; return 1; }
    run grep -qiF "cut-release.sh" "$PROMPTS_DIR/$p"
    [ "$status" -eq 0 ] || { echo "guardrail in $p does not name the cut-release.sh promotion tool"; return 1; }
  done
}
