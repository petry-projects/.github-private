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
  # Root-schema-conforming so the fixture also passes --schema-tree (which, with
  # the #1651 allowlist emptied, schema-validates every skill against the root
  # schema when no per-skill case.schema.json is present).
  cat >"$TMP/example-skill/dev/cases.jsonl" <<'JSONL'
{"id": "dev-001", "input": "redacted input A", "expected": {"escalate": false, "risk": "LOW"}}
{"id": "dev-002", "input": "redacted input B", "expected": {"escalate": true, "risk": "HIGH"}}
JSONL
  cat >"$TMP/example-skill/holdout/cases.jsonl" <<'JSONL'
{"id": "ho-001", "input": "redacted input C", "expected": {"escalate": false, "risk": "LOW"}}
{"id": "ho-002", "input": "redacted input D", "expected": {"escalate": true, "risk": "HIGH"}}
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

# --- tree-wide per-case schema validation (--schema-tree, #1645/#1651) ---------
#
# `--schema-tree` validates EVERY case in every split against a schema, not just
# the split hygiene the default tree mode checks. Since #1651 the allowlist is
# empty: every skill is schema-validated, and each skill is validated against its
# OWN evals/<skill>/case.schema.json when present, else the root case.schema.json
# (per-skill schema resolution). This lets a skill whose case shape legitimately
# differs from triage's {escalate, risk} govern that shape explicitly rather than
# be skipped.

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

@test "schema-tree now enforces every skill (allowlist emptied, #1651)" {
  # triage was allowlisted pre-#1651; with the allowlist empty its cases ARE now
  # schema-validated, so a non-conforming triage case must FAIL rather than skip.
  mkdir -p "$TMP/triage/dev" "$TMP/triage/holdout"
  printf '%s\n' '{"id":"tri-ho-bad","expected":{"unexpected":"shape"}}' \
    >"$TMP/triage/holdout/cases.jsonl"
  printf '%s\n' '{"id":"tri-dev-bad","expected":{"unexpected":"shape"}}' \
    >"$TMP/triage/dev/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"triage"* ]]
}

@test "schema-tree validates a skill against its own case.schema.json when present" {
  # A skill whose cases carry a shape the ROOT schema forbids (expected.risk_tier,
  # no {escalate,risk}) must VALIDATE when it ships its own per-skill schema — the
  # previously-failing solution-architect shape (#1651 AC #1/#7).
  mkdir -p "$TMP/solution-architect/dev" "$TMP/solution-architect/holdout"
  cat >"$TMP/solution-architect/case.schema.json" <<'JSON'
{ "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object", "additionalProperties": false,
  "required": ["id", "input", "expected"],
  "properties": {
    "id": {"type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$", "minLength": 3},
    "input": {"type": "string", "minLength": 1},
    "expected": {"type": "object", "additionalProperties": false,
      "required": ["risk_tier", "escalate"],
      "properties": {"risk_tier": {"enum": ["LOW", "MEDIUM", "HIGH"]},
                     "escalate": {"type": "boolean"}}}}}
JSON
  printf '%s\n' '{"id":"sa-dev-1","input":"x","expected":{"risk_tier":"LOW","escalate":false}}' \
    >"$TMP/solution-architect/dev/cases.jsonl"
  printf '%s\n' '{"id":"sa-ho-1","input":"y","expected":{"risk_tier":"HIGH","escalate":true}}' \
    >"$TMP/solution-architect/holdout/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "schema-tree applies the per-skill schema, not the root, when one is present" {
  # A case that is VALID under the root schema ({escalate,risk}) but INVALID under
  # the skill's own schema must fail — proving per-skill resolution, not the root,
  # governs a skill that ships its own case.schema.json.
  mkdir -p "$TMP/solution-architect/dev" "$TMP/solution-architect/holdout"
  cat >"$TMP/solution-architect/case.schema.json" <<'JSON'
{ "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object", "additionalProperties": false,
  "required": ["id", "input", "expected"],
  "properties": {
    "id": {"type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$", "minLength": 3},
    "input": {"type": "string", "minLength": 1},
    "expected": {"type": "object", "additionalProperties": false,
      "required": ["risk_tier", "escalate"],
      "properties": {"risk_tier": {"enum": ["LOW", "MEDIUM", "HIGH"]},
                     "escalate": {"type": "boolean"}}}}}
JSON
  printf '%s\n' '{"id":"sa-dev-1","input":"x","expected":{"escalate":false,"risk":"LOW"}}' \
    >"$TMP/solution-architect/dev/cases.jsonl"
  printf '%s\n' '{"id":"sa-ho-1","input":"y","expected":{"risk_tier":"HIGH","escalate":true}}' \
    >"$TMP/solution-architect/holdout/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"solution-architect"* ]]
}

