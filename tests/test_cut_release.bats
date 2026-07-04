#!/usr/bin/env bats
# Unit tests for the pure helpers in scripts/cut-release.sh
# (valid_agent, validate_version, release_ref, channel_ref). The git-backed
# flow in main() is not exercised here.
#
# Run with: bats tests/test_cut_release.bats

setup() {
  # Sourcing must NOT run main() (source-guard); it only defines the helpers.
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/cut-release.sh"
}

# ---------------------------------------------------------------------------
# valid_agent
# ---------------------------------------------------------------------------

# A this-repo cut creates a LOCAL annotated tag (`git tag -a`), which aborts with
# "fatal: empty ident name" on a bare runner. cut-release.sh must source the shared
# git-identity helper so the this-repo path can set a tagger identity (#1069 regression).
@test "cut-release wires the shared git-identity helper for the this-repo annotated-tag cut" {
  run declare -F setup_git_identity
  [ "$status" -eq 0 ]
}

@test "cut-release: setup_git_identity call precedes git tag -a in the this-repo annotated-tag path" {
  # Regression guard: asserts the call ordering in source so this test fails
  # if setup_git_identity is ever removed from before git tag -a (#1069).
  local script id_line tag_line
  script="$(dirname "$BATS_TEST_FILENAME")/../scripts/cut-release.sh"
  id_line=$(grep -n '^[[:space:]]*setup_git_identity[[:space:]]*$' "$script" | cut -d: -f1)
  tag_line=$(grep -n '^[[:space:]]*git tag -a' "$script" | cut -d: -f1)
  [ -n "$id_line" ]
  [ -n "$tag_line" ]
  [ "$id_line" -lt "$tag_line" ]
}

@test "valid_agent: pr-review is accepted" {
  run valid_agent "pr-review"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dev-lead is accepted" {
  run valid_agent "dev-lead"
  [ "$status" -eq 0 ]
}

@test "valid_agent: feature-ideation is accepted" {
  run valid_agent "feature-ideation"
  [ "$status" -eq 0 ]
}

# The six .github-hosted reusables migrated by #482, brought under the ring model (#870).
@test "valid_agent: agent-shield is accepted" {
  run valid_agent "agent-shield"
  [ "$status" -eq 0 ]
}

@test "valid_agent: auto-rebase is accepted" {
  run valid_agent "auto-rebase"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dependency-audit is accepted" {
  run valid_agent "dependency-audit"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dependabot-automerge is accepted" {
  run valid_agent "dependabot-automerge"
  [ "$status" -eq 0 ]
}

@test "valid_agent: dependabot-rebase is accepted" {
  run valid_agent "dependabot-rebase"
  [ "$status" -eq 0 ]
}

@test "valid_agent: pr-review-mention is accepted" {
  run valid_agent "pr-review-mention"
  [ "$status" -eq 0 ]
}

