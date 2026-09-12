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
