#!/usr/bin/env bats
# Tests for interaction-contracts/validate-interaction-contracts.py — the hermetic
# well-formedness check for the per-role interaction contracts authored under
# docs/agentic-interaction-model.md §8 (Story 2 / #1404).
#
# This suite is HERMETIC (no network, no live schema). It exercises the parse /
# consistency invariants the validator enforces against a self-contained fixture
# contract under $TMP. The DEEP cross-check of triggers.events/timers against each
# workflow's real on: block is Story 4's validate-interaction-model (#1406), not
# this check — so these tests only cover well-formedness + workflow-path existence.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VALIDATOR="$ROOT/interaction-contracts/validate-interaction-contracts.py"
  TMP="$BATS_TEST_TMPDIR"

  # A fake workflow file so the workflows[] path-existence invariant is satisfied.
  mkdir -p "$TMP/.github/workflows"
  printf 'on:\n  issues:\n    types: [labeled]\n' >"$TMP/.github/workflows/demo.yml"

  # A self-contained, well-formed persona interaction contract.
  mkdir -p "$TMP/personas/demo"
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: persona
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events:
      - issues
      - repository_dispatch:demo-mention
    timers: []
  emits:
    - "label:demo"
    - "comment:<!-- demo marker -->"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-${{ issue }}"
  stop_markers:
    - demo:hands-off
  budget: none
YAML
}

@test "validate-interaction-contracts accepts a well-formed contract" {
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-interaction-contracts is a no-op when there are no contracts" {
  rm -rf "$TMP/personas"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -eq 0 ]
}

@test "validate-interaction-contracts rejects a missing required field (role)" {
  sed -i '/^role: demo/d' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role"* ]]
}

@test "validate-interaction-contracts rejects an unknown kind" {
  sed -i 's/^kind: persona/kind: gremlin/' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kind"* ]]
}

@test "validate-interaction-contracts rejects a workflows path that does not exist" {
  sed -i 's#- .github/workflows/demo.yml#- .github/workflows/nope.yml#' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate-interaction-contracts rejects an empty emits list" {
  # Replace the two-item emits block with an empty list.
  python3 - "$TMP/personas/demo/interaction.yml" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = re.sub(r"  emits:\n    - \"label:demo\"\n    - \"comment:<!-- demo marker -->\"\n", "  emits: []\n", t)
p.write_text(t)
PY
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"emits"* ]]
}

@test "validate-interaction-contracts rejects an unknown budget value" {
  sed -i 's/^  budget: none/  budget: infinite-money/' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"budget"* ]]
}

@test "validate-interaction-contracts rejects a self-trigger (emit dispatches an event it subscribes to)" {
  # The contract subscribes to repository_dispatch:demo-mention; emitting that
  # same dispatch would make it trigger on its own output (#860 rule 1).
  sed -i 's/    - "label:demo"/    - "dispatch:demo-mention"/' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"self-trigger"* ]]
}

@test "validate-interaction-contracts rejects a Class 2 timer with no timer_role" {
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: runtime
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events: []
    timers:
      - cron: "15 */2 * * *"
        justification: "retry stalled work"
        stop_condition: "item still open"
        event_fast_path: null
  emits:
    - "dispatch:demo-retry"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-retry"
  stop_markers: []
  budget: pr-automation-budget
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role"* ]]
}

@test "validate-interaction-contracts rejects a timer with an invalid role value" {
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: runtime
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events: []
    timers:
      - cron: "15 */2 * * *"
        role: convergence-clock
        justification: "retry stalled work"
        stop_condition: "item still open"
        event_fast_path: null
  emits:
    - "dispatch:demo-retry"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-retry"
  stop_markers: []
  budget: pr-automation-budget
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backstop"* ]]
}

@test "validate-interaction-contracts rejects a timer missing the event_fast_path key" {
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: runtime
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events: []
    timers:
      - cron: "15 */2 * * *"
        role: self-heal
        justification: "retry stalled work"
        stop_condition: "item still open"
  emits:
    - "dispatch:demo-retry"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-retry"
  stop_markers: []
  budget: pr-automation-budget
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"event_fast_path"* ]]
}

