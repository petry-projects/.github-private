#!/usr/bin/env bats
# Tests for evals/validate-cases.py — the held-out hygiene validator (#691, epic #581).
# Validates the dev/holdout split: well-formed JSONL, unique non-empty `id` per
# split, and no `id` shared across splits (a case must never appear in both).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VALIDATOR="$ROOT/evals/validate-cases.py"
  TMP="$(mktemp -d)"
  # A well-formed skill: disjoint dev/holdout ids.
  mkdir -p "$TMP/example-skill/dev" "$TMP/example-skill/holdout"
  cat >"$TMP/example-skill/dev/cases.jsonl" <<'JSONL'
{"id": "dev-001", "prompt": "redacted input A", "expected": "redacted output A"}
{"id": "dev-002", "prompt": "redacted input B", "expected": "redacted output B"}
JSONL
  cat >"$TMP/example-skill/holdout/cases.jsonl" <<'JSONL'
{"id": "ho-001", "prompt": "redacted input C", "expected": "redacted output C"}
{"id": "ho-002", "prompt": "redacted input D", "expected": "redacted output D"}
JSONL
}

teardown() { rm -rf "$TMP"; }

@test "validate-cases accepts a well-formed dev/holdout split" {
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-cases rejects an id appearing in both dev and holdout" {
  # Make ho-001 collide with a dev id.
  cat >"$TMP/example-skill/holdout/cases.jsonl" <<'JSONL'
{"id": "dev-001", "prompt": "leaked into holdout", "expected": "x"}
{"id": "ho-002", "prompt": "redacted input D", "expected": "redacted output D"}
JSONL
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev-001"* ]]
  [[ "$output" == *"both"* ]]
}

@test "validate-cases rejects a duplicate id within a split" {
  cat >"$TMP/example-skill/dev/cases.jsonl" <<'JSONL'
{"id": "dev-001", "prompt": "a", "expected": "a"}
{"id": "dev-001", "prompt": "dup", "expected": "dup"}
JSONL
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "validate-cases rejects malformed JSON in a case line" {
  printf '%s\n' '{"id": "dev-003", "prompt": "broken"' >>"$TMP/example-skill/dev/cases.jsonl"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
}

@test "validate-cases rejects a case missing an id" {
  printf '%s\n' '{"prompt": "no id here", "expected": "x"}' >>"$TMP/example-skill/dev/cases.jsonl"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id"* ]]
}

@test "validate-cases rejects a case with an empty id" {
  printf '%s\n' '{"id": "   ", "prompt": "blank id", "expected": "x"}' >>"$TMP/example-skill/dev/cases.jsonl"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id"* ]]
}

@test "validate-cases rejects a non-object case line" {
  printf '%s\n' '["not", "an", "object"]' >>"$TMP/example-skill/dev/cases.jsonl"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
}

@test "validate-cases skips blank lines in a cases file" {
  printf '\n\n' >>"$TMP/example-skill/dev/cases.jsonl"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -eq 0 ]
}

@test "validate-cases fails when a skill has a dev split but no holdout" {
  rm -rf "$TMP/example-skill/holdout"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holdout"* ]]
}

@test "validate-cases validates the committed evals tree" {
  # The real example skill checked into the repo must always validate.
  run python3 "$VALIDATOR" "$ROOT/evals"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
