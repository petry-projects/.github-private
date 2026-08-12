# PR-review concurrency, coverage & the cancelled-check surface

This note is the documented argument behind the `concurrency` block in
[`.github/workflows/pr-review.yml`](../../.github/workflows/pr-review.yml). It closes the
falsifiability gap that issue #1422 raised: the previous design *assumed* "at least one review
runs to completion at the final head SHA" but never demonstrated it, and its inline comment
asserted "no cancelled-check noise" — which the 2026-08-02 measurement (~49% of runs cancelled)
contradicted.

## The concurrency model (what actually happens)

`pr-review.yml` uses a per-PR **and per-head-SHA** concurrency group with
`cancel-in-progress: false`. GitHub's concurrency model admits **one running + one pending** run
per group. Given that model, for a single group:

- A newer same-group event **never cancels the run already executing** (`cancel-in-progress: false`).
  → the **in-flight** run is protected.
- When a run is already running and one is already pending, a third same-group event **evicts the
  older pending run**, which concludes as `cancelled`.
  → the **pending** run is *not* protected.

So `cancel-in-progress: false` moves cancellation from in-flight to pending; it does not remove it.
This is the correction to the old comment (AC #5).

## Why the group is keyed by head SHA (AC #3)

Before #1422 the group was keyed by PR only (`pr-review-pr-<PR>`). Every event for a PR — across
**every** head SHA — shared one slot, so rapid pushes plus review/CI events for *different* SHAs
contended for the same running+pending pair. The dominant cancellation path was therefore
**cross-SHA**: a run enqueued for a new push could be evicted by churn relating to an older,
now-stale SHA (and vice-versa).

Keying the group by `<PR>-<head-sha>` splits that contention per SHA:

| Trigger | Head-SHA source in the group key |
|---|---|
| `pull_request` (`synchronize`/`reopened`/`ready_for_review`) | `github.event.pull_request.head.sha` |
| `pull_request_review` | `github.event.pull_request.head.sha` |
| `check_suite` (`completed`) | `github.event.check_suite.head_sha` |
| `repository_dispatch` (mention) | `github.event.client_payload.sha` if the payload carries one |
| `workflow_dispatch` (`pr_url`) | none — **falls back** to the bare `pr-review-pr-<PR>` group |

Triggers whose payload carries **no** SHA (the deferred-refinement caveat in the original comment:
`workflow_dispatch` with only a `pr_url`, or a mention without a sha) fall back to the exact prior
per-PR group, so their behaviour is unchanged. This makes the change strictly additive: SHA-bearing
triggers gain per-SHA isolation; SHA-less triggers behave as before.

## Coverage argument — at least one completed review at the final head SHA (AC #4)

Claim: **for any push, at least one review runs to completion at that push's head SHA.**

Let `S` be the head SHA produced by a push, `N` the PR number, and
`G(S) = pr-review-pr-{repo}/pull/{N}-{S}` its concurrency group. The PR identity is derived from
the PR **number** field (not the raw event URL) so that `pull_request` (which carries an `html_url`)
and `check_suite` (which carries an API `url`) produce the **same group key** for the same PR.

1. A push emits `pull_request: synchronize`, whose group key resolves to `G(S)` (the SHA comes from
   `github.event.pull_request.head.sha`). CI completing for `S` later emits `check_suite: completed`
   with `github.event.check_suite.head_sha == S`, also resolving to `G(S)`. Every event *for `S`*
   maps to `G(S)` and **no event for a different SHA maps to `G(S)`** — that is exactly what SHA
   keying buys.
2. Within `G(S)`, `cancel-in-progress: false` guarantees the running member is never cancelled by a
   newer member. At most the *pending* member is evicted. Eviction requires a running member to
   already exist — i.e. a run for `S` is already executing. So an eviction inside `G(S)` never
   reduces the count of *executing* runs for `S` below one.
3. Therefore some run for `S` reaches execution and is not cancelled. The agent's idempotency marker
   (`<!-- pr-review-agent v1 sha=<HEAD> -->`) makes that run either post the review or confirm an
   existing review at `S` — a completion. A duplicate racing run for `S` no-ops against the same
   marker; it does not undo the completion.

The property that could previously fail — a run for the final SHA evicted by churn on an **older**
SHA sharing the PR-level slot — cannot occur once the older SHA lives in a different group `G(S')`.
That is the concrete gap the SHA key closes.

**Residual (stated honestly).** Three or more events for the *same* SHA in quick succession can still
evict a pending same-SHA run, producing a `cancelled` conclusion. That cancelled run is a redundant
duplicate of a run that is already executing for the same SHA (point 2), so it is not lost coverage —
but it is still a `cancelled` check on the PR. `gh pr checks` buckets `cancelled` as `fail`; the
automation surface our own tooling keys on does **not** (`scripts/lib/ci-status.sh`
`compute_ci_status` treats `CANCELLED` as non-blocking, issue #608 / #1421 regression fixture in
`tests/test_ci_status.bats`). Fully eliminating the same-SHA cancelled conclusion requires cutting
the trigger fan-in itself — see the #1408 interaction below.

## Interaction with #1408 (narrowing `pr-review-sweep`) (AC #6)

`pr-review-sweep.yml` (#573/#898) re-dispatches a review for a PR that went green after a
`ci-pending` / `ci-failing` skip, via two paths: a `workflow_run: completed` fast path and a cron
backstop. #1408 proposes **narrowing** that sweep.

The two mechanisms cover **different** failure modes, and this must stay true after #1408:

- **This change (SHA keying)** guarantees the *final head SHA* is reviewed once it has been seen by a
  trigger and CI has completed for it — it removes the *cross-SHA eviction* drop.
- **The sweep** covers the case where a review was **skipped on purpose** because CI was pending or
  failing at review time, and CI *later* goes green with **no new pr-review trigger** firing for that
  transition. SHA keying does nothing for that case — no run was evicted; none was ever started for
  the green state.

Therefore #1408 must **not** narrow away the sweep's `ci-pending/ci-failing → green` re-trigger,
because this change does not backstop it. What #1408 *can* safely narrow is any sweep behaviour that
merely re-fires a review the SHA-keyed concurrency now already guarantees (a redundant belt-and-braces
re-dispatch for a SHA that was already reviewed). The dependency is one-directional: land and verify
the SHA-keyed coverage guarantee here **before** #1408 removes any re-trigger path, and keep the
CI-transition re-trigger regardless. The pre-existing stall detector (`scripts/pr_stall_scan.sh`, run
from `daily-pr-review-health.yml`) remains the detect-only net for a PR that ends up green +
`REVIEW_REQUIRED` with no pending event — the instrument built *before* the timers narrow.

## Measuring it (AC #1)

The cancellation rate is now a **tracked number**, not an anecdote. `scripts/pr_review_health.sh`
(daily, no new cron) renders a deterministic "Run-outcome mix by triggering event" table — success /
cancelled / skipped / failure and a cancel-rate column, split by triggering event — alongside the
existing p50/p95 convergence-latency table. The pure aggregation lives in
`scripts/lib/pr-review-outcomes.sh` (unit-tested in `tests/pr_review_outcomes.bats`). The dated
starting observation (49 cancelled / 34 success / 17 skipped over three hours on 2026-08-02) is
recorded in [`docs/metrics-baseline.md`](../metrics-baseline.md).