@test "validate-interaction-contracts accepts a standalone runtime contract under interaction-contracts/" {
  rm -rf "$TMP/personas"
  mkdir -p "$TMP/interaction-contracts"
  cat >"$TMP/interaction-contracts/demo-runtime.yml" <<'YAML'
schema_version: 1
role: demo-runtime
kind: runtime
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events:
      - issues
    timers:
      - cron: "2,17,32,47 * * * *"
        role: backstop
        justification: "reconciles a missed event"
        stop_condition: "item still open and not human-gated"
        event_fast_path: "workflow_run:[completed]"
  emits:
    - "commit"
  idempotency_key: "pr_number + head_sha"
  concurrency_lane: "demo-${{ pr }}"
  stop_markers:
    - needs-human-review
  budget: pr-automation-budget
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-interaction-contracts accepts a comment-marker: emit (normative docs form)" {
  sed -i 's#    - "label:demo"#    - "comment-marker:<!-- pr-budget exhausted -->"#' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-interaction-contracts rejects a bare-token emit with trailing garbage (commitfoo)" {
  sed -i 's#    - "label:demo"#    - "commitfoo"#' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"emits"* ]]
}

@test "validate-interaction-contracts rejects an emit with an empty payload (label:)" {
  sed -i 's#    - "label:demo"#    - "label:"#' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"emits"* ]]
}

@test "validate-interaction-contracts rejects a workflow path that escapes the repo root" {
  sed -i 's#- .github/workflows/demo.yml#- ../escape.yml#' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes"* ]]
}

@test "validate-interaction-contracts reports a parse error without a traceback" {
  printf 'schema_version: 1\nrole: [unterminated\n' >"$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-interaction-contracts allows a guarded self-dispatch when a matching self_trigger_guards entry exists" {
  # Subscribes to repository_dispatch:demo-mention and emits dispatch:demo-mention,
  # but declares the in-code guard that prevents the runaway loop (#860 rule 1).
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: persona
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events:
      - issues
      - repository_dispatch:demo-mention
    timers: []
  emits:
    - "dispatch:demo-mention"
    - "label:demo"
  self_trigger_guards:
    - emit: "dispatch:demo-mention"
      guard: "demo-intent.sh drops events where sender.login == BOT_USER"
      location: "scripts/demo-intent.sh:10-20"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-${{ issue }}"
  stop_markers:
    - demo:hands-off
  budget: none
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-interaction-contracts rejects a self-dispatch when the guard entry names a different emit" {
  # Guard entry exists but for a different emit — the collision is still unguarded.
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: persona
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events:
      - issues
      - repository_dispatch:demo-mention
    timers: []
  emits:
    - "dispatch:demo-mention"
    - "label:demo"
  self_trigger_guards:
    - emit: "label:demo"
      guard: "unrelated guard entry — does not cover dispatch:demo-mention"
      location: "scripts/demo-intent.sh:1-5"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-${{ issue }}"
  stop_markers:
    - demo:hands-off
  budget: none
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"self-trigger"* ]]
}

@test "validate-interaction-contracts rejects a self_trigger_guards entry missing the location field" {
  # Guard entry is malformed (missing location) — must fail validation.
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: persona
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events:
      - issues
    timers: []
  emits:
    - "label:demo"
  self_trigger_guards:
    - emit: "label:demo"
      guard: "some guard description"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-${{ issue }}"
  stop_markers:
    - demo:hands-off
  budget: none
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"location"* ]]
}

@test "validate-interaction-contracts rejects a self_trigger_guards emit not declared in interaction.emits" {
  # Guard entry references an emit name that is not in the contract's emits list.
  cat >"$TMP/personas/demo/interaction.yml" <<'YAML'
schema_version: 1
role: demo
kind: persona
workflows:
  - .github/workflows/demo.yml
interaction:
  triggers:
    events:
      - issues
    timers: []
  emits:
    - "label:demo"
  self_trigger_guards:
    - emit: "label:not-in-emits"
      guard: "some guard"
      location: "scripts/demo.sh:1-5"
  idempotency_key: "issue_number"
  concurrency_lane: "demo-${{ issue }}"
  stop_markers:
    - demo:hands-off
  budget: none
YAML
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not declared in interaction.emits"* ]]
}

@test "validate-interaction-contracts rejects an emit with a whitespace-only payload (label:   )" {
  sed -i 's#    - "label:demo"#    - "label:   "#' "$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"emits"* ]]
}
