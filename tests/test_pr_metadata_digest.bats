#!/usr/bin/env bats
# Unit tests for scripts/lib/pr-metadata-digest.sh (issue #1551).
#
# The metadata digest is the second half of the reviewed-state fingerprint for
# metadata-only fix-requests: head SHA + digest(body, closingIssuesReferences,
# labels). These tests lock in that the digest is STABLE across cosmetic input
# variation but SENSITIVE to every one of the three metadata surfaces named in
# AC2, and that marker_meta_digest round-trips the value the writer stamps.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/pr-metadata-digest.sh"
}

@test "digest is deterministic for identical snapshots" {
  local snap='{"body":"Closes #1493","closingIssuesReferences":[{"number":1493}],"labels":[{"name":"enhancement"}]}'
  run compute_pr_metadata_digest "$snap"
  [ "$status" -eq 0 ]
  local first="$output"
  run compute_pr_metadata_digest "$snap"
  [ "$output" = "$first" ]
  # 16 lowercase hex chars.
  [[ "$first" =~ ^[a-f0-9]{16}$ ]]
}

@test "digest changes when the PR body changes" {
  local a='{"body":"Closes #1493","closingIssuesReferences":[],"labels":[]}'
  local b='{"body":"Refs #1493","closingIssuesReferences":[],"labels":[]}'
  run compute_pr_metadata_digest "$a"; local da="$output"
  run compute_pr_metadata_digest "$b"; local db="$output"
  [ "$da" != "$db" ]
}

@test "digest changes when a closing-issue reference is removed (the #1531 fix)" {
  local before='{"body":"x","closingIssuesReferences":[{"number":1493}],"labels":[]}'
  local after='{"body":"x","closingIssuesReferences":[],"labels":[]}'
  run compute_pr_metadata_digest "$before"; local db="$output"
  run compute_pr_metadata_digest "$after"; local da="$output"
  [ "$db" != "$da" ]
}

@test "digest changes when labels change" {
  local a='{"body":"x","closingIssuesReferences":[],"labels":[{"name":"bug"}]}'
  local b='{"body":"x","closingIssuesReferences":[],"labels":[{"name":"bug"},{"name":"wip"}]}'
  run compute_pr_metadata_digest "$a"; local da="$output"
  run compute_pr_metadata_digest "$b"; local db="$output"
  [ "$da" != "$db" ]
}

@test "digest is insensitive to label/closing-ref ordering" {
  local a='{"body":"x","closingIssuesReferences":[{"number":1},{"number":2}],"labels":[{"name":"a"},{"name":"b"}]}'
  local b='{"body":"x","closingIssuesReferences":[{"number":2},{"number":1}],"labels":[{"name":"b"},{"name":"a"}]}'
  run compute_pr_metadata_digest "$a"; local da="$output"
  run compute_pr_metadata_digest "$b"; local db="$output"
  [ "$da" = "$db" ]
}

@test "digest ignores fields outside the metadata surface" {
  local a='{"body":"x","closingIssuesReferences":[],"labels":[],"headRefOid":"aaaa","reviews":[{"body":"noise"}]}'
  local b='{"body":"x","closingIssuesReferences":[],"labels":[],"headRefOid":"bbbb","reviews":[]}'
  run compute_pr_metadata_digest "$a"; local da="$output"
  run compute_pr_metadata_digest "$b"; local db="$output"
  [ "$da" = "$db" ]
}

@test "digest degrades to a value (not an error) on missing fields" {
  run compute_pr_metadata_digest '{}'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[a-f0-9]{16}$ ]]
}

@test "marker_meta_digest extracts meta= from a fix-request marker" {
  local body='<!-- pr-review-agent v1 sha=abc123 --> <!-- decision=fix-requested risk=LOW meta=deadbeefdeadbeef -->'
  run marker_meta_digest "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "deadbeefdeadbeef" ]
}

@test "marker_meta_digest is empty when no meta= is present (approval / code-change marker)" {
  run marker_meta_digest '<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
