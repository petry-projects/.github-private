#!/usr/bin/env bats
# Tests for scripts/evals/eval-cost-estimate.sh (#1686 AC #3).
#
# Enabling engine parity (Haiku -> Opus) for a persona eval costs materially more
# per scheduled run. This estimator prices that decision from the SAME source of
# truth as every other USD figure — scripts/lib/model-pricing.tsv via
# scripts/lib/model-pricing.sh — so the delta is never a hardcoded rate. These
# tests stay offline: no model is invoked, only the price table is read.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EST="$ROOT/scripts/evals/eval-cost-estimate.sh"
  TMP="$(mktemp -d)"

  # Fixture skill declaring the persona tier with a known held-out case count (3).
  mkdir -p "$TMP/evals/fixture-persona/holdout"
  cat >"$TMP/evals/fixture-persona/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "fixture-persona/judge.md", "engine": "persona"}
JSON
  cat >"$TMP/evals/fixture-persona/holdout/cases.jsonl" <<'JSONL'
{"id": "a", "input": "one"}
{"id": "b", "input": "two"}
{"id": "c", "input": "three"}
JSONL
}

teardown() { rm -rf "$TMP"; }

@test "prints a per-run cost estimate as valid JSON with a positive Haiku->Opus delta" {
  EVALS_DIR="$TMP/evals" run --separate-stderr bash "$EST" fixture-persona
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.skill' <<<"$output")" = "fixture-persona" ]
  [ "$(jq -r '.cases' <<<"$output")" -eq 3 ]
  [ "$(jq -r '.declared_tier' <<<"$output")" = "persona" ]
  # Parity run (Opus) must cost strictly more than the triage baseline (Haiku).
  parity="$(jq -r '.parity_run_usd' <<<"$output")"
  baseline="$(jq -r '.triage_run_usd' <<<"$output")"
  delta="$(jq -r '.delta_usd' <<<"$output")"
  awk -v p="$parity" -v b="$baseline" 'BEGIN { exit !(p > b) }'
  awk -v d="$delta" 'BEGIN { exit !(d > 0) }'
}

@test "USD figures are rendered to cents (2 decimals) per AGENTS cost-reporting" {
  EVALS_DIR="$TMP/evals" run --separate-stderr bash "$EST" fixture-persona
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.parity_run_usd' <<<"$output")" =~ ^[0-9]+\.[0-9]{2}$ ]]
  [[ "$(jq -r '.triage_run_usd' <<<"$output")" =~ ^[0-9]+\.[0-9]{2}$ ]]
  [[ "$(jq -r '.delta_usd'      <<<"$output")" =~ ^[0-9]+\.[0-9]{2}$ ]]
}

@test "rates are sourced from the price table, not hardcoded (removing the table breaks it)" {
  # With no price row resolvable, the estimator must fail loudly rather than fall
  # back to an invented rate — proving the number is table-derived (#1686 AC #3,
  # AGENTS 'prices are data, not code').
  EVALS_DIR="$TMP/evals" PRICING_TABLE="$TMP/nonexistent-pricing.tsv" \
    run --separate-stderr bash "$EST" fixture-persona
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]] || [[ "$stderr" == *"::error::"* ]]
}

@test "per-case token assumptions are overridable via env (a bigger case costs more)" {
  EVALS_DIR="$TMP/evals" run --separate-stderr bash "$EST" fixture-persona
  base="$(jq -r '.parity_run_usd' <<<"$output")"
  EVALS_DIR="$TMP/evals" EVAL_COST_OUTPUT_TOKENS=100000 \
    run --separate-stderr bash "$EST" fixture-persona
  bigger="$(jq -r '.parity_run_usd' <<<"$output")"
  awk -v a="$base" -v b="$bigger" 'BEGIN { exit !(b > a) }'
}

@test "a triage-tier skill reports a zero delta (already at baseline)" {
  mkdir -p "$TMP/evals/fixture-triage/holdout"
  cat >"$TMP/evals/fixture-triage/holdout/cases.jsonl" <<'JSONL'
{"id": "a", "input": "one"}
JSONL
  EVALS_DIR="$TMP/evals" run --separate-stderr bash "$EST" fixture-triage
  [ "$status" -eq 0 ]
  [ "$(jq -r '.declared_tier' <<<"$output")" = "triage" ]
  [ "$(jq -r '.delta_usd' <<<"$output")" = "0.00" ]
}
