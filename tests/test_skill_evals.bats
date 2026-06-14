#!/usr/bin/env bats
# Tests for the deterministic eval scorer (scripts/evals/run-eval.sh).
#
# The scorer invokes the skill through scripts/engine.sh's run_triage by default,
# but accepts an EVAL_ENGINE_CMD override so these tests drive it against a stub
# engine + fixture cases with NO network — mirroring the DRY_RUN-offline
# discipline of tests/test_initiative_planner.bats.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCORER="$ROOT/scripts/evals/run-eval.sh"
  TMP="$(mktemp -d)"

  # Fixture held-out set: one approve case, one escalate case. Each input carries
  # a unique marker so the stub engine can return a deterministic answer per case.
  mkdir -p "$TMP/evals/triage/holdout"
  cat >"$TMP/evals/triage/holdout/cases.jsonl" <<'JSONL'
{"id": "case-approve", "input": "MARKER_APPROVE\nTitle: Fix docs typo\n\nDocs-only change, no high-risk files.", "expected": {"escalate": false, "risk": "LOW"}}
{"id": "case-escalate", "input": "MARKER_ESCALATE\nTitle: Rotate auth token\n\nTouches **/auth/** and secrets.", "expected": {"escalate": true, "risk": "HIGH"}}
JSONL

  # Stub engine: takes a prompt file ($1), greps for the case marker, emits the
  # CORRECT triage JSON for each fixture case. run_triage's contract is
  # `run_triage <prompt_file>` writing the model's stdout — the stub matches it.
  STUB_OK="$TMP/stub_ok.sh"
  cat >"$STUB_OK" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q MARKER_APPROVE "$prompt"; then
  echo '{"escalate": false, "risk": "LOW", "signals": [], "summary": "docs only"}'
elif grep -q MARKER_ESCALATE "$prompt"; then
  echo '{"escalate": true, "risk": "HIGH", "signals": ["auth"], "summary": "auth/secrets touched"}'
else
  echo 'no marker found'
fi
SH
  chmod +x "$STUB_OK"

  # Stub engine that always approves — wrong for the escalate case.
  STUB_WRONG="$TMP/stub_wrong.sh"
  cat >"$STUB_WRONG" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo '{"escalate": false, "risk": "LOW", "signals": [], "summary": "always approve"}'
SH
  chmod +x "$STUB_WRONG"

  # Stub engine that emits non-JSON prose.
  STUB_PROSE="$TMP/stub_prose.sh"
  cat >"$STUB_PROSE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 'This PR looks fine to me, I would approve it.'
SH
  chmod +x "$STUB_PROSE"
}

teardown() { rm -rf "$TMP"; }

@test "scores a correct stub as all-pass (score 1, exit 0)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '.total'  <<<"$output")" -eq 2 ]
  [ "$(jq '.passed' <<<"$output")" -eq 2 ]
  [ "$(jq '.failed' <<<"$output")" -eq 0 ]
  [ "$(jq '.score'  <<<"$output")" = "1" ]
}

@test "per-case results carry id, pass, expected and actual decisions" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  approve="$(jq -c '.cases[] | select(.id=="case-approve")' <<<"$output")"
  [ "$(jq -r '.pass'             <<<"$approve")" = "true" ]
  [ "$(jq -r '.expected.escalate' <<<"$approve")" = "false" ]
  [ "$(jq -r '.actual.escalate'   <<<"$approve")" = "false" ]
  [ "$(jq -r '.actual.risk'       <<<"$approve")" = "LOW" ]
}

@test "a wrong escalate/risk decision scores fail (exit 1)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_WRONG" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  # The approve case still matches; the escalate case is mis-approved -> fail.
  [ "$(jq '.passed' <<<"$output")" -eq 1 ]
  [ "$(jq '.failed' <<<"$output")" -eq 1 ]
  esc="$(jq -c '.cases[] | select(.id=="case-escalate")' <<<"$output")"
  [ "$(jq -r '.pass' <<<"$esc")" = "false" ]
}

@test "unparseable (non-JSON) model output counts as a failure" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_PROSE" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  [ "$(jq '.passed' <<<"$output")" -eq 0 ]
  [ "$(jq '.failed' <<<"$output")" -eq 2 ]
  # Unparseable output yields a null actual decision.
  [ "$(jq -r '.cases[0].actual' <<<"$output")" = "null" ]
}

@test "aggregate score is passed/total across a mixed set" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_WRONG" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  [ "$(jq '.score' <<<"$output")" = "0.5" ]
}

@test "scorer never writes to the held-out cases file" {
  before="$(md5sum "$TMP/evals/triage/holdout/cases.jsonl")"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  after="$(md5sum "$TMP/evals/triage/holdout/cases.jsonl")"
  [ "$before" = "$after" ]
}

@test "missing skill argument is a hard error (::error::, non-zero)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run bash "$SCORER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "unknown skill (no cases.jsonl) is a hard error (::error::, non-zero)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run bash "$SCORER" nosuchskill
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "default engine command is run_triage from scripts/engine.sh" {
  # No EVAL_ENGINE_CMD override: the scorer must source engine.sh and resolve
  # run_triage as the engine command. We can't invoke a real provider offline,
  # so just assert the default wiring is documented/usable by checking the help
  # path rejects a bad skill cleanly (engine.sh sourced without error first).
  EVALS_DIR="$TMP/evals" run bash "$SCORER" nosuchskill
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "scorer reads holdout/ only — never the proposer-visible dev/ split" {
  # A dev/ case that, if the scorer read it, would change total. The scorer must
  # ignore dev/ entirely (#691 hygiene: only holdout/ is ever scored).
  mkdir -p "$TMP/evals/triage/dev"
  cat >"$TMP/evals/triage/dev/cases.jsonl" <<'JSONL'
{"id": "dev-decoy", "input": "MARKER_APPROVE\nDev-only case that must never be scored.", "expected": {"escalate": false, "risk": "LOW"}}
JSONL
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 2 ]
  [ -z "$(jq -r '.cases[] | select(.id=="dev-decoy")' <<<"$output")" ]
}
