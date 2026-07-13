#!/usr/bin/env bats
# Tests for personas/validate-personas.py — the persona manifest validator.
# Exercises the cross-invariants (id==dir==canary.agent, layer paths exist,
# eval splits present) hermetically against a minimal test-double schema, so no
# network and no copy of the canonical schema (which lives in petry-projects/.github)
# is needed. The live check against the real schema is the `validate-personas`
# CI job in lint.yml.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VALIDATOR="$ROOT/personas/validate-personas.py"
  TMP="$(mktemp -d)"

  # Minimal test-double schema: enough shape for the validator to run, NOT a
  # copy of the canonical schema.
  cat >"$TMP/schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["id"],
  "properties": {
    "id": {"type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$"}
  }
}
JSON

  # Framework-agent fixture for vendor_pin invariant tests.
  mkdir -p "$TMP/frameworks/demo-fw"
  printf '# Vendored framework\n\nPin: v1.2.3\n' >"$TMP/frameworks/demo-fw/VENDOR.md"

  # Local canary-rings registry for non-draft invariant tests.
  printf '{"agents": {"demo": {}}}\n' >"$TMP/registry.json"

  # A self-contained, valid fixture persona.
  mkdir -p "$TMP/personas/demo" "$TMP/agents" "$TMP/evals/demo/dev" "$TMP/evals/demo/holdout"
  printf -- '---\nname: demo\n---\n' >"$TMP/agents/demo.md"
  printf '{"id": "d1"}\n' >"$TMP/evals/demo/dev/cases.jsonl"
  printf '{"id": "h1"}\n' >"$TMP/evals/demo/holdout/cases.jsonl"
  cat >"$TMP/personas/demo/persona.yml" <<'YAML'
id: demo
name: Demo
title: Demo Persona
summary: A fixture persona for validator tests.
status: draft
owner: petry-projects/org-leads
definition:
  layers:
    - kind: copilot-profile
      path: agents/demo.md
triggers:
  default_mode: advisory
  opt_out_label: demo:hands-off
  surfaces: []
trust:
  author_association_floor: [OWNER]
evals:
  required_before: stable
  path: evals/demo/
  min_cases: 1
canary:
  registry: petry-projects/.github/standards/canary-rings.json
  agent: demo
YAML
}

teardown() { rm -rf "$TMP"; }

@test "validate-personas accepts a well-formed manifest" {
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-personas rejects id that does not match its directory" {
  sed -i 's/^id: demo/id: other/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"directory name"* ]]
}

@test "validate-personas rejects canary.agent that does not match id" {
  sed -i 's/^  agent: demo/  agent: nope/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canary.agent"* ]]
}

@test "validate-personas rejects a missing definition layer path" {
  rm -f "$TMP/agents/demo.md"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate-personas rejects a missing eval split" {
  rm -rf "$TMP/evals/demo/holdout"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holdout"* ]]
}

@test "validate-personas rejects an id that violates kebab-case" {
  sed -i 's/^id: demo/id: Demo_ID/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
}

@test "validate-personas is a no-op when there is no personas root" {
  run python3 "$VALIDATOR" "$TMP/nonexistent" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects a framework-agent with mismatched vendor_pin" {
  cat >"$TMP/personas/demo/persona.yml" <<'YAML'
id: demo
name: Demo
title: Demo Persona
summary: A fixture persona for validator tests.
status: draft
owner: petry-projects/org-leads
definition:
  layers:
    - kind: framework-agent
      path: agents/demo.md
      framework:
        name: demo-fw
        vendor_pin: v9.9.9
        skill: demo
triggers:
  default_mode: advisory
  opt_out_label: demo:hands-off
  surfaces: []
trust:
  author_association_floor: [OWNER]
evals:
  required_before: stable
  path: evals/demo/
  min_cases: 1
canary:
  registry: petry-projects/.github/standards/canary-rings.json
  agent: demo
YAML
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"vendor_pin"* ]]
}

@test "validate-personas accepts a non-draft persona with a registry entry" {
  sed -i 's/^status: draft/status: stable/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/registry.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects a non-draft persona without a registry entry" {
  sed -i 's/^status: draft/status: stable/' "$TMP/personas/demo/persona.yml"
  printf '{"agents": {}}\n' >"$TMP/empty-registry.json"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/empty-registry.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agents.demo"* ]]
}
