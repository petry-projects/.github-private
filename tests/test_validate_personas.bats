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

# --- Addressing (§4.1): handle slug == id, and handles are unique fleet-wide ---
#
# The live team properties (exists / privacy: closed / notifications_disabled)
# are deliberately NOT covered here — they need the network, and this suite is
# hermetic. Those are the `verify-persona-teams` CI job's job.

# add_address <persona-dir> <handle> [alias...] — append an address block.
add_address() {
  local dir="$1" handle="$2"; shift 2
  {
    printf 'address:\n  handle: %s\n  aliases: [' "$handle"
    local sep="" a
    for a in "$@"; do printf '%s%s' "$sep" "$a"; sep=", "; done
    printf ']\n'
  } >>"$TMP/personas/$dir/persona.yml"
}

# clone_persona <new-id> — a second, self-contained fixture persona.
clone_persona() {
  local id="$1"
  mkdir -p "$TMP/personas/$id" "$TMP/evals/$id/dev" "$TMP/evals/$id/holdout"
  printf '{"id": "d1"}\n' >"$TMP/evals/$id/dev/cases.jsonl"
  printf '{"id": "h1"}\n' >"$TMP/evals/$id/holdout/cases.jsonl"
  sed -e "s/^id: demo/id: $id/" \
      -e "s/^  opt_out_label: demo:hands-off/  opt_out_label: $id:hands-off/" \
      -e "s|^  path: evals/demo/|  path: evals/$id/|" \
      -e "s/^  agent: demo/  agent: $id/" \
      "$TMP/personas/demo/persona.yml" >"$TMP/personas/$id/persona.yml"
}

@test "validate-personas accepts a manifest whose address handle slug matches its id" {
  add_address demo petry-projects/demo
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects an address handle whose team slug != id" {
  add_address demo petry-projects/something-else
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"!= id 'demo'"* ]]
}

@test "validate-personas rejects two personas claiming the same handle" {
  add_address demo petry-projects/demo
  clone_persona rival
  # rival's own handle is fine; its ALIAS poaches demo's handle.
  add_address rival petry-projects/rival petry-projects/demo
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already claimed"* ]]
}

@test "validate-personas treats handle collisions case-insensitively" {
  add_address demo petry-projects/demo
  clone_persona rival
  add_address rival petry-projects/rival PETRY-PROJECTS/Demo
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already claimed"* ]]
}

@test "validate-personas accepts distinct handles across personas" {
  add_address demo petry-projects/demo
  clone_persona rival
  add_address rival petry-projects/rival
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas ignores personas with no address block" {
  clone_persona rival
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}
