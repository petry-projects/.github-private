#!/usr/bin/env bats
# Tests for scripts/evals/score-gate.sh — the role-generic SCORED promotion gate
# (#1630, epic #1627).
#
# The story replaces the count-only holdout gate (#1318: only min_cases was ever
# enforced) with a gate that scores a persona's held-out advice against a
# documented threshold and emits a machine-readable pass/fail. Following ADR-0004
# and spec-drift.sh's pure-classifier-plus-bats discipline, the gate's DECISION
# logic is pure and unit-tested here BEFORE it is relied on for promotion:
#   * sg_resolve_threshold — threshold precedence (cli > scorer.json > default)
#   * sg_extract_score     — pulls the aggregate score out of a scorer report
#   * sg_verdict           — the pass/fail predicate against the threshold
#   * main                 — end-to-end over a stub report, offline (no LLM)
#
# Run with: bats tests/test_score_gate.bats

bats_require_minimum_version 1.5.0

GATE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/evals/score-gate.sh"

setup() {
  # shellcheck source=scripts/evals/score-gate.sh
  source "$GATE"
}

# ── sg_verdict <score> <threshold> ────────────────────────────────────────────
# pass iff score >= threshold. The bar is inclusive: exactly meeting it promotes.

@test "sg_verdict: score above threshold passes (exit 0)" {
  run sg_verdict 0.85 0.7
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "sg_verdict: score exactly at threshold passes (inclusive bar)" {
  run sg_verdict 0.7 0.7
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "sg_verdict: score below threshold fails (exit 1)" {
  run sg_verdict 0.5 0.7
  [ "$status" -eq 1 ]
  [ "$output" = "fail" ]
}

@test "sg_verdict: a zero score never passes a positive threshold" {
  run sg_verdict 0 0.7
  [ "$status" -eq 1 ]
  [ "$output" = "fail" ]
}

# ── sg_resolve_threshold <cli> <scorer_json_path> ─────────────────────────────
# Precedence: an explicit CLI value wins; else scorer.json's gate_threshold; else
# the documented default (0.7).

@test "sg_resolve_threshold: CLI value wins over scorer.json" {
  local cfg="$BATS_TEST_TMPDIR/scorer.json"
  echo '{"mode":"llm-judge","gate_threshold":0.6}' >"$cfg"
  run sg_resolve_threshold "0.9" "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "0.9" ]
}

@test "sg_resolve_threshold: falls back to scorer.json gate_threshold" {
  local cfg="$BATS_TEST_TMPDIR/scorer.json"
  echo '{"mode":"llm-judge","gate_threshold":0.8}' >"$cfg"
  run sg_resolve_threshold "" "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "0.8" ]
}

@test "sg_resolve_threshold: default 0.7 when no CLI and no gate_threshold" {
  local cfg="$BATS_TEST_TMPDIR/scorer.json"
  echo '{"mode":"llm-judge"}' >"$cfg"
  run sg_resolve_threshold "" "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "0.7" ]
}

@test "sg_resolve_threshold: default 0.7 when scorer.json is absent" {
  run sg_resolve_threshold "" "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]
  [ "$output" = "0.7" ]
}

@test "sg_resolve_threshold: rejects a negative CLI threshold (would pass everything)" {
  run sg_resolve_threshold "-1" ""
  [ "$status" -eq 2 ]
}

@test "sg_resolve_threshold: rejects a CLI threshold above 1 (would fail everything)" {
  run sg_resolve_threshold "1.5" ""
  [ "$status" -eq 2 ]
}

@test "sg_resolve_threshold: rejects a non-numeric CLI threshold" {
  run sg_resolve_threshold "high" ""
  [ "$status" -eq 2 ]
}

@test "sg_resolve_threshold: an in-range CLI boundary value (0 or 1) is accepted" {
  run sg_resolve_threshold "1" ""
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run sg_resolve_threshold "0" ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "sg_resolve_threshold: an out-of-range scorer.json gate_threshold falls back to default" {
  local cfg="$BATS_TEST_TMPDIR/scorer.json"
  echo '{"mode":"llm-judge","gate_threshold":2}' >"$cfg"
  run sg_resolve_threshold "" "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "0.7" ]
}

# ── sg_extract_score <report_json> ────────────────────────────────────────────

@test "sg_extract_score: pulls a numeric score from a scorer report" {
  run sg_extract_score '{"skill":"x","score":0.857,"passed":6,"total":7}'
  [ "$status" -eq 0 ]
  [ "$output" = "0.857" ]
}

@test "sg_extract_score: rejects a report with no numeric score" {
  run sg_extract_score '{"skill":"x","passed":6,"total":7}'
  [ "$status" -ne 0 ]
}

@test "sg_extract_score: rejects non-JSON garbage" {
  run sg_extract_score 'not json at all'
  [ "$status" -ne 0 ]
}

@test "sg_extract_score: rejects a score above 1 (out of scorer range)" {
  run sg_extract_score '{"skill":"x","score":2,"passed":6,"total":3}'
  [ "$status" -ne 0 ]
}

@test "sg_extract_score: rejects a negative score" {
  run sg_extract_score '{"skill":"x","score":-0.5,"passed":0,"total":7}'
  [ "$status" -ne 0 ]
}

@test "sg_extract_score: accepts the boundary scores 0 and 1" {
  run sg_extract_score '{"skill":"x","score":1,"passed":7,"total":7}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run sg_extract_score '{"skill":"x","score":0,"passed":0,"total":7}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ── main: end-to-end over a stub report (offline, no LLM) ──────────────────────
# --report feeds a pre-computed scorer report so the gate is exercised without a
# live model — the offline discipline the whole eval harness uses in tests.

_write_report() {
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/report.json"
}

@test "main: a passing report emits verdict=pass and exits 0" {
  _write_report '{"skill":"solution-architect","score":0.857,"passed":6,"failed":1,"total":7,"cases":[]}'
  run bash "$GATE" solution-architect --threshold 0.7 --report "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' <<<"$output")" = "pass" ]
  [ "$(jq -r '.role'    <<<"$output")" = "solution-architect" ]
  [ "$(jq -r '.score'   <<<"$output")" = "0.857" ]
  [ "$(jq -r '.threshold' <<<"$output")" = "0.7" ]
}

@test "main: a sub-threshold report emits verdict=fail and exits 1" {
  _write_report '{"skill":"solution-architect","score":0.5,"passed":3,"failed":3,"total":6,"cases":[]}'
  run bash "$GATE" solution-architect --threshold 0.7 --report "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.verdict' <<<"$output")" = "fail" ]
}

@test "main: a report with no numeric score is a hard error (exit 2)" {
  _write_report '{"skill":"solution-architect","passed":0,"total":0}'
  run bash "$GATE" solution-architect --threshold 0.7 --report "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 2 ]
}

@test "main: missing role argument is a usage error (exit 2)" {
  run bash "$GATE"
  [ "$status" -eq 2 ]
}

@test "main: a negative --threshold is rejected as a hard error (exit 2)" {
  _write_report '{"skill":"solution-architect","score":0.5,"passed":3,"failed":3,"total":6,"cases":[]}'
  run bash "$GATE" solution-architect --threshold -1 --report "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 2 ]
}

@test "main: a report tagged for a different role is refused (exit 2)" {
  _write_report '{"skill":"qa-lead","score":0.9,"passed":9,"failed":1,"total":10,"cases":[]}'
  run bash "$GATE" solution-architect --threshold 0.7 --report "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 2 ]
}

@test "main: a report with a score above 1 is a hard error (exit 2)" {
  _write_report '{"skill":"solution-architect","score":2,"passed":6,"failed":0,"total":3,"cases":[]}'
  run bash "$GATE" solution-architect --threshold 0.7 --report "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 2 ]
}

# --- flag-arity usage errors (must be exit 2, never bash's own exit 1) -------
# Regression guard: these flags previously used ${2:?...}, whose expansion error
# aborts with status 1 — indistinguishable from a legitimate "gate failed"
# verdict — and, when the flag was the final argument, `shift 2` failed under
# `set -e` before any handler ran.

@test "main: --threshold as the final argument is a usage error (exit 2)" {
  run bash "$GATE" solution-architect --threshold
  [ "$status" -eq 2 ]
  [[ "$output" == *"--threshold needs a value"* ]]
}

@test "main: --report as the final argument is a usage error (exit 2)" {
  run bash "$GATE" solution-architect --report
  [ "$status" -eq 2 ]
  [[ "$output" == *"--report needs a file"* ]]
}

@test "main: --evals-dir as the final argument is a usage error (exit 2)" {
  run bash "$GATE" solution-architect --evals-dir
  [ "$status" -eq 2 ]
  [[ "$output" == *"--evals-dir needs a directory"* ]]
}

@test "main: a non-numeric --threshold is rejected as a hard error (exit 2)" {
  _write_report '{"skill":"solution-architect","score":0.5,"passed":3,"failed":3,"total":6,"cases":[]}'
  run bash "$GATE" solution-architect --threshold abc --report "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 2 ]
}
