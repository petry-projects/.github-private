#!/usr/bin/env bats
# Tests for scripts/canary_report.sh — pure canary go/no-go rendering.
# Network I/O (collect_repo_jsonl / main) is not exercised here.
# Run locally: bats tests/canary_report.bats

setup() {
  # shellcheck source=scripts/canary_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/canary_report.sh"

  DIR="$(mktemp -d)"
  FILE="$DIR/records.jsonl"

  # Neutralise the maintainer-default time windows so the fixtures below are
  # scored purely on their model split (window filtering is a main()-level concern
  # exercised via its own knobs). Each test may override these.
  export CANARY_CANDIDATE="claude-opus-5-5"
  export CANARY_INCUMBENT="claude-opus-4-8"
  export CANARY_WORKFLOW="pr-review"
  export CANARY_TIER="deep"
  export CANARY_SINCE=""
  export CANARY_UNTIL=""
  export CANARY_BASELINE_SINCE=""
  export CANARY_BASELINE_UNTIL=""
}

teardown() {
  rm -rf "$DIR"
}

# mkrec <file> <ts> <workflow> <tier> <model> <in> <cr> <cw> <out> <context> <duration_ms|"">
mkrec() {
  local file="$1" ts="$2" wf="$3" tier="$4" model="$5" inp="$6" cr="$7" cw="$8" out="$9" ctx="${10}" dur="${11}"
  local durfield="null"
  [ -n "$dur" ] && durfield="$dur"
  printf '{"ts":"%s","workflow":"%s","tier":"%s","model":"%s","input_tokens":%d,"cache_read_tokens":%d,"cache_creation_tokens":%d,"output_tokens":%d,"context":"%s","duration_ms":%s}\n' \
    "$ts" "$wf" "$tier" "$model" "$inp" "$cr" "$cw" "$out" "$ctx" "$durfield" >> "$file"
}

# Five candidate PRs (opus-5-5) that clear every bar vs five incumbent
# invocations (opus-4-8). Token usage identical per call so the deltas are the
# pure price difference; candidate durations are 30% faster.
seed_pass() {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep claude-opus-5-5 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep claude-opus-4-8 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
}

# ---------------------------------------------------------------------------
# Overall PASS
# ---------------------------------------------------------------------------

@test "render_canary_report: all three bars clear → PASS, exit 0" {
  seed_pass
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"- cache_read: PASS"* ]]
  [[ "$output" == *"- latency: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** PASS"* ]]
}

@test "render_canary_report: reports per-arm invocation and distinct-PR counts" {
  seed_pass
  run render_canary_report "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- candidate invocations: 5"* ]]
  [[ "$output" == *"- candidate distinct PRs: 5"* ]]
  [[ "$output" == *"- incumbent invocations: 5"* ]]
}

# ---------------------------------------------------------------------------
# FAIL per metric
# ---------------------------------------------------------------------------

@test "render_canary_report: candidate not 20% cheaper per invocation → cost FAIL, exit 1" {
  local i
  for i in 1 2 3 4 5; do
    # Higher candidate output makes per-invocation cost exceed the incumbent.
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep claude-opus-5-5 \
      1000 1000 0 300 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep claude-opus-4-8 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"- cost: FAIL"* ]]
  [[ "$output" == *"**Overall verdict:** FAIL"* ]]
}

@test "render_canary_report: cache-read cost not 50% lower → cache_read FAIL, exit 1" {
  local i
  for i in 1 2 3 4 5; do
    # Candidate reads a lot more cache: cache-read cost reduction falls below 50%
    # while per-invocation cost still clears its 20% bar.
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep claude-opus-5-5 \
      900 2000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep claude-opus-4-8 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"- cache_read: FAIL"* ]]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** FAIL"* ]]
}

@test "render_canary_report: candidate not 20% faster → latency FAIL, exit 1" {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep claude-opus-5-5 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 1000
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep claude-opus-4-8 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"- latency: FAIL"* ]]
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** FAIL"* ]]
}

# ---------------------------------------------------------------------------
# INSUFFICIENT
# ---------------------------------------------------------------------------

@test "render_canary_report: fewer than 5 distinct candidate PRs → INSUFFICIENT, exit 2" {
  local i
  for i in 1 2 3 4; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep claude-opus-5-5 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
  done
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep claude-opus-4-8 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- cost: INSUFFICIENT"* ]]
  [[ "$output" == *"**Overall verdict:** INSUFFICIENT"* ]]
}

@test "render_canary_report: no non-null duration on either arm → latency INSUFFICIENT (never PASS), exit 2" {
  local i
  for i in 1 2 3 4 5; do
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep claude-opus-5-5 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" ""
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep claude-opus-4-8 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" ""
  done
  run render_canary_report "$DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"- latency: INSUFFICIENT"* ]]
  # Cost/cache are computable and clear their bars, but a missing latency signal
  # must block an overall PASS.
  [[ "$output" == *"- cost: PASS"* ]]
  [[ "$output" == *"**Overall verdict:** INSUFFICIENT"* ]]
}

# ---------------------------------------------------------------------------
# Unpriced-model accounting
# ---------------------------------------------------------------------------

@test "render_canary_report: unpriced candidate records are counted and reported, never dropped" {
  local i
  for i in 1 2 3 4 5; do
    # A model with no row in model-pricing.tsv → unpriced, but still a real call.
    mkrec "$FILE" "2026-09-26T10:0${i}:00Z" pr-review deep claude-opus-5-5 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/${i}" 700
    mkrec "$FILE" "2026-09-20T10:0${i}:00Z" pr-review deep claude-opus-4-8 \
      1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/10${i}" 1000
  done
  # Add two unpriced candidate calls on new PRs (dated before opus-5-5 pricing began).
  mkrec "$FILE" "2026-09-01T10:00:00Z" pr-review deep claude-opus-5-5 \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/91" 700
  mkrec "$FILE" "2026-09-01T10:01:00Z" pr-review deep claude-opus-5-5 \
    1000 1000 0 100 "https://github.com/petry-projects/.github-private/pull/92" 700
  run render_canary_report "$DIR"
  # 7 candidate invocations total; 2 of them unpriced but still counted.
  [[ "$output" == *"- candidate invocations: 7"* ]]
  [[ "$output" == *"- candidate unpriced records: 2"* ]]
}
