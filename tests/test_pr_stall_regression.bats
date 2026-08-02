#!/usr/bin/env bats
# Un-eventable-transition regression for the stall detector (issue #1410, AC#3).
#
# THE SAFETY PROPERTY THIS PINS
# -----------------------------
# The whole point of #1410 is to build the instrument BEFORE the Class-2 backstop
# timers (`dev-lead-retry`, `pr-review-sweep`) are narrowed. The narrowing trades a
# known-noisy failure mode for a possible SILENT one: a genuinely un-eventable
# transition — CI settling green with no `workflow_run` fast path, e.g. a
# cross-repo or GitHub-App check like SonarCloud — that the fast path can never
# scope to, and that (once the cron backstop is narrowed) nothing would sweep.
#
# The QA-Lead advisory is explicit that "budget + stop-marker respected" is NOT
# sufficient proof. The real bar: the class the cron previously caught must STILL
# be caught after the narrowing — surfaced by the pushed detector so a human/
# backstop resolves it, instead of stalling unseen (the #860 blindness, in the
# opposite direction). These tests use the REAL ci-status classifier plus the real
# stall lib so the SonarCloud "green" premise is not hand-waved.
#
# Run with: bats tests/test_pr_stall_regression.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/ci-status.sh"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-stall-detect.sh"

  # A rollup whose ONLY external check is a SonarCloud GitHub-App analysis that has
  # settled SUCCESS. It carries no `workflowName` (it is an App/commit-status check,
  # not one of this repo's Actions workflows), so no `workflow_run: completed` event
  # in this repo ever fires for it — the sweep's fast path is structurally blind to
  # this transition. This is the exact "un-eventable green" fingerprint.
  SONAR_GREEN_ROLLUP='[{"name":"SonarCloud Code Analysis","status":"COMPLETED","conclusion":"SUCCESS"}]'
}

# ---------------------------------------------------------------------------
# Premise: the SonarCloud-only rollup really is CI-green, per the real classifier.
# ---------------------------------------------------------------------------

@test "premise: a SonarCloud GitHub-App check settling SUCCESS is classified CI-passing" {
  run compute_ci_status "$SONAR_GREEN_ROLLUP"
  [ "$status" -eq 0 ]
  [ "$output" = "passing" ]
}

# ---------------------------------------------------------------------------
# THE CORE PROPERTY: the un-eventable green -> REVIEW_REQUIRED transition, left
# idle past the threshold with no fast-path event to re-fire it, IS caught by the
# stall detector. This is what makes it "still resolve" after the narrowing —
# it becomes a pushed signal instead of a silent stall.
# ---------------------------------------------------------------------------

@test "AC#3: the un-eventable green transition is caught by the stall detector (resolves, not silent)" {
  local ci
  ci=$(compute_ci_status "$SONAR_GREEN_ROLLUP")
  # green + REVIEW_REQUIRED + never reviewed at head + idle 90m (>30m) + not gated
  run is_pr_stall "$ci" REVIEW_REQUIRED 0 90 false
  [ "$status" -eq 0 ]
}

@test "AC#3: the caught stall names the green + REVIEW_REQUIRED, no-pending-event condition" {
  local ci
  ci=$(compute_ci_status "$SONAR_GREEN_ROLLUP")
  run pr_stall_reasons "$ci" REVIEW_REQUIRED 0 90 false
  [[ "$output" == *"REVIEW_REQUIRED"* ]]
  [[ "$output" == *"no agent activity or pending event"* ]]
}

# ---------------------------------------------------------------------------
# "budget + stop-marker respected" is NOT sufficient proof, and this is where we
# prove the detector does NOT conflate the un-eventable stall with the LEGITIMATE
# human-gated halts. Each intentional stop is fail-quiet (never reported).
# ---------------------------------------------------------------------------

@test "AC#2/#3: each human-gated halt on the SAME green state is fail-quiet (not a stall)" {
  local ci
  ci=$(compute_ci_status "$SONAR_GREEN_ROLLUP")

  # needs-human-review (the automation-budget / cycle-cap escalation label)
  gated=false; pr_stall_is_gated '["needs-human-review"]' && gated=true
  run is_pr_stall "$ci" REVIEW_REQUIRED 0 90 "$gated"
  [ "$status" -ne 0 ]

  # the pr-automation-budget exhaustion marker (comment), even with no label yet
  gated=false; pr_stall_is_gated '[]' true && gated=true
  run is_pr_stall "$ci" REVIEW_REQUIRED 0 90 "$gated"
  [ "$status" -ne 0 ]

  # dev-lead:hands-off (PR intentionally excluded from the agent)
  gated=false; pr_stall_is_gated '["dev-lead:hands-off"]' && gated=true
  run is_pr_stall "$ci" REVIEW_REQUIRED 0 90 "$gated"
  [ "$status" -ne 0 ]

  # initiative:hold (work deliberately held)
  gated=false; pr_stall_is_gated '["initiative:hold"]' && gated=true
  run is_pr_stall "$ci" REVIEW_REQUIRED 0 90 "$gated"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The converse of "still resolves": once the automated step actually runs (a
# review lands at head), the transition HAS resolved and the signal clears — the
# detector must not keep flagging a PR that is no longer stalled.
# ---------------------------------------------------------------------------

@test "AC#3: once a review lands at head, the resolved transition clears the stall signal" {
  local ci
  ci=$(compute_ci_status "$SONAR_GREEN_ROLLUP")
  run is_pr_stall "$ci" REVIEW_REQUIRED 1 90 false
  [ "$status" -ne 0 ]
}
