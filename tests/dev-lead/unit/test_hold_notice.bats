#!/usr/bin/env bats
# Unit tests for scripts/lib/hold-notice.sh — the PURE logic behind the #1767
# "held item" notice. dev-lead silently skipped a held work item (a hold label
# present) and said nothing on the item, so the skip looked like a stalled agent.
# These tests pin the deterministic decisions per ADR-0004 (no network, no LLM):
#
#   AC1/AC3 — the notice body names the SPECIFIC blocking label and how to
#             re-enable pickup; dev-lead:hands-off and needs-human-review are not
#             collapsed into generic wording.
#   AC2/AC6 — idempotency: given a hold-label skip a notice is emitted once, and
#             a second skip on the same item+label emits nothing.
#   AC4     — re-arm: a superseded (collapsed) notice no longer suppresses a fresh
#             notice, and the supersede rewrite is itself idempotent.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/hold-notice.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── markers ───────────────────────────────────────────────────────────────────

@test "active marker embeds the exact label" {
  run hold_notice_active_marker "needs-human-review"
  [ "$status" -eq 0 ]
  [ "$output" = "<!-- dev-lead-hold-notice label=needs-human-review -->" ]
}

@test "superseded marker is distinct from the active marker" {
  active="$(hold_notice_active_marker "needs-human-review")"
  superseded="$(hold_notice_superseded_marker "needs-human-review")"
  [ "$active" != "$superseded" ]
  # A superseded marker must NOT contain the active marker as a substring, or the
  # idempotency check would treat a collapsed notice as still-active (breaks re-arm).
  case "$superseded" in
    *"$active"*) return 1 ;;
  esac
}

# ── body content (AC1, AC3) ─────────────────────────────────────────────────────

@test "notice body names the blocking label and how to re-enable" {
  run hold_notice_body "needs-human-review"
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs-human-review"* ]]
  # first line is the idempotency marker — extract via parameter expansion, not
  # a `head -1` pipe, which can raise SIGPIPE (exit 141) under set -o pipefail.
  first="${output%%$'\n'*}"
  [ "$first" = "<!-- dev-lead-hold-notice label=needs-human-review -->" ]
  # names how to re-enable
  [[ "$output" == *"remove"* || "$output" == *"Remove"* ]]
}

@test "hands-off and needs-human-review produce distinct wording (AC3)" {
  hands_off="$(hold_notice_body "dev-lead:hands-off")"
  needs_review="$(hold_notice_body "needs-human-review")"
  [[ "$hands_off" == *"dev-lead:hands-off"* ]]
  [[ "$needs_review" == *"needs-human-review"* ]]
  # Not collapsed into identical generic text.
  [ "$hands_off" != "$needs_review" ]
}

# ── idempotency (AC2, AC6) ───────────────────────────────────────────────────────

@test "should_post: emits when no prior notice exists (first skip)" {
  run hold_notice_should_post "needs-human-review" "some unrelated comment body"
  [ "$status" -eq 0 ]
}

@test "should_post: silent no-op on a second skip for the same label (AC2/AC6)" {
  existing="$(hold_notice_body "needs-human-review")"
  run hold_notice_should_post "needs-human-review" "$existing"
  [ "$status" -eq 1 ]
}

@test "should_post: a notice for a DIFFERENT label does not suppress this one" {
  existing="$(hold_notice_body "dev-lead:hands-off")"
  run hold_notice_should_post "needs-human-review" "$existing"
  [ "$status" -eq 0 ]
}

# ── supersede / re-arm (AC4) ─────────────────────────────────────────────────────

@test "supersede_body collapses the notice and neutralizes its active marker" {
  original="$(hold_notice_body "needs-human-review")"
  collapsed="$(hold_notice_supersede_body "$original")"
  # wrapped in a collapsible details block
  [[ "$collapsed" == *"<details>"* ]]
  [[ "$collapsed" == *"</details>"* ]]
  # carries the superseded sentinel
  [[ "$collapsed" == *"<!-- dev-lead-hold-notice superseded"* ]]
  # the ACTIVE marker is gone, so the item no longer reads as still-held
  active="$(hold_notice_active_marker "needs-human-review")"
  case "$collapsed" in
    *"$active"*) return 1 ;;
  esac
}

