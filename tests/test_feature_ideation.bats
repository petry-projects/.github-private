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
