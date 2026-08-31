#!/usr/bin/env bats
# Tests for scripts/lib/miss-harvest.sh — harvests accepted pr-review misses
# (issue #1596) into evals/deep-review/dev/cases.jsonl as regression cases.
#
# HARD INVARIANT under test: harvested cases go to dev/ ONLY. The harvester must
# refuse to write any holdout/ path — auto-harvesting into holdout/ would destroy
# the held-out guarantee (#1088). It must also de-identify the case before it is
# written (evals/README.md decision A3).
#
# Run locally: bats tests/test_miss_harvest.bats

setup() {
  # shellcheck source=scripts/lib/miss-harvest.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/miss-harvest.sh"
  TMP="$(mktemp -d)"
  MISS='{"repo":"petry-projects/.github","pr":"https://github.com/petry-projects/.github/pull/995","bot":"coderabbitai","finding":"ADR asserts a rolling 5-hour window while also asserting utilization is monotonic — a self-contradiction. cc @don-petry https://internal.example.com/x token ghp_ABCDEFabcdef0123456789ABCDEFabcdef01"}'
}

teardown() {
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# The dev-only invariant — the harvester CANNOT write a holdout/ path
# ---------------------------------------------------------------------------

@test "mh_assert_dev_path: rejects a holdout/ path" {
  run mh_assert_dev_path "evals/deep-review/holdout/cases.jsonl"
  [ "$status" -ne 0 ]
}

@test "mh_assert_dev_path: accepts a dev/ path" {
  run mh_assert_dev_path "evals/deep-review/dev/cases.jsonl"
  [ "$status" -eq 0 ]
}

@test "mh_harvest: refuses to write when handed a holdout/ target and writes nothing" {
  target="$TMP/holdout/cases.jsonl"
  mkdir -p "$TMP/holdout"
  run mh_harvest "$MISS" "$target"
  [ "$status" -ne 0 ]
  [ ! -f "$target" ]
}

@test "mh_harvest: appends a valid JSONL case to a dev/ target" {
  target="$TMP/dev/cases.jsonl"
  mkdir -p "$TMP/dev"
  run mh_harvest "$MISS" "$target"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  # Exactly one line, and it is valid JSON carrying a non-empty id.
  [ "$(wc -l < "$target")" -eq 1 ]
  run jq -e '.id | type == "string" and length > 0' "$target"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# De-identification (evals/README.md decision A3)
# ---------------------------------------------------------------------------

@test "mh_build_case: strips URLs, @mentions and token-like strings" {
  run mh_build_case "$MISS"
  [ "$status" -eq 0 ]
  # No raw URL, @mention, or ghp_ token survives into the committed case.
  ! grep -q "https://" <<<"$output"
  ! grep -q "@don-petry" <<<"$output"
  ! grep -q "ghp_ABCDEF" <<<"$output"
  # Still valid JSON with the expected shape.
  run jq -e '.id and .input and .expected' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "mh_build_case: id is stable for the same finding (idempotent harvest key)" {
  a="$(mh_build_case "$MISS" | jq -r '.id')"
  b="$(mh_build_case "$MISS" | jq -r '.id')"
  [ "$a" = "$b" ]
  [ -n "$a" ]
}
