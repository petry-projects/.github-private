#!/usr/bin/env bats
# Tests for the held-out triage eval-case set (evals/).
# validate-cases.py performs JSON-Schema validation only (no scorer, no model
# invocation) so the whole suite runs offline.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EVALS_DIR="$ROOT/evals"
  VALIDATOR="$EVALS_DIR/validate-cases.py"
  SCHEMA="$EVALS_DIR/case.schema.json"
  CASES="$EVALS_DIR/triage/cases.jsonl"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

@test "validate-cases accepts the seed triage case set" {
  run python3 "$VALIDATOR" "$CASES"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cases OK"* ]]
}

@test "validate-cases rejects a case missing expected.risk" {
  jq -c 'del(.expected.risk)' <(head -1 "$CASES") >"$TMP/bad.jsonl"
  run python3 "$VALIDATOR" "$TMP/bad.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"risk"* ]]
}

@test "validate-cases rejects an unknown top-level property" {
  jq -c '.surprise = "x"' <(head -1 "$CASES") >"$TMP/bad.jsonl"
  run python3 "$VALIDATOR" "$TMP/bad.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"additional"* || "$output" == *"surprise"* ]]
}

@test "validate-cases rejects an invalid risk enum value" {
  jq -c '.expected.risk = "CATASTROPHIC"' <(head -1 "$CASES") >"$TMP/bad.jsonl"
  run python3 "$VALIDATOR" "$TMP/bad.jsonl"
  [ "$status" -ne 0 ]
}

@test "validate-cases rejects a non-boolean escalate" {
  jq -c '.expected.escalate = "yes"' <(head -1 "$CASES") >"$TMP/bad.jsonl"
  run python3 "$VALIDATOR" "$TMP/bad.jsonl"
  [ "$status" -ne 0 ]
}

@test "validate-cases rejects duplicate case ids" {
  head -1 "$CASES" >"$TMP/dup.jsonl"
  head -1 "$CASES" >>"$TMP/dup.jsonl"
  run python3 "$VALIDATOR" "$TMP/dup.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unique"* || "$output" == *"duplicate"* ]]
}

@test "case schema validates with the same python jsonschema pattern as plan.schema.json" {
  run python3 -c "import json,jsonschema,sys; jsonschema.Draft202012Validator.check_schema(json.load(open('$SCHEMA')))"
  [ "$status" -eq 0 ]
}

@test "seed cases cover both escalate outcomes" {
  has_true="$(jq -s 'any(.[]; .expected.escalate == true)' "$CASES")"
  has_false="$(jq -s 'any(.[]; .expected.escalate == false)' "$CASES")"
  [ "$has_true" = "true" ]
  [ "$has_false" = "true" ]
}

@test "seed cases include a case for each named high-risk trigger" {
  tags="$(jq -r 'select(.tags != null) | .tags[]' "$CASES" | sort -u)"
  grep -qx 'auth-secrets' <<<"$tags"
  grep -qx 'db-migration' <<<"$tags"
  grep -qx 'security-anti-pattern' <<<"$tags"
}

@test "every high-risk (HIGH) seed case escalates" {
  # A HIGH classification must never be paired with escalate=false: triage.md
  # treats any HIGH signal as an always-escalate condition.
  bad="$(jq -s '[.[] | select(.expected.risk == "HIGH" and .expected.escalate == false)] | length' "$CASES")"
  [ "$bad" -eq 0 ]
}

@test "validate-cases rejects a case with HIGH risk but escalate false" {
  jq -c '.expected.risk = "HIGH" | .expected.escalate = false' <(head -1 "$CASES") >"$TMP/bad.jsonl"
  run python3 "$VALIDATOR" "$TMP/bad.jsonl"
  [ "$status" -ne 0 ]
}
