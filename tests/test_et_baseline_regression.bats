#!/usr/bin/env bats
# Frozen ET-baseline regression guard (issue #1102, epic #1101).
#
# Story 1 of the in-loop-fetch refactor freezes a PRE-CHANGE Effective-Tokens
# baseline for the deep and audit tiers so that every later ET claim (Story 6)
# is measured against an immutable before-number rather than a guess. This guard
# PINS that committed baseline fixture:
#   - it exists and is valid JSONL;
#   - it carries both the deep and the audit tier;
#   - every record's stored `et` is internally consistent with the ET formula at
#     the record's own dated rate (recomputed via the SAME token-metrics.sh /
#     model-pricing.sh tooling the cost report uses — no new metric is invented);
#   - the per-tier record count and total ET match hard-coded expected values,
#     so ANY edit to the frozen numbers fails CI and requires an explicit,
#     reviewable fixture update visible in the diff (mirrors the downstream-impact
#     golden guard and the held-out/baseline immutability discipline).
#
# The fixture is dated in a fixed past window, so its per-record multiplier is
# selected from model-pricing.tsv at the rate in effect on that date — appending
# a future price row cannot move these numbers (see model-pricing.tsv selection
# rule). That is the whole point: the goalpost cannot move.
#
# Run with: bats tests/test_et_baseline_regression.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/token-metrics.sh"
  BASELINE="$(dirname "$BATS_TEST_FILENAME")/fixtures/et-baseline/pre-change-baseline-2026-06.jsonl"
}

# ---------------------------------------------------------------------------
# The frozen fixture must exist and be well-formed (a deleted/renamed fixture
# must not silently turn the guard into a no-op).
# ---------------------------------------------------------------------------

@test "ET baseline fixture exists" {
  [ -f "$BASELINE" ]
}

@test "ET baseline fixture is valid JSONL (every line parses)" {
  [ -s "$BASELINE" ]
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | jq empty
  done < "$BASELINE"
}

@test "ET baseline carries both the deep and audit tiers" {
  local tiers
  tiers=$(jq -r '.tier' "$BASELINE" | sort -u)
  echo "$tiers" | grep -qx "deep"
  echo "$tiers" | grep -qx "audit"
}

# ---------------------------------------------------------------------------
# Internal consistency: every stored `et` equals the ET formula recomputed from
# input/cache/output at the multiplier in effect on the record's own date. Uses
# the existing calculate_et + et_multiplier_for — this is the same math the
# Token Cost Observatory applies, not a new metric.
# ---------------------------------------------------------------------------

@test "every record's et matches the ET formula at its dated rate" {
  local record model date input cache output stored expected
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    model=$(echo "$record"  | jq -r '.model')
    date=$(echo "$record"   | jq -r '.ts[0:10]')
    input=$(echo "$record"  | jq -r '.input_tokens')
    cache=$(echo "$record"  | jq -r '.cache_read_tokens')
    output=$(echo "$record" | jq -r '.output_tokens')
    stored=$(echo "$record" | jq -r '.et')

    local mult
    if declare -f et_multiplier_for >/dev/null 2>&1; then
      mult=$(et_multiplier_for "$model" "$date")
    else
      mult=$(model_multiplier_for "$model")
    fi
    expected=$(calculate_et "$input" "$cache" "$output" "$mult")

    # Compare numerically: the stored `et` is a JSON number (token-metrics.sh
    # emits `tonumber`), while calculate_et prints a fixed 2-decimal string, so a
    # raw string compare would spuriously differ on trailing zeros.
    if ! awk -v a="$stored" -v b="$expected" 'BEGIN { exit (a + 0 == b + 0) ? 0 : 1 }'; then
      echo "ET mismatch for model=$model date=$date: stored=$stored expected=$expected" >&2
      return 1
    fi
  done < "$BASELINE"
}

# ---------------------------------------------------------------------------
# Frozen aggregates. Per-tier record count and summed ET are pinned to exact
# expected values so a changed/added/removed baseline record fails CI.
# ---------------------------------------------------------------------------

@test "deep tier: frozen count and total ET" {
  local count total
  count=$(jq -r 'select(.tier == "deep") | .et' "$BASELINE" | wc -l | tr -d ' ')
  total=$(jq -s '[.[] | select(.tier == "deep") | .et] | add' "$BASELINE")
  [ "$count" -eq 3 ]
  [ "$total" = "170400" ]
}

@test "audit tier: frozen count and total ET" {
  local count total
  count=$(jq -r 'select(.tier == "audit") | .et' "$BASELINE" | wc -l | tr -d ' ')
  total=$(jq -s '[.[] | select(.tier == "audit") | .et] | add' "$BASELINE")
  [ "$count" -eq 3 ]
  [ "$total" = "378500" ]
}
