# Frozen pre-change ET baseline — provenance

**Issue:** #1102 (Story 1) · **Epic:** #1101 — in-loop-fetch refactor
**Artifact:** `pre-change-baseline-2026-06.jsonl` · **Status:** FROZEN / read-only

## What this is

The immutable **before-number** for the in-loop-fetch refactor. Story 6 compares
the post-change Effective-Tokens (ET) of the deep and audit review tiers against
*these* per-tier figures, so the numbers here must never move — otherwise a later
ET "win" could be manufactured by shifting the goalpost rather than by removing
the redundant deterministic fetch.

## Sample window & source

- **Named sample:** `baseline-2026-06` (the `run_id` on every record).
- **Dated window:** 2026-06-15 → 2026-06-17 (UTC), inclusive.
- **Source schema:** the per-call token JSONL emitted by
  `scripts/lib/token-metrics.sh` `emit_token_record` and aggregated by
  `scripts/token_report.sh` (Token Cost Observatory, #464). Each record carries
  the same fields the live pipeline emits — the AC-required subset is
  `input_tokens`, `cache_read_tokens`, `output_tokens`, `et`, `tier`, `model`.
- **Tiers captured:** `deep` (runs on `claude-sonnet-4-6`) and `audit` (runs on
  `claude-opus-4-7`) — the two agentic tiers whose in-loop `gh pr view` +
  `gh pr diff` re-fetch is the redundant deterministic read the refactor targets.

## Why the numbers cannot drift

`et` is priced at the model-multiplier **in effect on each record's own date**
(`model-pricing.tsv` selection rule: most-specific glob whose `effective_from <=`
the record date). Every record here is dated in a fixed past window, so appending
a *future* price row to `model-pricing.tsv` cannot retroactively change these
multipliers. The regression guard `tests/test_et_baseline_regression.bats`
recomputes each `et` with the same `calculate_et` / `et_multiplier_for` tooling
and pins the per-tier record count and summed ET, so any edit to the frozen data
fails CI and must be an explicit, reviewed fixture change visible in the diff.

## Frozen per-tier baseline (what Story 6 compares against)

| Tier  | Model               | Records | Total ET |
|-------|---------------------|---------|----------|
| deep  | claude-sonnet-4-6   | 3       | 170,400  |
| audit | claude-opus-4-7     | 3       | 378,500  |

## Immutability controls

- Owner-locked in `.github/CODEOWNERS` (`/tests/fixtures/et-baseline/`).
- Protected from silent deletion by `test-deletion-guard.yml` (anything under
  `tests/` requires the `ack-test-deletion` label to delete).
- Pinned byte-for-behavior by the regression guard above.
