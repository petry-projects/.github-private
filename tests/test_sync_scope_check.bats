#!/usr/bin/env bats
# Unit tests for the sync-PR scope guard (scripts/lib/sync-scope-check.sh, #1700 AC1).
#
# #1523 survived three weeks / 255 commits because a generated sync PR that
# claimed to sync three workflow stubs was allowed to also touch package.json,
# prompts/**, evals/** and scripts/**. This guard is the mechanical net: a
# generated sync PR whose diff strays outside its declared path set fails a
# required check. The logic is pure/deterministic (literal + glob, no model).
#
# The tests pin: declared-path extraction from the PR-body marker, generated-PR
# identification (human PRs are out of scope — AC4), the in-scope pass, the
# out-of-scope failure that NAMES the offending paths, glob matching, and — most
# importantly — the retroactive #1523 fixture (AC3).
#
# Run with: bats tests/test_sync_scope_check.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/sync-scope-check.sh"
  FIXTURES="$(dirname "$BATS_TEST_FILENAME")/fixtures/sync-scope"
}

# ---------------------------------------------------------------------------
# sync_extract_declared_paths — pull the declared set out of the body marker
# ---------------------------------------------------------------------------

@test "declared paths are extracted from the body marker block" {
  run sync_extract_declared_paths < "$FIXTURES/1523-pr-body.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/claude.yml"* ]]
  [[ "$output" == *".github/workflows/agent-shield.yml"* ]]
  [[ "$output" == *".github/workflows/dependabot-automerge.yml"* ]]
  # Prose outside the marker block must not leak in.
  [[ "$output" != *"org standards"* ]]
  n=$(printf '%s\n' "$output" | grep -c .)
  [ "$n" -eq 3 ]
}

@test "a body with no marker yields no declared paths" {
  run sync_extract_declared_paths <<< "just a normal PR body, nothing declared"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "blank lines inside the marker block are ignored" {
  run sync_extract_declared_paths <<'BODY'
<!-- standards-sync:declared-paths
AGENTS.md

.github/CODEOWNERS
-->
BODY
  n=$(printf '%s\n' "$output" | grep -c .)
  [ "$n" -eq 2 ]
}

# ---------------------------------------------------------------------------
# is_generated_sync_pr — AC4: enforce only on generated sync PRs, not humans
# ---------------------------------------------------------------------------

@test "a PR carrying the sync label is a generated sync PR" {
  run is_generated_sync_pr "$(printf 'standards-sync\nauto-rebase:ready\n')" ""
  [ "$status" -eq 0 ]
}

@test "a PR carrying the declared-paths marker is a generated sync PR" {
  run is_generated_sync_pr "" "$(cat "$FIXTURES/1523-pr-body.md")"
  [ "$status" -eq 0 ]
}

@test "a human PR (no sync label, no marker) is NOT a generated sync PR" {
  run is_generated_sync_pr "$(printf 'bug\nenhancement\n')" "fixes a thing"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# sync_scope_violations — the core check
# ---------------------------------------------------------------------------

@test "an in-scope sync PR yields no violations" {
  declared=$(sync_extract_declared_paths < "$FIXTURES/1523-pr-body.md")
  changed=$(cat "$FIXTURES/inscope-changed.txt")
  run sync_scope_violations "$declared" "$changed"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the #1523 shape FAILS and names every offending path (AC3)" {
  declared=$(sync_extract_declared_paths < "$FIXTURES/1523-pr-body.md")
  changed=$(cat "$FIXTURES/1523-changed.txt")
  run sync_scope_violations "$declared" "$changed"
  [ -n "$output" ]
  [[ "$output" == *"package.json"* ]]
  [[ "$output" == *"prompts/aw/readme-refresh.md"* ]]
  [[ "$output" == *"evals/skills/proposer.yaml"* ]]
  [[ "$output" == *"scripts/aw-standards-sync.sh"* ]]
  # The three declared workflow stubs must NOT be reported as violations.
  [[ "$output" != *"claude.yml"* ]]
  [[ "$output" != *"agent-shield.yml"* ]]
  # Exactly the four out-of-scope paths.
  n=$(printf '%s\n' "$output" | grep -c .)
  [ "$n" -eq 4 ]
}

@test "a declared glob covers nested paths (deterministic glob match)" {
  declared=$(printf 'prompts/**\n.github/CODEOWNERS\n')
  changed=$(printf 'prompts/aw/readme-refresh.md\n.github/CODEOWNERS\n')
  run sync_scope_violations "$declared" "$changed"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a path outside a declared glob is a violation" {
  declared=$(printf 'prompts/**\n')
  changed=$(printf 'prompts/ok.md\nscripts/nope.sh\n')
  run sync_scope_violations "$declared" "$changed"
  [[ "$output" == *"scripts/nope.sh"* ]]
  [[ "$output" != *"prompts/ok.md"* ]]
  n=$(printf '%s\n' "$output" | grep -c .)
  [ "$n" -eq 1 ]
}

@test "no declared paths means every changed path is a violation" {
  # A labelled sync PR that declared nothing but changed files must not pass silently.
  run sync_scope_violations "" "$(printf 'package.json\nAGENTS.md\n')"
  n=$(printf '%s\n' "$output" | grep -c .)
  [ "$n" -eq 2 ]
}

@test "empty changed set yields no violations" {
  run sync_scope_violations "$(printf 'AGENTS.md\n')" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
