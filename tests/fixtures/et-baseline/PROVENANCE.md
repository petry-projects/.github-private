# Frozen pre-change ET baseline — provenance

**Issue:** #1102 (Story 1) · **Epic:** #1101 — in-loop-fetch refactor
**Artifact:** `pre-change-baseline-2026-07.jsonl` · **Status:** FROZEN / read-only

## What this is

The immutable **before-number** for the in-loop-fetch refactor. Story 6 compares
the post-change Effective-Tokens (ET) of the deep and audit review tiers against
*these* per-tier figures, so the numbers here must never move — otherwise a later
ET "win" could be manufactured by shifting the goalpost rather than by removing
the redundant deterministic fetch.

## Sample window & source

- **Dated window:** 2026-07-03 → 2026-07-10 (UTC), inclusive — the earliest
  non-expired production telemetry available at capture time (the Token Cost
  Observatory uploads `token-usage-<run_id>.jsonl` artifacts under the repo's
  default retention, so the pre-refactor window is bounded by that retention).
- **Real, not synthesized.** Every record was extracted verbatim from the
  `token-usage-<run_id>` CI artifacts uploaded by the live `pr-review` pipeline
  (`.github/workflows/pr-review.yml` → `emit_token_record`). The `run_id`,
  `ts`, token counts, `cache_creation_tokens`, and `context` (the actual PR
  URL reviewed) are the exact values the pipeline emitted — nothing is
  hand-authored.
- **Source run IDs (deep + audit tiers, `pr-review` workflow):**
  `28680719157`, `28680743571`, `28684575826`, `28690647414`, `28708785471`,
  `28712486134`, `28945288331`, `28945290473`, `29004496155`, `29060937544`.
- **Source schema:** the per-call token JSONL emitted by
  `scripts/lib/token-metrics.sh` `emit_token_record` and aggregated by
  `scripts/token_report.sh` (Token Cost Observatory, #464). Records carry the
  full emitted field set — `ts`, `workflow`, `tier`, `engine`, `model`,
  `input_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `output_tokens`,
  `et`, `run_id`, `context`.
- **Tiers captured:** `deep` (runs on `claude-opus-4-8`) and `audit` (runs on
  `claude-fable-5`) — the two agentic pr-review tiers whose in-loop `gh pr view`
  + `gh pr diff` re-fetch is the redundant deterministic read the refactor
  targets. Every retained record is a genuine pre-change run (the prefetch
  refactor, Stories 2+, had not landed on any of these dates).

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

| Tier  | Model             | Records | Total ET    |
|-------|-------------------|---------|-------------|
| deep  | claude-opus-4-8   | 10      | 3,642,411.5 |
| audit | claude-fable-5    | 2       | 1,716,043   |

## Immutability controls

- Owner-locked in `.github/CODEOWNERS` (`/tests/fixtures/et-baseline/`).
- Protected from silent deletion by `test-deletion-guard.yml` (anything under
  `tests/` requires the `ack-test-deletion` label to delete).
- Pinned by the regression guard above.
