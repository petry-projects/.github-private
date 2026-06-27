#!/usr/bin/env bats
# Regression tests for .github/workflows/feature-ideation.yml compliance.
#
# Guards the invariants checked by the weekly org compliance audit
# (check: non-stub-feature-ideation.yml). The stub now pins the reusable to
# the feature-ideation/next channel tag (the sanctioned ring-release
# mechanism — see the mutable-ref exception in AGENTS.md and
# docs/release/versioning.md) rather than the former @v1 SHA (#629).
#
# Run with: bats tests/test_feature_ideation.bats

FEATURE_IDEATION_YML=".github/workflows/feature-ideation.yml"

# Canonical reusable + channel pin from
# petry-projects/.github/standards/workflows/feature-ideation.yml
REUSABLE="petry-projects/.github/.github/workflows/feature-ideation-reusable.yml"
# The candidate (folded-enhancement) ring channel this repo (next/dogfood) pins to.
CHANNEL="feature-ideation/next"

setup() {
  # Run tests from repo root so relative paths resolve correctly.
  cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

@test "feature-ideation.yml exists" {
  [ -f "$FEATURE_IDEATION_YML" ]
}

@test "feature-ideation.yml calls the org reusable workflow" {
  grep -qF "uses: ${REUSABLE}@" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml pins the reusable to the configured channel tag" {
  grep -F "uses: ${REUSABLE}@" "$FEATURE_IDEATION_YML"
  grep -qF "uses: ${REUSABLE}@${CHANNEL}" "$FEATURE_IDEATION_YML"
}

# ── #934: operator-triggered enhancement backfill ────────────────────────────
# The folded feature-ideation reusable gains a backlog-sweep mode (porting the
# idea-enhancer sweep). The stub exposes it as a boolean workflow_dispatch input
# and forwards it, matching the canonical stub template so the sync is drift-free.

@test "feature-ideation.yml exposes the enhance_backlog backfill-sweep input" {
  # Declared as a workflow_dispatch input AND forwarded in with: → two occurrences.
  run grep -c "enhance_backlog:" "$FEATURE_IDEATION_YML"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "feature-ideation.yml forwards enhance_backlog to the reusable workflow" {
  grep -qE 'enhance_backlog:[[:space:]]*"?\$\{\{[[:space:]]*inputs\.enhance_backlog[[:space:]]*\|\|[[:space:]]*false[[:space:]]*\}\}"?' "$FEATURE_IDEATION_YML"
}

# ── #963: discussion→dispatch redispatch bridge ──────────────────────────────
# claude-code-action aborts on `discussion` event contexts ("Unsupported event
# type: discussion"). So on `discussion: created` we must NOT call the reusable
# inline — instead a `redispatch` job re-invokes this stub via workflow_dispatch
# (which the action supports), mirroring initiative-planner.yml's #618 bridge.
# The `ideate` reusable call then runs only on workflow_dispatch/schedule.

@test "feature-ideation.yml declares a target_discussion workflow_dispatch input" {
  # The dispatched run carries the new Discussion number through this input so
  # single-idea enhancement runs under workflow_dispatch (where the action works).
  run grep -cE '^[[:space:]]+target_discussion:' "$FEATURE_IDEATION_YML"
  [ "$status" -eq 0 ]
  # Declared as a dispatch input AND forwarded in the reusable's with: block.
  [ "$output" -eq 2 ]
}

@test "feature-ideation.yml has a redispatch job that runs only on the discussion event" {
  grep -qE '^[[:space:]]+redispatch:' "$FEATURE_IDEATION_YML"
  # The redispatch job is gated to the discussion event.
  grep -qE "github\.event_name[[:space:]]*==[[:space:]]*['\"]discussion['\"]" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml redispatch job keeps the ideas-category / non-bot guard" {
  grep -qE "github\.event\.discussion\.category\.slug[[:space:]]*==[[:space:]]*['\"]ideas['\"]" "$FEATURE_IDEATION_YML"
  grep -qE "github\.event\.discussion\.user\.type[[:space:]]*!=[[:space:]]*['\"]Bot['\"]" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml redispatch requires GH_PAT_WORKFLOWS (GITHUB_TOKEN won't start a run)" {
  # A workflow_dispatch fired with GITHUB_TOKEN is accepted but never starts a
  # run (loop prevention) — same constraint as the initiative-planner bridge.
  grep -qF "secrets.GH_PAT_WORKFLOWS" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml redispatch forwards target_discussion via workflow_dispatch" {
  grep -qF "gh workflow run feature-ideation.yml" "$FEATURE_IDEATION_YML"
  grep -qE -- '(-f|--field)[[:space:]]+"?target_discussion=' "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml ideate job no longer runs on the discussion event" {
  # The reusable call (single-idea/scan) must run under workflow_dispatch/schedule
  # only; the discussion event is handled by the redispatch bridge.
  grep -qE "github\.event_name[[:space:]]*!=[[:space:]]*['\"]discussion['\"]" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml sources target_discussion from inputs.target_discussion" {
  grep -qE 'target_discussion:[[:space:]]*"?\$\{\{[[:space:]]*inputs\.target_discussion' "$FEATURE_IDEATION_YML"
}
