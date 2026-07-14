#!/usr/bin/env bats
# Tests for evals/spec-drift/run-eval.sh — the frozen OFFLINE spec-drift eval
# harness (#1145, epic #1142).
#
# The harness drives the Story-2 detector's PURE classifier
# (scripts/spec-drift.sh :: classify_drift) directly against fixture cases, with
# no network, no LLM, and no live PR. These tests exercise:
#   * sd_is_false_positive — the pure false-positive predicate the 0-FP gate uses
#   * sd_run_split         — scores one cases.jsonl and fails when FP > 0
#   * main                 — end-to-end over the committed dev/holdout splits, and
#                            split isolation (scoring dev never requires holdout)
#
# Run with: bats tests/test_spec_drift_eval.bats

HARNESS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/evals/spec-drift/run-eval.sh"
EVAL_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/evals/spec-drift"

setup() {
  # shellcheck source=evals/spec-drift/run-eval.sh
  source "$HARNESS"
}

# ---------------------------------------------------------------------------
# sd_is_false_positive <actual> <expected>
# A false positive is the costly detector error: it flags DRIFT on a PR whose
# expected verdict is NOT drift (a spec-compliant change wrongly alarmed).
# ---------------------------------------------------------------------------

@test "sd_is_false_positive: DRIFT actual vs ALIGNED expected is a false positive" {
  run sd_is_false_positive "DRIFT" "ALIGNED"
  [ "$status" -eq 0 ]
}

@test "sd_is_false_positive: DRIFT actual vs INDETERMINATE expected is a false positive" {
  run sd_is_false_positive "DRIFT" "INDETERMINATE"
  [ "$status" -eq 0 ]
}

@test "sd_is_false_positive: DRIFT actual vs DRIFT expected is NOT a false positive" {
  run sd_is_false_positive "DRIFT" "DRIFT"
  [ "$status" -ne 0 ]
}

@test "sd_is_false_positive: a missed drift (INDETERMINATE vs DRIFT) is NOT a false positive" {
  run sd_is_false_positive "INDETERMINATE" "DRIFT"
  [ "$status" -ne 0 ]
}

@test "sd_is_false_positive: ALIGNED vs ALIGNED is NOT a false positive" {
  run sd_is_false_positive "ALIGNED" "ALIGNED"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# sd_run_split <cases.jsonl> — scores one split via classify_drift
# ---------------------------------------------------------------------------

_write_cases() {
  # $1 = target file; remaining args are raw JSONL lines.
  local target="$1"; shift
  : >"$target"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$target"
  done
}

@test "sd_run_split: an all-correct split reports 0 false positives and succeeds" {
  local f="$BATS_TEST_TMPDIR/ok.jsonl"
  _write_cases "$f" \
    '{"id":"a","acceptance_criteria":"1. x","diff":"d","analysis":"note\nDRIFT_VERDICT: DRIFT","expected":{"verdict":"DRIFT"}}' \
    '{"id":"b","acceptance_criteria":"1. x","diff":"d","analysis":"note\nDRIFT_VERDICT: ALIGNED","expected":{"verdict":"ALIGNED"}}' \
    '{"id":"c","acceptance_criteria":"1. x","diff":"d","analysis":"","expected":{"verdict":"INDETERMINATE"}}'
  run sd_run_split "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"false_positives=0"* ]]
  [[ "$output" == *"total=3"* ]]
  [[ "$output" == *"correct=3"* ]]
}

@test "sd_run_split: a case that flags DRIFT on an ALIGNED expectation is a false positive and fails" {
  local f="$BATS_TEST_TMPDIR/fp.jsonl"
  _write_cases "$f" \
    '{"id":"fp","acceptance_criteria":"1. x","diff":"d","analysis":"DRIFT_VERDICT: DRIFT","expected":{"verdict":"ALIGNED"}}'
  run sd_run_split "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"false_positives=1"* ]]
}

@test "sd_run_split: prose mentioning the word drift but with an ALIGNED token is NOT a false positive" {
  local f="$BATS_TEST_TMPDIR/trap.jsonl"
  _write_cases "$f" \
    '{"id":"trap","acceptance_criteria":"1. x","diff":"d","analysis":"I considered the risk of drift here but the diff satisfies every criterion.\nDRIFT_VERDICT: ALIGNED","expected":{"verdict":"ALIGNED"}}'
  run sd_run_split "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"false_positives=0"* ]]
}

# ---------------------------------------------------------------------------
# main — end-to-end over the committed splits + split isolation
# ---------------------------------------------------------------------------

@test "main: the committed holdout split scores 0 false positives (AC5)" {
  run bash "$HARNESS" holdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"false_positives=0"* ]]
}

@test "main: the committed dev split scores 0 false positives" {
  run bash "$HARNESS" dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"false_positives=0"* ]]
}

@test "main: scoring dev does not require the holdout split to exist (tuning reads dev only)" {
  # A tuning root that physically contains ONLY dev/. If the harness read holdout
  # while scoring dev, it would fail here — proving the reward-hacking isolation.
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/dev"
  _write_cases "$root/dev/cases.jsonl" \
    '{"id":"only-dev","acceptance_criteria":"1. x","diff":"d","analysis":"DRIFT_VERDICT: ALIGNED","expected":{"verdict":"ALIGNED"}}'
  run bash "$HARNESS" --root "$root" dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"false_positives=0"* ]]
}

@test "main: an unknown split argument fails loudly" {
  run bash "$HARNESS" bogus-split
  [ "$status" -ne 0 ]
}

@test "main: both committed splits validate against the documented case schema" {
  # Schema conformance is the 'documented case shape' guarantee (AC1).
  run python3 "$(dirname "$EVAL_DIR")/validate-cases.py" "$EVAL_DIR/dev/cases.jsonl" "$EVAL_DIR/case.schema.json"
  [ "$status" -eq 0 ]
  run python3 "$(dirname "$EVAL_DIR")/validate-cases.py" "$EVAL_DIR/holdout/cases.jsonl" "$EVAL_DIR/case.schema.json"
  [ "$status" -eq 0 ]
}