@test "every committed per-skill case.schema.json keeps the root envelope" {
  # The per-skill override may only diverge on the payload (expected); the case
  # ENVELOPE (id pattern/minLength, description/tags constraints, root
  # additionalProperties:false, required id) must not drift per skill (#1651).
  root="$ROOT/evals/case.schema.json"
  rid_pat="$(jq -r '.properties.id.pattern' "$root")"
  rid_min="$(jq -r '.properties.id.minLength' "$root")"
  rdesc_min="$(jq -r '.properties.description.minLength' "$root")"
  rtag_min="$(jq -r '.properties.tags.items.minLength' "$root")"
  for schema in "$ROOT"/evals/*/case.schema.json; do
    [ -f "$schema" ] || continue
    [ "$(jq -r '.additionalProperties' "$schema")" = "false" ]
    [ "$(jq -r '.properties.id.pattern' "$schema")" = "$rid_pat" ]
    [ "$(jq -r '.properties.id.minLength' "$schema")" = "$rid_min" ]
    [ "$(jq -r '.properties.description.minLength' "$schema")" = "$rdesc_min" ]
    [ "$(jq -r '.properties.tags.items.minLength' "$schema")" = "$rtag_min" ]
    [ "$(jq -r '.properties.tags.uniqueItems' "$schema")" = "true" ]
    jq -e '.required | index("id")' "$schema" >/dev/null
  done
}

@test "schema-tree fails a gated skill missing its holdout split" {
  # qa-lead is gated: a missing split must fail the schema gate, not skip
  # silently (#1645 AC #9).
  mkdir -p "$TMP/qa-lead/dev"
  printf '%s\n' '{"id":"qa-dev-ok","input":"y","expected":{"escalate":false,"risk":"LOW"}}' \
    >"$TMP/qa-lead/dev/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holdout"* ]]
}

@test "schema-tree fails a gated skill with an id in both dev and holdout" {
  # Cross-split overlap defeats the held-out guarantee and must fail the gate.
  mkdir -p "$TMP/qa-lead/dev" "$TMP/qa-lead/holdout"
  printf '%s\n' '{"id":"qa-shared","input":"y","expected":{"escalate":false,"risk":"LOW"}}' \
    >"$TMP/qa-lead/dev/cases.jsonl"
  printf '%s\n' '{"id":"qa-shared","input":"x","expected":{"escalate":true,"risk":"HIGH"}}' \
    >"$TMP/qa-lead/holdout/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"qa-shared"* ]]
  [[ "$output" == *"both"* ]]
}

@test "schema-tree fails a gated skill with a duplicate id within a split" {
  mkdir -p "$TMP/qa-lead/dev" "$TMP/qa-lead/holdout"
  printf '%s\n%s\n' \
    '{"id":"qa-dup","input":"a","expected":{"escalate":false,"risk":"LOW"}}' \
    '{"id":"qa-dup","input":"b","expected":{"escalate":true,"risk":"HIGH"}}' \
    >"$TMP/qa-lead/dev/cases.jsonl"
  printf '%s\n' '{"id":"qa-ho-ok","input":"x","expected":{"escalate":true,"risk":"HIGH"}}' \
    >"$TMP/qa-lead/holdout/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "schema-tree fails a gated skill whose split has zero cases" {
  # Both split files exist but the dev split is empty (all blank lines). The
  # schema gate must reject it rather than pass with zero cases, matching
  # validate_file's "contains no cases" behavior.
  mkdir -p "$TMP/qa-lead/dev" "$TMP/qa-lead/holdout"
  printf '\n\n' >"$TMP/qa-lead/dev/cases.jsonl"
  printf '%s\n' '{"id":"qa-ho-ok","input":"x","expected":{"escalate":true,"risk":"HIGH"}}' \
    >"$TMP/qa-lead/holdout/cases.jsonl"
  run python3 "$VALIDATOR" --schema-tree "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"qa-lead/dev"* ]]
  [[ "$output" == *"no cases"* ]]
}

@test "schema-tree validates the committed evals tree (qa-lead conforms)" {
  run python3 "$VALIDATOR" --schema-tree "$ROOT/evals"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