@test "re-arm: after supersede, a fresh notice for the same label is emitted again (AC4)" {
  original="$(hold_notice_body "needs-human-review")"
  collapsed="$(hold_notice_supersede_body "$original")"
  run hold_notice_should_post "needs-human-review" "$collapsed"
  [ "$status" -eq 0 ]
}

@test "supersede_body is idempotent — an already-collapsed notice is unchanged" {
  original="$(hold_notice_body "needs-human-review")"
  once="$(hold_notice_supersede_body "$original")"
  twice="$(hold_notice_supersede_body "$once")"
  [ "$once" = "$twice" ]
}

@test "supersede_body(#2089): replaced by another hold label never claims the hold was lifted" {
  original="$(hold_notice_body "dev-lead:hands-off")"
  collapsed="$(hold_notice_supersede_body "$original" "needs-human-review")"
  [[ "$collapsed" == *"<!-- dev-lead-hold-notice superseded label=dev-lead:hands-off -->"* ]]
  [[ "$collapsed" == *"now withholding action under the \`needs-human-review\` label"* ]]
  [[ "$collapsed" != *"was lifted"* ]]
  [[ "$collapsed" != *"picked this item up"* ]]
}

@test "supersede_body(#2089): no replacing label (pickup) keeps the lifted wording" {
  original="$(hold_notice_body "dev-lead:hands-off")"
  collapsed="$(hold_notice_supersede_body "$original")"
  [[ "$collapsed" == *"hold was lifted; dev-lead has picked this item up"* ]]
}

@test "hold-notice wrapper(#2089): a hold that changes label rewrites the stale notice as superseded, not lifted" {
  # Drive the real wrapper with gh stubbed: the item has a live dev-lead:hands-off
  # notice and is now held under needs-human-review. Capture the PATCH body.
  local stub="$BATS_TEST_TMPDIR/bin" old
  mkdir -p "$stub"
  old="$(hold_notice_body "dev-lead:hands-off")"
  jq -n --arg b "$old" '[{id: 7, user: {login: "dl-bot"}, body: $b}]' > "$BATS_TEST_TMPDIR/comments.json"
  jq -n --arg b "$old" '$b' > "$BATS_TEST_TMPDIR/old.json"
  cat > "$stub/gh" <<'GHEOF'
#!/bin/bash
case "$*" in
  *"--paginate repos/o/r/issues/5/comments"*) cat "$T/comments.json" ;;
  *"-X PATCH repos/o/r/issues/comments/7"*) cat > "$T/patch.json" ;;
  *"repos/o/r/issues/comments/7"*) jq -r . "$T/old.json" ;;
  *"issue comment 5"*) cat > "$T/posted.txt" ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$stub/gh"
  T="$BATS_TEST_TMPDIR" PATH="$stub:$PATH" REPO=o/r SUBJECT_NUMBER=5 HOLD_LABEL=needs-human-review \
    NOTICE_AUTHOR=dl-bot DEV_LEAD_DRY_RUN=false DRY_RUN=false \
    run bash "$SCRIPT_DIR/scripts/dev-lead-hold-notice.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"collapsed stale hold notice 7"* ]]
  local patched; patched="$(jq -r .body "$BATS_TEST_TMPDIR/patch.json")"
  [[ "$patched" == *"<!-- dev-lead-hold-notice superseded label=dev-lead:hands-off -->"* ]]
  [[ "$patched" == *"withholding action under the \`needs-human-review\` label"* ]]
  [[ "$patched" != *"was lifted"* ]]
  [[ "$patched" != *"picked this item up"* ]]
  grep -q 'dev-lead-hold-notice label=needs-human-review' "$BATS_TEST_TMPDIR/posted.txt"
}

@test "body_has_active_hold_notice: true for a live notice, false once collapsed" {
  original="$(hold_notice_body "needs-human-review")"
  run body_has_active_hold_notice "$original"
  [ "$status" -eq 0 ]
  collapsed="$(hold_notice_supersede_body "$original")"
  run body_has_active_hold_notice "$collapsed"
  [ "$status" -eq 1 ]
}

@test "label_from_body round-trips the label out of a notice body" {
  original="$(hold_notice_body "dev-lead:needs-human")"
  run hold_notice_label_from_body "$original"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead:needs-human" ]
}
