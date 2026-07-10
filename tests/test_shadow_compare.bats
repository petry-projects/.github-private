#!/usr/bin/env bats
# Tests for scripts/lib/shadow-compare.sh — the pure comparison core for the
# shadow-mode dual-run canary validation (#605, prerequisite for #587).
#
# The module is side-effect-free (source-able): decision/risk ranking, verdict
# classification (MATCH / DIVERGENCE_BENIGN / REGRESSION / SKIPPED), the
# PASS/FAIL promotion signal, its aggregation across PRs, and the shadow_gate
# composition over the health-gated promotion decision are all unit-tested here.
#
# Run with: bats tests/test_shadow_compare.bats

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/shadow-compare.sh"

setup() {
  # shellcheck source=scripts/lib/shadow-compare.sh
  source "$LIB"
}

# ---------------------------------------------------------------------------
# shadow_decision_rank <decision>  (approve=0, escalate=1; others non-zero)
# ---------------------------------------------------------------------------

@test "shadow_decision_rank: approve ranks below escalate" {
  run shadow_decision_rank approve
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
  run shadow_decision_rank escalate
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "shadow_decision_rank: skip is not rankable (non-zero exit)" {
  run shadow_decision_rank skip
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# shadow_risk_rank <risk>  (LOW=0, MEDIUM=1, HIGH=2)
# ---------------------------------------------------------------------------

@test "shadow_risk_rank: LOW < MEDIUM < HIGH" {
  run shadow_risk_rank LOW;    [ "$output" -eq 0 ]
  run shadow_risk_rank MEDIUM; [ "$output" -eq 1 ]
  run shadow_risk_rank HIGH;   [ "$output" -eq 2 ]
}

@test "shadow_risk_rank: unknown risk is not rankable (non-zero exit)" {
  run shadow_risk_rank NOPE
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# shadow_classify <stable_decision> <stable_risk> <next_decision> <next_risk>
# Regression = the NEXT candidate is strictly LESS cautious than stable.
# ---------------------------------------------------------------------------

@test "shadow_classify: identical verdicts MATCH" {
  run shadow_classify escalate HIGH escalate HIGH
  [ "$status" -eq 0 ]
  [ "$output" = "MATCH" ]
}

@test "shadow_classify: next approves what stable escalated is a REGRESSION" {
  run shadow_classify escalate HIGH approve LOW
  [ "$output" = "REGRESSION" ]
}

@test "shadow_classify: next escalates what stable approved is BENIGN divergence" {
  run shadow_classify approve LOW escalate HIGH
  [ "$output" = "DIVERGENCE_BENIGN" ]
}

@test "shadow_classify: same decision but next under-rates risk is a REGRESSION" {
  run shadow_classify approve HIGH approve LOW
  [ "$output" = "REGRESSION" ]
}

@test "shadow_classify: same decision but next over-rates risk is BENIGN" {
  run shadow_classify approve LOW approve HIGH
  [ "$output" = "DIVERGENCE_BENIGN" ]
}

@test "shadow_classify: a skip on either side is SKIPPED (inconclusive)" {
  run shadow_classify approve LOW skip LOW
  [ "$output" = "SKIPPED" ]
  run shadow_classify skip LOW approve LOW
  [ "$output" = "SKIPPED" ]
}

# ---------------------------------------------------------------------------
# shadow_signal <classification>  — the required promotion signal
# ---------------------------------------------------------------------------

@test "shadow_signal: only REGRESSION fails" {
  run shadow_signal REGRESSION;        [ "$output" = "FAIL" ]
  run shadow_signal MATCH;             [ "$output" = "PASS" ]
  run shadow_signal DIVERGENCE_BENIGN; [ "$output" = "PASS" ]
  run shadow_signal SKIPPED;           [ "$output" = "PASS" ]
}

# ---------------------------------------------------------------------------
# shadow_aggregate <classification...>  — FAIL if ANY regression in the window
# ---------------------------------------------------------------------------

@test "shadow_aggregate: any regression fails the window" {
  run shadow_aggregate MATCH DIVERGENCE_BENIGN REGRESSION
  [ "$output" = "FAIL" ]
}

@test "shadow_aggregate: a clean window passes" {
  run shadow_aggregate MATCH DIVERGENCE_BENIGN SKIPPED
  [ "$output" = "PASS" ]
}

@test "shadow_aggregate: an empty window passes (no evidence of regression)" {
  run shadow_aggregate
  [ "$output" = "PASS" ]
}

# ---------------------------------------------------------------------------
# shadow_gate <graduated_state> <shadow_signal>
# The shadow result is a REQUIRED signal: a FAIL blocks an otherwise-clean
# PROMOTE (and holds any state), a PASS leaves the health-gate decision intact.
# ---------------------------------------------------------------------------

@test "shadow_gate: a regression blocks an otherwise-ready PROMOTE" {
  run shadow_gate PROMOTE FAIL
  [ "$output" = "BLOCKED" ]
}

@test "shadow_gate: a clean shadow passes PROMOTE through unchanged" {
  run shadow_gate PROMOTE PASS
  [ "$output" = "PROMOTE" ]
}

@test "shadow_gate: a regression holds a SOAKING candidate as BLOCKED" {
  run shadow_gate SOAKING FAIL
  [ "$output" = "BLOCKED" ]
}

@test "shadow_gate: a clean shadow leaves SOAKING/BLOCKED untouched" {
  run shadow_gate SOAKING PASS
  [ "$output" = "SOAKING" ]
  run shadow_gate BLOCKED PASS
  [ "$output" = "BLOCKED" ]
}

# ---------------------------------------------------------------------------
# shadow_compare_verdicts <stable_json> <next_json>  — file-driven classify
# ---------------------------------------------------------------------------

_write_verdict() {
  local path="$1" decision="$2" risk="$3"
  jq -n --arg d "$decision" --arg r "$risk" \
    '{decision: $d, risk: $r, summary: "s", findings: [], body: "b"}' > "$path"
}

@test "shadow_compare_verdicts: reads both verdict files and classifies" {
  local stable="$BATS_TEST_TMPDIR/stable.json" next="$BATS_TEST_TMPDIR/next.json"
  _write_verdict "$stable" escalate HIGH
  _write_verdict "$next" approve LOW
  run shadow_compare_verdicts "$stable" "$next"
  [ "$status" -eq 0 ]
  [ "$output" = "REGRESSION" ]
}

@test "shadow_compare_verdicts: a missing verdict file fails non-zero" {
  local stable="$BATS_TEST_TMPDIR/stable.json"
  _write_verdict "$stable" approve LOW
  run shadow_compare_verdicts "$stable" "/nonexistent/next.json"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# shadow_report <classification> <s_decision> <s_risk> <n_decision> <n_risk> [pr] [today]
# ---------------------------------------------------------------------------

@test "shadow_report: names the classification and both verdicts" {
  run shadow_report REGRESSION escalate HIGH approve LOW "https://github.com/o/r/pull/7" "2026-07-10"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGRESSION"* ]]
  [[ "$output" == *"escalate"* ]]
  [[ "$output" == *"approve"* ]]
  [[ "$output" == *"#7"* ]]
}