@test "valid_agent: unknown agent is rejected" {
  run valid_agent "ci-failure-analyst"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# cross_repo_agent — agents whose reusable lives in petry-projects/.github
# (this repo holds only the thin caller stub), so live cuts are refused until
# the cross-repo push target is wired (TODO #872).
# ---------------------------------------------------------------------------

@test "cross_repo_agent: feature-ideation is cross-repo" {
  run cross_repo_agent "feature-ideation"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: agent-shield is cross-repo" {
  run cross_repo_agent "agent-shield"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: auto-rebase is cross-repo" {
  run cross_repo_agent "auto-rebase"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: dependency-audit is cross-repo" {
  run cross_repo_agent "dependency-audit"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: dependabot-automerge is cross-repo" {
  run cross_repo_agent "dependabot-automerge"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: dependabot-rebase is cross-repo" {
  run cross_repo_agent "dependabot-rebase"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: pr-review-mention is cross-repo" {
  run cross_repo_agent "pr-review-mention"
  [ "$status" -eq 0 ]
}

@test "cross_repo_agent: pr-review is NOT cross-repo (hosted here)" {
  run cross_repo_agent "pr-review"
  [ "$status" -ne 0 ]
}

@test "cross_repo_agent: dev-lead is NOT cross-repo (hosted here)" {
  run cross_repo_agent "dev-lead"
  [ "$status" -ne 0 ]
}

@test "cross_repo_agent: unknown agent is NOT cross-repo" {
  run cross_repo_agent "ci-failure-analyst"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# validate_version — strict MAJOR.MINOR.PATCH
# ---------------------------------------------------------------------------

@test "validate_version: 1.0.0 is valid" {
  run validate_version "1.0.0"
  [ "$status" -eq 0 ]
}

@test "validate_version: 12.4.37 is valid" {
  run validate_version "12.4.37"
  [ "$status" -eq 0 ]
}

@test "validate_version: leading v is rejected" {
  run validate_version "v1.0.0"
  [ "$status" -ne 0 ]
}

@test "validate_version: two-part version is rejected" {
  run validate_version "1.2"
  [ "$status" -ne 0 ]
}

@test "validate_version: four-part version is rejected" {
  run validate_version "1.2.3.4"
  [ "$status" -ne 0 ]
}

@test "validate_version: non-numeric is rejected" {
  run validate_version "1.2.x"
  [ "$status" -ne 0 ]
}

@test "validate_version: empty is rejected" {
  run validate_version ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# release_ref / channel_ref — tag-name formatting
# ---------------------------------------------------------------------------

@test "release_ref: prepends agent and v" {
  run release_ref "pr-review" "1.0.0"
  [ "$output" = "pr-review/v1.0.0" ]
}

@test "release_ref: dev-lead variant" {
  run release_ref "dev-lead" "2.3.1"
  [ "$output" = "dev-lead/v2.3.1" ]
}

@test "release_ref: feature-ideation variant" {
  run release_ref "feature-ideation" "1.4.0"
  [ "$output" = "feature-ideation/v1.4.0" ]
}

@test "release_ref: agent-shield variant" {
  run release_ref "agent-shield" "1.0.0"
  [ "$output" = "agent-shield/v1.0.0" ]
}

@test "release_ref: dependabot-automerge variant" {
  run release_ref "dependabot-automerge" "2.1.3"
  [ "$output" = "dependabot-automerge/v2.1.3" ]
}

@test "channel_ref: agent-scoped channel name" {
  run channel_ref "pr-review" "stable"
  [ "$output" = "pr-review/stable" ]
}

@test "channel_ref: next channel" {
  run channel_ref "dev-lead" "next"
  [ "$output" = "dev-lead/next" ]
}

@test "channel_ref: feature-ideation ring0 channel" {
  run channel_ref "feature-ideation" "ring0"
  [ "$output" = "feature-ideation/ring0" ]
}

@test "channel_ref: pr-review-mention next channel" {
  run channel_ref "pr-review-mention" "next"
  [ "$output" = "pr-review-mention/next" ]
}

@test "channel_ref: auto-rebase stable channel" {
  run channel_ref "auto-rebase" "stable"
  [ "$output" = "auto-rebase/stable" ]
}

# ---------------------------------------------------------------------------
# strip_origin — normalize a local-style ref to a remote-repo ref name (#872)
# ---------------------------------------------------------------------------

@test "strip_origin: origin/main becomes main" {
  run strip_origin "origin/main"
  [ "$output" = "main" ]
}

@test "strip_origin: a bare ref passes through" {
  run strip_origin "main"
  [ "$output" = "main" ]
}

@test "strip_origin: a SHA passes through" {
  run strip_origin "376a4fcb1117444595e3e702fa450873d0e54310"
  [ "$output" = "376a4fcb1117444595e3e702fa450873d0e54310" ]
}

@test "strip_origin: only the leading origin/ is stripped" {
  run strip_origin "origin/release/origin/x"
  [ "$output" = "release/origin/x" ]
}
