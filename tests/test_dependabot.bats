#!/usr/bin/env bats
# Regression tests for .github/dependabot.yml compliance.
#
# Guards the invariants checked by the weekly org compliance audit
# to prevent re-filing of missing-*-label findings.
#
# Run with: bats tests/test_dependabot.bats

DEPENDABOT_YML=".github/dependabot.yml"

setup() {
  # Run tests from repo root so relative paths resolve correctly.
  cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

@test "dependabot.yml exists" {
  [ -f "$DEPENDABOT_YML" ]
}

@test "dependabot.yml has github-actions ecosystem" {
  grep -qE 'package-ecosystem:[[:space:]]*(\"github-actions\"|'"'"'github-actions'"'"'|github-actions)' "$DEPENDABOT_YML"
}

@test "dependabot.yml has security label (compliance-audit check)" {
  [[ "$(yq '.updates[] | select(.["package-ecosystem"] == "github-actions") | .labels[] | select(. == "security")' "$DEPENDABOT_YML")" == "security" ]]
}

@test "dependabot.yml has dependencies label (compliance-audit check)" {
  [[ "$(yq '.updates[] | select(.["package-ecosystem"] == "github-actions") | .labels[] | select(. == "dependencies")' "$DEPENDABOT_YML")" == "dependencies" ]]
}

@test "dependabot.yml github-actions entry has open-pull-requests-limit: 10" {
  [[ "$(yq '.updates[] | select(.["package-ecosystem"] == "github-actions") | .["open-pull-requests-limit"]' "$DEPENDABOT_YML")" == "10" ]]
}

@test "dependabot.yml schedule is weekly" {
  grep -qE 'interval:[[:space:]]*("weekly"|'"'"'weekly'"'"'|weekly)' "$DEPENDABOT_YML"
}
