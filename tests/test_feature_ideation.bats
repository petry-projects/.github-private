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

@test "feature-ideation.yml pins the reusable to the feature-ideation/next channel tag" {
  grep -qF "uses: ${REUSABLE}@${CHANNEL}" "$FEATURE_IDEATION_YML"
}
