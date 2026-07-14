#!/usr/bin/env bats
# Frozen deep-review baseline regression guard (issue #1089, epic #1088).
#
# Phase 1 of the "world-class bug hunter" initiative freezes an IMMUTABLE
# quality/cost baseline so every downstream enhancement (#1090–#1093) can prove
# "no regression" against a fixed reference and the Phase-4 gate (#1094) has a
# stable before-number. This guard PINS the committed baseline artifact:
#   - it exists and is valid JSON;
#   - the frozen median escalated-review (deep-tier) ET matches an exact value,
#     recomputed from the SAME real telemetry the Token Cost Observatory prices
#     (tests/fixtures/et-baseline/pre-change-baseline-2026-07.jsonl) so the stored
#     number can never silently drift from its source records;
#   - the two metrics that cannot be captured in an un-credentialed / pre-emitter
#     context (the llm-judge holdout eval score, and the finding_verification
#     false-positive rate) keep their documented pending/unavailable status, so a
#     silent flip to an unreviewed number fails CI.
#
# Mirrors tests/test_et_baseline_regression.bats: any edit to the frozen numbers
# fails CI and must be an explicit, reviewable fixture change visible in the diff.
# That is the whole point — the goalpost cannot move without a CODEOWNER review.
#
# Run with: bats tests/test_deep_review_baseline.bats

setup() {
  FIXDIR="$(dirname "$BATS_TEST_FILENAME")/fixtures/deep-review-baseline"
  BASELINE="$FIXDIR/frozen-baseline-2026-07.json"
  ET_SOURCE="$(dirname "$BATS_TEST_FILENAME")/fixtures/et-baseline/pre-change-baseline-2026-07.jsonl"
}

# ---------------------------------------------------------------------------
# The frozen artifact and its provenance must exist and be well-formed (a
# deleted/renamed artifact must not silently turn the guard into a no-op).
# ---------------------------------------------------------------------------

@test "deep-review baseline artifact exists" {
  [ -f "$BASELINE" ]
}

@test "deep-review baseline provenance exists" {
  [ -f "$FIXDIR/PROVENANCE.md" ]
}

@test "deep-review baseline is valid JSON" {
  [ -s "$BASELINE" ]
  jq empty "$BASELINE"
}

@test "baseline is marked FROZEN and bound to issue #1089 / epic #1088" {
  [ "$(jq -r '.status' "$BASELINE")" = "FROZEN" ]
  [ "$(jq -r '.issue' "$BASELINE")" = "1089" ]
  [ "$(jq -r '.epic' "$BASELINE")" = "1088" ]
}

# ---------------------------------------------------------------------------
# Frozen cost baseline: the median escalated-review (deep-tier) ET is pinned to
# an exact value AND recomputed from the referenced real telemetry, so the stored
# figure can never diverge from its source records.
# ---------------------------------------------------------------------------

@test "median escalated-review ET is frozen to the exact pinned value" {
  local v
  v="$(jq -r '.metrics?.median_escalated_review_et?.value' "$BASELINE")"
  [ "$v" = "343068.25" ]
  [ "$(jq -r '.metrics?.median_escalated_review_et?.status' "$BASELINE")" = "frozen" ]
  [ "$(jq -r '.metrics?.median_escalated_review_et?.record_count' "$BASELINE")" = "10" ]
}

@test "stored median recomputes from the referenced et-baseline telemetry" {
  [ -f "$ET_SOURCE" ]
  local recomputed stored count
  recomputed="$(jq -s 'map(select(.tier=="deep").et) | sort as $s | ($s|length) as $n
      | if $n % 2 == 1 then $s[($n/2|floor)] else (($s[$n/2-1] + $s[$n/2]) / 2) end' "$ET_SOURCE")"
  stored="$(jq -r '.metrics?.median_escalated_review_et?.value' "$BASELINE")"
  # Numeric compare (avoid trailing-zero string mismatches).
  awk -v a="$recomputed" -v b="$stored" 'BEGIN { exit (a + 0 == b + 0) ? 0 : 1 }'
  # The pinned record_count must match the real source too.
  count="$(jq -s 'map(select(.tier=="deep")) | length' "$ET_SOURCE")"
  [ "$count" = "$(jq -r '.metrics?.median_escalated_review_et?.record_count' "$BASELINE")" ]
}

# ---------------------------------------------------------------------------
# The two not-yet-capturable metrics must keep their documented, honest status
# (no fabricated number). A silent flip to a real value fails CI so that the
# first genuine capture goes through an explicit CODEOWNER-reviewed diff.
# ---------------------------------------------------------------------------

@test "deep-review holdout eval score stays pending (needs credentialed capture)" {
  [ "$(jq -r '.metrics?.deep_review_holdout_eval_score?.value' "$BASELINE")" = "null" ]
  [ "$(jq -r '.metrics?.deep_review_holdout_eval_score?.status' "$BASELINE")" = "pending-credentialed-capture" ]
  # The reproducible capture command must be recorded so the number is fillable.
  [ "$(jq -r '.metrics?.deep_review_holdout_eval_score?.reproduce' "$BASELINE")" != "null" ]
}

@test "finding_verification FP-rate stays unavailable (emitter not implemented)" {
  [ "$(jq -r '.metrics?.finding_verification_fp_rate?.value' "$BASELINE")" = "null" ]
  [ "$(jq -r '.metrics?.finding_verification_fp_rate?.status' "$BASELINE")" = "unavailable-no-emitter" ]
}
