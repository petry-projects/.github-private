# Shadow-mode dual-run — safe agent canary validation

Shadow-mode is a health-gate signal for the per-agent channel-tag release model
(initiative [#495](../initiatives/agentic-release-strategy.md)). It is issue
**#605**, promoted from Ideas Discussion #566 so the dependency is a real
`blocked_by` edge: it is a **prerequisite for the self-improving-skills proposer
(#587)** and a peer of health-gated promotion (#501).

## What it does

On a single PR, two agent lanes run in parallel:

- the **`stable` lane** — production duty; its output is posted to the PR;
- the **`next` (shadow) lane** — the candidate release, run **silently**: its
  output is **never posted** to the PR, only logged.

The shadow output is compared against the stable output to detect a
**quality regression** — the candidate doing demonstrably worse than the version
it would replace on the same input. The comparison yields a machine-readable
signal (`shadow_dual_run`) that the health-gated promotion gate (#501) consumes
as a **required** input before advancing a candidate ring.

This directly serves the initiative: it validates a `next` candidate against live
production behaviour before any consumer sees it (SC5), without exposing the PR to
the unvalidated candidate (only `stable` posts).

## Signal contract

The comparison is pure logic in [`scripts/lib/shadow-compare.sh`](../../scripts/lib/shadow-compare.sh);
the wrapper [`scripts/shadow-run.sh`](../../scripts/shadow-run.sh) reads the two
lanes' results and emits the signal. `sc_classify` returns one status:

| Status | Meaning | Blocks promotion? |
|---|---|---|
| `MATCH` | Both lanes succeed, outputs equal after normalization | No — strongest healthy signal |
| `DIVERGED` | Both succeed but outputs differ | **No — advisory only** |
| `REGRESSION` | Stable succeeds, shadow does not (failed / empty / errored) | **Yes** |
| `SHADOW_ONLY_OK` | Stable did not succeed but shadow did (candidate may be a fix) | No |
| `BOTH_FAILED` | Neither succeeded (environmental / PR-specific) | No — inconclusive |
| `NO_SHADOW` | No shadow run observed | No — inconclusive |

**Only `REGRESSION` blocks promotion.** `DIVERGED` is advisory because review
quality is not objectively measurable — A/B quality routing is deferred (see the
initiative analysis §5 / Option D). The gate therefore halts a candidate only when
it is *provably* worse than the version it replaces, and logs a divergence for
human review otherwise.

The emitted JSON signal (written to `SHADOW_SIGNAL_OUT`, surfaced in `GITHUB_ENV`
as `SHADOW_STATUS` / `SHADOW_BLOCK_PROMOTION`):

```json
{
  "signal": "shadow_dual_run",
  "reusable": "dev-lead",
  "channel": "next",
  "status": "REGRESSION",
  "regression": true,
  "blocks_promotion": true,
  "stable_run_id": 111,
  "shadow_run_id": 222
}
```

`shadow-run.sh` always exits 0 for a completed comparison — the shadow lane must
never disrupt the PR. A regression surfaces as a `::warning::` plus the env flags
and signal artifact, not as a failed required check.

## Wiring into promotion (#501)

`shadow_dual_run` is declared as a required gate signal in
[`release/registry.yml`](../../release/registry.yml) under
`reusables.dev-lead.gate.signals`. The Release_Manager soak-and-promote loop
(#993/#999) reads this registry; when #501's health gate evaluates a ring it must
confirm the `shadow_dual_run` signal is non-blocking before advancing (see the
staged rollout in [`runbook.md` §2c](./runbook.md#2c-staged-canary--ring-rollout)).

## Integration status — the dispatch half

This change delivers the **comparison + signal** half of shadow-mode: given the
two lanes' results, it classifies and emits the promotion signal. The remaining
**dispatch** half — running the `next` lane in parallel with `stable` on the same
PR while suppressing the shadow's PR output — requires a *silent/shadow-mode input*
on the org-canonical `dev-lead-reusable.yml` (and the `pr-review` reusable), which
AGENTS.md restricts from ad-hoc modification. That reusable input plus the workflow
that dispatches both lanes and feeds their run ids/outputs into `shadow-run.sh` is
the follow-up integration step; this issue lands the signal contract the gate
depends on, mirroring how `release/registry.yml` was landed ahead of its #501
reader.
