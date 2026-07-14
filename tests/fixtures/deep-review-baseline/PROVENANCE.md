# Frozen deep-review bug-hunter baseline — provenance

**Issue:** #1089 (Phase 1) · **Epic:** #1088 — PR-review world-class bug hunter
**Artifact:** `frozen-baseline-2026-07.json` · **Status:** FROZEN / read-only

## What this is

The immutable **before-numbers** for the bug-hunter initiative. Every downstream
enhancement (#1090 semantic symbol context, #1091 issue-type specialist routing,
#1092 agentic validation, #1093 merged-PR few-shot) must prove **no regression**
against these figures, and the Phase-4 convergence gate (#1094) consumes them as
the fixed reference before any `LIVE_MODE` flip. The numbers here must never move
by prompt-tuning — otherwise a later "win" could be manufactured by shifting the
goalpost rather than by actually finding more bugs at bounded cost.

The baseline captures the three signals named in the epic's success metric and
cost cap:

| Metric | Value | Status |
|--------|-------|--------|
| Median escalated-review (deep-tier) ET | **343,068.25** | **frozen (real telemetry)** |
| Deep-review held-out eval aggregate score (llm-judge, threshold 0.7) | `null` | pending — credentialed capture |
| False-positive rate (`finding_verification` records) | `null` | unavailable — emitter not implemented |

## 1. Median escalated-review ET — frozen, real, not synthesized

- **What it is.** The median per-call Effective Tokens (ET) of the **deep** review
  tier — the tier `triage` escalates into, i.e. the "escalated review" the epic's
  cost cap governs (*"median ET per escalated review must stay ≤ 1.5× the Phase-1
  frozen baseline"*). Median (not mean) so a single pathological review cannot
  skew the goalpost.
- **Source.** Computed directly from the 10 genuine `deep`-tier records already
  committed and frozen in
  [`tests/fixtures/et-baseline/pre-change-baseline-2026-07.jsonl`](../et-baseline/pre-change-baseline-2026-07.jsonl)
  (issue #1102). Those records were extracted verbatim from the live `pr-review`
  pipeline's `token-usage-<run_id>` CI artifacts — the same per-call JSONL
  `scripts/token_report.sh` prices. This artifact does **not** duplicate that
  data; it references it and freezes the derived median, so the two artifacts
  cannot silently diverge (the regression guard recomputes the median from the
  source and fails on any mismatch).
- **Dated window:** 2026-07-03 → 2026-07-10 (UTC), inclusive.
- **Source run IDs (deep tier, `pr-review`):** `28680743571`, `28680719157`,
  `28684575826`, `28690647414`, `28708785471`, `28712486134`, `28945288331`,
  `28945290473`, `29004496155`, `29060937544`.
- **Reproduce:**
  ```bash
  jq -s 'map(select(.tier=="deep").et) | sort as $s | ($s|length) as $n
    | if $n%2==1 then $s[($n/2|floor)] else (($s[$n/2-1]+$s[$n/2])/2) end' \
    tests/fixtures/et-baseline/pre-change-baseline-2026-07.jsonl
  # => 343068.25
  ```
- **Cost cap derived from it:** 1.5× → **514,602.375** ET is the ceiling a
  downstream story's median escalated-review ET must stay under.

## 2. Deep-review held-out eval score — pending credentialed capture

`scripts/evals/run-eval.sh deep-review` scores the five held-out cases in
`evals/deep-review/holdout/cases.jsonl` with the CODEOWNER-gated llm-judge
(`evals/judge.md`, `pass_threshold` 0.7). It makes **live model calls** through
the engine (`run_triage`), so it cannot be scored in an un-credentialed context:
the dev-lead sandbox reports *"Not logged in"*, so every case is an infra failure
and `run-eval.sh` exits 2 (un-scored, by design — a throttle must not open a false
held-out regression, #920).

The value is therefore left `null` with `status: pending-credentialed-capture` and
the exact reproduce command. It must be frozen by a **credentialed CI run through
an explicit CODEOWNER-reviewed PR** — the automated skill-proposer identity must
never freeze the goalpost it is later graded against (`holdout-guard.yml`, #692).
Until it is frozen, the Phase-4 gate (#1094) captures a same-run baseline at gate
time and compares the candidate against it, which is strictly sound (same engine,
same judge, same window).

## 3. False-positive rate — unavailable (emitter not implemented)

The epic's success metric measures FP-rate from `kind:"finding_verification"`
records (`severity_before`/`severity_after`/`outcome`) said to be emitted by
`emit_verification_record()` in `scripts/lib/token-metrics.sh`. **That emitter
does not exist.** `finding_verification` is a *documented schema only* — it is
referenced by `tests/token_report.bats` (story #843, which pins that
`token_report.sh` **excludes** such records from cost) but no production code
emits it, and no such records exist in the telemetry window.

A real FP-rate baseline consequently **cannot be captured yet**: with zero
`finding_verification` records the rate is undefined. Standing up the emitter is
itself a prioritized gap — see the audit
([`docs/initiatives/pr-review-bughunter-audit.md`](../../../docs/initiatives/pr-review-bughunter-audit.md)),
where it maps to **#1092** (agentic validation, which produces the
severity-downgrade/refute outcomes the FP-rate is computed from). The story that
first emits these records freezes this number via a CODEOWNER-reviewed PR.

## Why the numbers cannot drift

- The frozen ET median is priced at the model-multiplier **in effect on each
  record's own date** (`model-pricing.tsv` selection rule), and every source
  record is dated in a fixed past window — appending a future price row cannot
  retroactively move it.
- [`tests/test_deep_review_baseline.bats`](../../test_deep_review_baseline.bats)
  pins the exact median, the record count, and recomputes the median from the
  referenced source JSONL, and asserts the two pending metrics keep their honest
  `null` status — so any edit (including a silent flip of a pending metric to an
  unreviewed number) fails CI and must be an explicit, reviewable fixture change.

## Immutability controls

- Owner-locked in `.github/CODEOWNERS` (`/tests/fixtures/deep-review-baseline/`).
- Protected from silent deletion by `test-deletion-guard.yml` (anything under
  `tests/` requires the `ack-test-deletion` label to delete).
- Pinned by the regression guard above (registered in `lint.yml`).
