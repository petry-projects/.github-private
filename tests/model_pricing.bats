#!/usr/bin/env bats
# Tests for scripts/lib/model-pricing.sh — effective-dated price lookup, cost, ET.
# Run locally: bats tests/model_pricing.bats

setup() {
  # shellcheck source=scripts/lib/model-pricing.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/model-pricing.sh"
}

# ---------------------------------------------------------------------------
# price_for — against the production table
# ---------------------------------------------------------------------------

@test "price_for: opus 4.7 at a 2026 date → \$5 / \$0.50 / \$25" {
  run price_for "claude-opus-4-7" "2026-06-07"
  [ "$output" = "5.00 0.50 25.00" ]
}

@test "price_for: sonnet 4.6 → \$3 / \$0.30 / \$15" {
  run price_for "claude-sonnet-4-6" "2026-06-07"
  [ "$output" = "3.00 0.30 15.00" ]
}

@test "price_for: more-specific glob wins (opus-4-1 legacy = \$15, not \$5)" {
  run price_for "claude-opus-4-1-20250805" "2026-06-07"
  [ "$output" = "15.00 1.50 75.00" ]
}

@test "price_for: unknown model → empty" {
  run price_for "mystery-model-v9" "2026-06-07"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Effective-date selection (dedicated fixture table with two dated rows)
# ---------------------------------------------------------------------------

@test "price_for: selects the rate in effect on the record's date" {
  PRICING_TABLE="$(mktemp)"
  {
    printf '# glob\teff\tin\tcr\tout\n'
    printf 'test-model*\t2025-01-01\t10.00\t1.00\t40.00\n'
    printf 'test-model*\t2026-03-01\t8.00\t0.80\t32.00\n'
  } > "$PRICING_TABLE"
  before="$(price_for "test-model-x" "2026-02-15")"   # before the price drop
  after="$(price_for  "test-model-x" "2026-03-02")"   # after the price drop
  rm -f "$PRICING_TABLE"
  [ "$before" = "10.00 1.00 40.00" ]
  [ "$after"  = "8.00 0.80 32.00" ]
}

@test "price_for: date before the earliest effective_from → empty (no retroactive guess)" {
  PRICING_TABLE="$(mktemp)"
  printf 'test-model*\t2026-03-01\t8.00\t0.80\t32.00\n' > "$PRICING_TABLE"
  run price_for "test-model-x" "2025-01-01"
  rm -f "$PRICING_TABLE"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# cost_usd
# ---------------------------------------------------------------------------

@test "cost_usd: opus 21952/0/14665 ≈ \$0.476385" {
  run cost_usd "claude-opus-4-7" 21952 0 14665 "2026-06-07"
  [ "$output" = "0.476385" ]
}

@test "cost_usd: unknown model → empty (never silently \$0)" {
  run cost_usd "mystery-model-v9" 1000 0 500 "2026-06-07"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# et_multiplier_for — derived from the same table (fixes stale opus=15)
# ---------------------------------------------------------------------------

@test "et_multiplier_for: haiku baseline = 1.0" {
  run et_multiplier_for "claude-haiku-4-5-20251001" "2026-06-07"
  [ "$output" = "1.0" ]
}

@test "et_multiplier_for: sonnet = 3.0" {
  run et_multiplier_for "claude-sonnet-4-6" "2026-06-07"
  [ "$output" = "3.0" ]
}

@test "et_multiplier_for: opus 4.7 = 5.0 (was hardcoded 15)" {
  run et_multiplier_for "claude-opus-4-7" "2026-06-07"
  [ "$output" = "5.0" ]
}

@test "et_multiplier_for: unknown model → safe default 1.0" {
  run et_multiplier_for "mystery-model-v9" "2026-06-07"
  [ "$output" = "1.0" ]
}
