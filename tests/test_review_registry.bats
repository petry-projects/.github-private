#!/usr/bin/env bats
# Unit tests for the rubric-registry lookup helper in
# scripts/lib/review-registry.sh (issue #611).
#
# The registry is an input-adapter layer ABOVE engine.sh: it maps an
# artifact_type to the rubric (prompt cascade) and output_channel that should
# review it. Phase 1 registers only pr_diff, which must resolve to today's
# behavior with no change.
#
# Run with: bats tests/test_review_registry.bats
# Install bats: https://github.com/bats-core/bats-core

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/review-registry.sh"
}

# ---------------------------------------------------------------------------
# Schema version
# ---------------------------------------------------------------------------

@test "reports a non-empty integer schema version" {
  run review_registry_version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# Registered types — pr_diff is the SOLE type (AC #2)
# ---------------------------------------------------------------------------

@test "pr_diff is registered" {
  run review_registry_types
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "pr_diff"
}

@test "pr_diff is the only registered type" {
  run review_registry_types
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c .)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Lookup — rubric resolves to the existing cascade (AC #3)
# ---------------------------------------------------------------------------

@test "pr_diff rubric resolves to the triage -> deep-review -> synthesize cascade" {
  run review_registry_lookup pr_diff rubric
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/triage.md,prompts/deep-review.md,prompts/synthesize.md" ]
}

@test "pr_diff output_channel resolves to post-pr-review.sh" {
  run review_registry_lookup pr_diff output_channel
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/post-pr-review.sh" ]
}

# ---------------------------------------------------------------------------
# Lookup errors — unknown type / field fail non-zero
# ---------------------------------------------------------------------------

@test "unknown artifact_type fails non-zero" {
  run review_registry_lookup plan rubric
  [ "$status" -ne 0 ]
}

@test "unknown field fails non-zero" {
  run review_registry_lookup pr_diff not_a_field
  [ "$status" -ne 0 ]
}

@test "missing artifact_type argument fails non-zero" {
  run review_registry_lookup
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The registry references TODAY's cascade, not a copy (AC #3): every
# referenced rubric file and the output_channel must exist on disk.
# ---------------------------------------------------------------------------

@test "every referenced rubric file exists" {
  run review_registry_lookup pr_diff rubric
  [ "$status" -eq 0 ]
  IFS=',' read -ra rubric_files <<< "$output"
  [ "${#rubric_files[@]}" -gt 0 ]
  for f in "${rubric_files[@]}"; do
    [ -f "$REPO_ROOT/$f" ] || { echo "missing rubric file: $f"; false; }
  done
}

@test "referenced output_channel exists" {
  run review_registry_lookup pr_diff output_channel
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/$output" ]
}
