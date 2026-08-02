# How to add an agentic role

**Status:** runbook (repo-local) · **Scope:** `petry-projects/.github-private`
· **Companion to:** [`docs/agentic-interaction-model.md`](./agentic-interaction-model.md) (the normative standard)

This is the step-by-step for introducing a new agentic role — a workflow that reacts to
events or runs on a cadence and takes automated action. The [interaction-model
standard](./agentic-interaction-model.md) says *what* a conforming role looks like; this
runbook says *how* to declare one so it passes CI on the first try. Every step cites the
standard section that governs it — read that section for the rules, and follow this page
for the sequence.

Do not treat any step as optional: a role whose `on:` block, contract, and classification
row disagree fails CI (see [Enforcement](#enforcement) below).

---

## Step 1 — Classify the role: pick the trigger class

Decide, from the **origin of the work**, which of the three trigger classes the role is
(standard [§2](./agentic-interaction-model.md#2-the-three-trigger-classes),
[§3](./agentic-interaction-model.md#3-class-discriminator-the-parse-contract)):

- **Class 1 — event-driven reaction.** A GitHub webhook already represents the work (a PR
  opens, a review is submitted, a check run completes). Subscribe to the narrowest event(s)
  that carry the signal. **No `schedule`** — the event-first principle
  ([§1](./agentic-interaction-model.md#1-the-event-first-principle)) means a cron here is
  either a disguised Class 2 or a leak.
- **Class 2 — backstop / reconciliation timer.** The work is fundamentally event-driven,
  but the event path can *miss* (dropped webhook, race, a state that became actionable
  without a fresh event). Pair the event fast-path with a **low-frequency reconciliation
  timer** that declares a `timer_role`.
- **Class 3 — scheduled-origin work.** The cadence itself *is* the requirement (a weekly
  report, a daily health scan, a periodic canary). There is no upstream webhook that
  represents "produce this week's report."

If you are reaching for a `schedule` on Class 1 work, stop: prefer the event
([§1](./agentic-interaction-model.md#1-the-event-first-principle)). A timer is legitimate
only as a Class 2 backstop under an event path, or as a Class 3 scheduled origin.

**Then add a classification row.** Add exactly one row for the new workflow to the §4 table
in the standard
([Classification of current agentic workflows](./agentic-interaction-model.md#4-classification-of-current-agentic-workflows)),
in the fixed column order `Workflow (path) | Class | timer_role | Justification`. The
completeness check is bidirectional — a workflow with no row (and not on the exclusion list)
fails CI. If the role is CI infrastructure or a thin caller stub rather than an agentic role,
add it to the §4 **exclusion list** instead, with a one-line reason.

## Step 2 — Author the interaction contract (the Story-1 shape)

Declare the role's interaction pattern as a **machine-readable contract** in the shape fixed
by standard [§8.1](./agentic-interaction-model.md#81-fields) — do not restate the pattern in
prose scattered across workflow comments. The contract lives in one of two standalone
repo-local locations (the [§8.2](./agentic-interaction-model.md#82-file-location--decision-standalone-repo-local-contract-not-personayml-yet)
decision — option (b), so there is **no** cross-repo `persona.schema.json` dependency):

- `personas/<id>/interaction.yml` — for a role backed by a persona manifest.
- `interaction-contracts/<name>.yml` — for a non-persona runtime whose triggers live only in
  its workflow(s) (e.g. `dev-lead`, `pr-review`, `ci-failure-analyst`).

Copy the shape from an existing contract of the same kind
([`personas/dev-lead/interaction.yml`](../personas/dev-lead/interaction.yml) for the persona
lens, [`interaction-contracts/dev-lead.yml`](../interaction-contracts/dev-lead.yml) for the
runtime lens). Fill in every required field:

- `interaction.triggers.events` — mirror the workflow's `on:` webhook subscriptions verbatim.
- `interaction.triggers.timers` — empty for a pure Class 1 role; one entry per `schedule.cron`
  otherwise (see Step 4).
- `emits` — the events / markers this role produces. This is what proves the role never
  subscribes to its own output (#860 rule 1,
  [§7](./agentic-interaction-model.md#7-the-860-normative-rules)): an emit must not name an
  event class the role also subscribes to.
- `idempotency_key`, `concurrency_lane`, `stop_markers`, and `budget` — the role obeys the
  existing `pr-automation-budget` ceiling ([§9](./agentic-interaction-model.md#9-the-cost--run-count-bound));
  do **not** invent a new numeric cap.

## Step 3 — Choose the event path vs. a sanctioned bridge

A workflow step running as the default `GITHUB_TOKEN` **cannot emit webhooks that trigger
other workflows** — GitHub suppresses recursive triggering, so an event a Class 1 role is
waiting for will silently never arrive if its upstream producer runs as `GITHUB_TOKEN`
(standard [§5](./agentic-interaction-model.md#5-the-github_token-event-boundary-rule-and-sanctioned-bridges)).

- **Prefer the direct event.** If the work is represented by a real webhook that a real
  actor produces, subscribe to it directly — no bridge needed.
- If you must wake a downstream role across the `GITHUB_TOKEN` boundary, cross it **only**
  via one of the two sanctioned bridges:
  - **Bridge A — PAT-backed `repository_dispatch`** (event-preserving). Fire the dispatch (or
    apply the triggering label) with the role's declared
    `runtime.identity.credential` PAT — never a shared token borrowed to punch through the
    boundary. The downstream Class 1 role wakes on its normal event path, scoped to the
    payload.
  - **Bridge B — a stop-condition-gated backstop timer.** Where a PAT bridge is not warranted,
    a Class 2 backstop timer may reconcile the missed event on a cadence — but it must satisfy
    the full timer contract in Step 4.

Never try to cross the boundary by having `GITHUB_TOKEN` emit the triggering event and hoping
it fires — it will not, and the failure is silent.

## Step 4 — Declare the timer contract (only if the role uses a timer)

Skip this step for a pure Class 1 role. If the role has any `schedule.cron` (Class 2 or
Class 3), each timer is bound by the timer contract
([§6](./agentic-interaction-model.md#6-the-timer-contract)) and must be declared in the
contract's `interaction.triggers.timers`:

- **`role`** — one of `backstop`, `safety-net`, `self-heal`
  ([§6.1](./agentic-interaction-model.md#61-the-timer_role-taxonomy)). A **Class 3**
  report/canary carries **no** `timer_role` (its cadence is the origin); a **Class 2** timer
  **must** declare one.
- **`justification`** — why this is a timer and not an event.
- **`stop_condition`** — the timer checks it *before* acting and re-dispatches only work that
  is still open and not human-gated
  ([§6.2](./agentic-interaction-model.md#62-requirements-every-timer-must-meet)).
- **`event_fast_path`** — the Class 1 event this timer backstops; `null` marks the
  [§6.3](./agentic-interaction-model.md#63-the-correct-example-vs-the-leak) leak (a schedule
  as the *only* path to event-driven work).
- The timer must be **idempotent** (extra ticks harmless, missed ticks self-heal), must
  **skip human-gate markers** (`needs-human-review`, `dev-lead:needs-human`, …), and must
  **never re-arm a runaway** — its reset path is human-gated. Also obey the off-peak
  scheduling standard (non-zero, staggered minute; AGENTS.md "Scheduled workflows").

## Enforcement

The classification table and the per-role contracts are **CI-verified, not review-verified**:
the [`validate-interaction-model`](./agentic-interaction-model.md#10-how-this-document-is-enforced)
check (Story 4 / [#1406](https://github.com/petry-projects/.github-private/issues/1406)) fails
any PR whose `on:` block, §4 row, and contract disagree — so a non-conforming role cannot
merge. That validator is the single source of truth for the exact rules; this runbook does not
restate them.
