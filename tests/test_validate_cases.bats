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

# --- tree-wide per-case schema validation (--schema-tree, #1645 AC #6) ---------
#
# `--schema-tree` validates EVERY case in every split against case.schema.json,
# not just the split hygiene the default tree mode checks. A documented allowlist
# (SCHEMA_TREE_ALLOWLIST) exempts the skills whose cases do not yet conform,
# pending the fleet-wide reconciliation (#1651), so the gate can protect qa-lead
# now without blocking every unrelated PR. The schema resolved is always the
# validator's sibling case.schema.json regardless of the eval_root argument.

@test "schema-tree fails a non-conforming gated (qa-lead) case" {
  # qa-lead is NOT allowlisted -> its cases ARE schema-validated.
  mkdir -p "$TMP/qa-lead/dev" "$TMP/qa-lead/holdout"
  printf '%s\n' '{"id":"qa-ho-bad","input":"x","expected":{"risk_tier":"HIGH","escalate":true}}' \
    >"$TMP/qa-lead/holdout/cases.jsonl"
  printf '%s\n' '{"id":"qa-dev-ok","input":"y","expected":{"escalate":false,"risk":"LOW"}}' \
    >"$TMP/qa-lead/dev/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"qa-lead"* ]]
}

@test "schema-tree accepts conforming gated (qa-lead) cases including recommend" {
  mkdir -p "$TMP/qa-lead/dev" "$TMP/qa-lead/holdout"
  printf '%s\n' '{"id":"qa-ho-ok","input":"x","expected":{"escalate":true,"risk":"HIGH","recommend":"add negative-path tests"}}' \
    >"$TMP/qa-lead/holdout/cases.jsonl"
  printf '%s\n' '{"id":"qa-dev-ok","input":"y","expected":{"escalate":false,"risk":"LOW","recommend":"no additional tests required"}}' \
    >"$TMP/qa-lead/dev/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "schema-tree skips allowlisted skills (the rest, pending #1651)" {
  # triage is allowlisted -> a non-conforming case must NOT fail the gate yet.
  mkdir -p "$TMP/triage/dev" "$TMP/triage/holdout"
  printf '%s\n' '{"id":"tri-ho-bad","expected":{"unexpected":"shape"}}' \
    >"$TMP/triage/holdout/cases.jsonl"
  printf '%s\n' '{"id":"tri-dev-bad","expected":{"unexpected":"shape"}}' \
    >"$TMP/triage/dev/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

@test "schema-tree validates the committed evals tree (qa-lead conforms)" {
  run python3 "$VALIDATOR" --schema-tree "$ROOT/evals"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
