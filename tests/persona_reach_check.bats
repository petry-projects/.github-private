#!/usr/bin/env bats
# Tests for scripts/persona_reach_check.sh — the consumer-reached / no-new-trigger-surface
# verification guard for a mention-routed persona (#1631, epic #1627).
#
# The guard exists because a ring label moving is NOT evidence a promotion reached
# a consumer (Discussion #1360 learning 12): a mention-routed persona is served by
# the shared persona-mention router, so promotion must be verified by a live mention
# resolving to the promoted persona, and promotion must add no new trigger surface.
# The pure predicates below are the hermetic, re-runnable core of that check.
#
# Run with: bats tests/persona_reach_check.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/persona_reach_check.sh"

setup() {
  # shellcheck source=scripts/persona_reach_check.sh
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# prc_surface_is_mention_only <events_csv>
# AC #5: promotion adds no trigger surface beyond the shared mention router.
# ---------------------------------------------------------------------------

@test "prc_surface_is_mention_only: the three deployed mention events are accepted" {
  run prc_surface_is_mention_only "issue_comment,pull_request_review_comment,discussion_comment"
  [ "$status" -eq 0 ]
}

@test "prc_surface_is_mention_only: a subset of the mention events is accepted" {
  run prc_surface_is_mention_only "issue_comment"
  [ "$status" -eq 0 ]
}

@test "prc_surface_is_mention_only: ignores surrounding whitespace" {
  run prc_surface_is_mention_only " issue_comment , discussion_comment "
  [ "$status" -eq 0 ]
}

@test "prc_surface_is_mention_only: rejects a new pull_request synchronize surface" {
  run prc_surface_is_mention_only "issue_comment,pull_request"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pull_request"* ]]
}

@test "prc_surface_is_mention_only: rejects an added schedule/cron surface" {
  run prc_surface_is_mention_only "issue_comment,schedule"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schedule"* ]]
}

@test "prc_surface_is_mention_only: rejects an empty surface (nothing routes)" {
  run prc_surface_is_mention_only ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# prc_is_past_draft <status>
# ---------------------------------------------------------------------------

@test "prc_is_past_draft: draft is not past draft" {
  run prc_is_past_draft "draft"
  [ "$status" -ne 0 ]
}

@test "prc_is_past_draft: next/ring0/ring1/stable are past draft" {
  for s in next ring0 ring1 stable; do
    run prc_is_past_draft "$s"
    [ "$status" -eq 0 ]
  done
}

# ---------------------------------------------------------------------------
# prc_promotion_verdict <status> <registered>
# AC #4 / learning 12: routes-to != promoted. The guard fails ONLY on the skew
# state (ring label past draft with no cross-repo registration) — the #1052
# hollow-green hazard — not on an honest still-draft persona.
# ---------------------------------------------------------------------------

@test "prc_promotion_verdict: draft is 'draft' and is a safe (exit 0) state" {
  run prc_promotion_verdict "draft" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "draft" ]
}

@test "prc_promotion_verdict: draft stays 'draft' even if routing wiring exists" {
  # routes-to != promoted: registration true but still draft is not yet promoted.
  run prc_promotion_verdict "draft" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "draft" ]
}

@test "prc_promotion_verdict: past draft WITH registration is 'promoted' (exit 0)" {
  run prc_promotion_verdict "next" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "promoted" ]
}

@test "prc_promotion_verdict: past draft WITHOUT registration is 'skew' and fails" {
  run prc_promotion_verdict "next" "false"
  [ "$status" -ne 0 ]
  [ "$output" = "skew" ]
}
