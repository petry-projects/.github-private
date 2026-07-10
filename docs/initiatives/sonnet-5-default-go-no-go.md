# Sonnet 5 default swap — human go/no-go record

Part of epic **#1095** (Sonnet 5 model swap). This is **Phase 3 / issue #1100**: promote
the Story-3 `engine.sh` chain change through the dev-lead canary rings, measure the
realized cost + quality in production, and **record the human go/no-go** on making
`claude-sonnet-5` the default `claude-sonnet-4-6` replacement before the intro-pricing
deadline of **2026-08-31**.

This document is the recorded recommendation + decision, mirroring the #845 precedent
("Record the human go/no-go decision and fleet-wide recommendation" for the Opus 4.8
initiative). **No automation is built here.** The go/no-go and the stable/default
promotion are **human** actions (see [Guardrail](#guardrail-human-only-promotion)).

## What is — and is not — being decided

The Story-3 change (#1098) appends `claude-sonnet-5-0` as a **non-default fallback**
*after* the `sonnet-4-6` slot in the triage and deep chains
([`scripts/engine.sh`](../../scripts/engine.sh) — `CLAUDE_TRIAGE_MODEL_CHAIN`,
`CLAUDE_DEEP_MODEL_CHAIN`). It is reachable only when the layer-1 primaries
(haiku triage / opus deep) **and** the `sonnet-4-6` fallback have both exhausted their
rate-limit buckets. It is **not** the fleet default.

So there are two distinct steps, and this record separates them:

1. **Canary-promote the fallback addition** (rides the dev-lead rings). Validates that
   adding Sonnet 5 as a tail fallback introduces no candidate-introduced regression.
2. **The default swap** — moving `claude-sonnet-5` ahead of `claude-sonnet-4-6` in the
   chains so it becomes the primary Sonnet tier. This is the decision this record
   authorizes (or declines), and it is a **human** action.

## Evidence

### 1. Held-out quality — non-regression gate (Story 2)

Before Sonnet 5 replaces Sonnet 4.6 in any default slot it must **match or beat**
`claude-sonnet-4-6` on the frozen held-out eval sets. The procedure and the `>=`
non-regression bar are defined in
[`docs/evals/model-ab-regression.md`](../evals/model-ab-regression.md), driven by
[`scripts/evals/model-ab.sh`](../../scripts/evals/model-ab.sh) over the
`triage` + `deep-review` holdout sets (generator pinned per arm, judge held fixed).

A regression on **either** set is a **blocking** result (comparator exit `1`), never
silently accepted; an `infra` outcome (exit `2`) means re-run, not a result. Record the
per-set candidate/incumbent scores and the verdict here:

| Holdout set | `sonnet-4-6` (incumbent) | `sonnet-5` (candidate) | `>=` non-regression | Outcome |
|-------------|--------------------------|------------------------|---------------------|---------|
| `triage`      | *fill from model-ab run* | *fill* | *pass / regression / infra* | |
| `deep-review` | *fill*                   | *fill* | *pass / regression / infra* | |

> Attach the `model-ab.sh` evidence JSON and a clean `git status --porcelain -- evals/`
> (held-out immutability) alongside this row when the decision is signed.

### 2. Realized cost delta (Story 1)

Prices are data, priced through the single source of truth
[`scripts/lib/model-pricing.tsv`](../../scripts/lib/model-pricing.tsv) via
[`scripts/lib/model-pricing.sh`](../../scripts/lib/model-pricing.sh) (`cost_usd`). The
per-MTok rates in effect:

| Rate window | Model | input | cache-read | cache-write | output |
|-------------|-------|------:|-----------:|------------:|-------:|
| incumbent          | `claude-sonnet-4-6`            | 3.00 | 0.30 | 3.75 | 15.00 |
| **intro** (→ 2026-08-31) | `claude-sonnet-5-*` @ 2026-06-30 | **2.00** | 0.20 | 2.50 | **10.00** |
| standard (2026-09-01 →)  | `claude-sonnet-5-*` @ 2026-09-01 | 3.00 | 0.30 | 3.75 | 15.00 |

**List-priced delta under intro pricing: 33.3% lower input ($3.00 → $2.00) and 33.3%
lower output ($15.00 → $10.00)** — clears the `>=30%` target. Worked example on a
deep-tier record (10M input / 2M cache-read / 1M output): `$45.60 → $30.40`, a 33.3%
total reduction (reproduce with `cost_usd` at an intro-window date).

**After 2026-08-31 the discount lapses:** `claude-sonnet-5` reverts to `$3/$15`,
**identical** to `claude-sonnet-4-6` — a **0% cost delta**. Past the intro window the
swap is cost-neutral, so the case for switching rests entirely on quality
(the §1 non-regression evidence), not price.

**Production-realized delta.** The list-priced number above is the expected win; the
*realized* delta is measured from the fleet's existing token cost report over the
affected tier, before vs. after the candidate rides the rings. Record it here:

| Tier | Window | records | realized input cost before | after | realized reduction |
|------|--------|--------:|-----------------------------|-------|--------------------|
| deep / triage | *canary dwell window* | *fill* | *fill* | *fill* | *fill (target ≥30%)* |

> This is a production measurement: it can only be filled from real canary traffic that
> has dwelled through the rings, priced with the same `model-pricing.sh` cost report the
> fleet already produces. It is a human-owner input to the decision, not an agent output.

### 3. Canary gate status (dev-lead rings)

The Story-3 `engine.sh` change ships inside the dev-lead reusable, so promoting dev-lead
through its rings is how the change reaches production incrementally. The gate walks
`next → ring0 → ring1` under the dev-lead gate config:

- baseline window: **14 days**; spike cap: **3×**
- `next → ring0`: dwell **4h**, sample **≤15**
- `ring0 → ring1`: dwell **8h**, **waive_sample**
- `ring1 → stable`: dwell **12h**

Regression detection is **byte-identity-aware**: the benign-failure allowlist applies
**only** when the reusable blob is byte-unchanged, so a candidate-introduced regression
cannot be masked by the allowlist. Because the Story-3 change edits the reusable blob,
the allowlist is inactive for this candidate and any regression surfaces as a real gate
failure. Record the gate result per transition:

| Transition | dwell met | sample | candidate-introduced regression? | gate |
|------------|-----------|-------:|----------------------------------|------|
| `next → ring0`  | *fill* | *fill* | *none / detail* | *pass / hold* |
| `ring0 → ring1` | *fill* | waived | *none / detail* | *pass / hold* |

> `ring1 → stable` is **not** filled by the canary automatically — promotion to `stable`
> is the human action gated by this record (see [Guardrail](#guardrail-human-only-promotion)).

## Recommendation

*To be written by the initiative owner from the three evidence sections above.*

- **If** §1 shows non-regression on both holdout sets **and** §3 shows no
  candidate-introduced regression through `ring1`, **and** the decision is made while
  intro pricing is live: **GO** — the ≥30% intro cost win ships with no quality
  regression. Proceed to the default swap as a human action.
- **If** §1 shows a regression on either set, or §3 holds at any ring: **NO-GO** — do not
  swap the default; keep `sonnet-4-6` primary and Sonnet 5 as the tail fallback.

## Decision (human owner signs)

| Field | Value |
|-------|-------|
| Decision | **GO / NO-GO / DEFER** *(circle one)* |
| Decided by | *human owner* |
| Decided on | *YYYY-MM-DD* (must be **on or before 2026-08-31**) |
| Evidence cited | §1 eval verdict · §2 cost delta · §3 canary gate |
| Rationale | *one paragraph* |

## Deadline contingency (2026-08-31)

The intro-pricing deadline is real: `$2/$10` closes 2026-08-31, after which the standard
`$3/$15` applies. If the canary/eval evidence is **not conclusive by 2026-08-31**, the
recommendation must explicitly state which of the following the owner chose:

- **Proceed at standard pricing** — Sonnet 5 becomes default at `$3/$15`. There is **no
  cost win** (it is cost-identical to `sonnet-4-6`) but also **no cost penalty**; justify
  the swap purely on the quality evidence, or hold.
- **Hold** — keep `sonnet-4-6` primary; the intro discount is forfeited and the swap, if
  ever made, is a later quality-driven decision at standard pricing.

Record the contingency choice in the [Decision](#decision-human-owner-signs) block if the
deadline is reached without conclusive canary evidence.

## Guardrail: human-only promotion

- **No `initiative:auto`.** This story must not carry the auto-release label; nothing here
  promotes automatically.
- **No unattended promotion to `stable` / default.** Moving the `dev-lead/stable` channel
  tag and swapping the chain default are **human** actions, performed only via the
  human-gated release-channel move — never auto-released to dev-lead. This mirrors the
  `hands_off` intent of the epic and the release-channel-tag ruleset (see
  [AGENTS.md → Release channel tags](../../AGENTS.md) and
  [`docs/release/versioning.md`](../release/versioning.md)).
