#!/usr/bin/env bats
# Wiring tests for the pr_diff dispatch in scripts/review-one-pr.sh (issue #612).
#
# Phase 1 of the artifact-contract extraction (epic #610): the production PR
# reviewer must dispatch through the rubric registry for artifact_type=pr_diff
# instead of hard-coding the cascade. These tests lock in that wiring without
# running the cascade end-to-end (which needs live engines + the GitHub API):
#   - review-one-pr.sh sources the registry helper,
#   - it resolves the pr_diff output_channel via the registry helper,
#   - it posts via the resolved channel rather than a hard-coded path,
#   - and the registry still resolves pr_diff to today's behavior (AC #1, #3).
#
# Run with: bats tests/test_pr_diff_dispatch.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  source "$REPO_ROOT/scripts/lib/review-registry.sh"
}

# ---------------------------------------------------------------------------
# The dispatch routes through the registry helper (AC #1)
# ---------------------------------------------------------------------------

@test "review-one-pr.sh sources the rubric registry helper" {
  run grep -qE 'lib/review-registry\.sh' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review-one-pr.sh dispatches on artifact_type=pr_diff" {
  run grep -qE 'pr_diff' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review-one-pr.sh resolves the output_channel via the registry helper" {
  run grep -qE 'review_registry_lookup[^|]*output_channel' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review-one-pr.sh resolves the rubric via the registry helper" {
  run grep -qE 'review_registry_lookup[^|]*rubric' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The output_channel is registry-driven, not hard-coded (AC #1, #3)
# ---------------------------------------------------------------------------

@test "review-one-pr.sh no longer hard-codes the post-pr-review.sh path at call sites" {
  # The verdict is posted via the resolved channel variable, so the literal
  # 'bash scripts/post-pr-review.sh' invocation must be gone.
  run grep -nE 'bash[[:space:]]+scripts/post-pr-review\.sh' "$REVIEW_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "review-one-pr.sh invokes the resolved output channel variable" {
  run grep -qE 'bash[[:space:]]+"\$\{?REVIEW_OUTPUT_CHANNEL\}?"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The registry still resolves pr_diff to today's output channel (AC #3): the
# dispatch must not silently change where the verdict is delivered.
# ---------------------------------------------------------------------------

@test "registry resolves pr_diff output_channel to post-pr-review.sh" {
  run review_registry_lookup pr_diff output_channel
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/post-pr-review.sh" ]
}

@test "registry pr_diff rubric leads with the triage -> deep-review prompts" {
  run review_registry_lookup pr_diff rubric
  [ "$status" -eq 0 ]
  # The first two cascade entries are the tier-1 and tier-2 prompts the
  # dispatch binds; they must remain the existing prompt files.
  [[ "$output" == prompts/triage.md,prompts/deep-review.md* ]]
}
