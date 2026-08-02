# Agentic interaction model

**Status:** normative (repo-local standard) · **Scope:** `petry-projects/.github-private`
· **Anchors:** the per-role interaction contracts (Story 2 / #1404), the CI validator
`validate-interaction-model` (Story 4 / #1406), the documentation wiring (Story 7).

This document codifies **how agentic roles are triggered and how they interact** so the
pattern is explicit, reviewable, and enforceable rather than tribal knowledge. It is the
normative source later phases reference — a contract, a validator, or a leak fix cites a
rule here rather than re-deriving it.

It is written **repo-local first** but shaped for promotion into an org-wide
`standards/agent-standards.md` in [`petry-projects/.github`](https://github.com/petry-projects/.github):
the principles and rules are org-general; only the classification table (§4) is
repo-specific inventory. When promoting, lift §§1–3 and §§6–10 verbatim and regenerate §4
per consuming repo. This mirrors the promotion pattern already used for the off-peak
scheduling standard (AGENTS.md → `standards/ci-standards.md`, epic #722).

---

## 1. The event-first principle

**An agentic role reacts to the event that represents the work; it does not poll for work
on a clock when an event already carries the signal.**

GitHub is an event system: a PR opens, a review is submitted, a check run completes, an
issue is labeled. Each is a webhook that can wake exactly the role that should act, at the
moment there is something to act on, scoped to the thing that changed. A timer, by
contrast, wakes on a fixed cadence whether or not there is work, re-derives "what changed"
by scanning, and adds latency equal to its period.

Therefore:

- **Prefer the event.** If a webhook exists that represents the work, subscribe to it. Do
  not add a cron that re-discovers what the webhook already told you.
- **Timers are backstops, not primaries.** A timer is legitimate only as a reconciliation
  net under an event path that can miss (§3 Class 2), or when the *origin* of the work is
  itself a schedule (§3 Class 3) — never as the main way event-shaped work is picked up.
- **A timer that has become the primary path for event-shaped work is a leak** (see
  `dev-lead-retry` in §6). It re-introduces exactly the latency and the runaway-amplifier
  risk the event path was meant to avoid.

The event-first principle is the reason the trigger taxonomy in §2 exists: it forces every
trigger to declare *why* it is a timer rather than an event, and to prove it is not a
disguised polling loop.

---

## 2. The three trigger classes

Every agentic workflow's `on:` block falls into exactly one of three classes. The class is
determined by the **origin of the work**, not by the count of triggers.

### Class 1 — event-driven reactions

The work originates from a GitHub webhook that represents it. The workflow subscribes to
that event and acts, scoped to the event's payload.

- **Rule.** Subscribe to the narrowest event(s) that carry the signal. Do **not** add a
  `schedule` — a Class 1 role with a cron is either a disguised Class 2 (declare it and
  give the timer a `timer_role` + stop condition, §6) or a leak.
- Permitted non-webhook triggers: `workflow_dispatch` (human/manual escape hatch) and
  `repository_dispatch` (the sanctioned cross-workflow bridge, §4) — neither is a clock.
- **Self-trigger is forbidden** (§7 rule 1): a Class 1 role must never subscribe to an
  event class its own output emits (e.g. a role that posts an `issue_comment` must not act
  on `issue_comment: created` without filtering out its own actor/marker).

### Class 2 — backstop / reconciliation timers

The work is fundamentally event-driven (Class 1), but the event path can *miss* (a dropped
webhook, a race, a state that became actionable without a fresh event). A Class 2 workflow
pairs the event fast-path with a **low-frequency reconciliation timer** that guarantees a
worst-case latency bound.

- **Rule.** A Class 2 timer must:
  1. carry a `timer_role` of `backstop`, `safety-net`, or `self-heal` (§6.1);
  2. **check a stop condition before acting** (§6.2, §7 rule 6) — it re-dispatches only work
     that is still open and not human-gated;
  3. be **idempotent** — an extra tick is harmless, a missed tick self-heals next tick;
  4. **should** exist alongside an event fast-path, not instead of one. A Class 2 timer with
     a null `event_fast_path` (a schedule as the *only* path to fundamentally event-driven
     work) is a **leak** — a de-facto convergence clock — and is flagged, not forbidden (see
     `dev-lead-retry`, §6.3).
- The timer's cadence buys a latency bound, nothing else; correctness comes from the event
  path. This is why idempotent sweeps may run more often on odd offsets (AGENTS.md
  "Scheduled workflows", Option 2) — precise timing does not matter to a converging sweep.

What separates a Class 2 timer from a Class 3 schedule is **not** the shape of the `on:`
block (both carry a `schedule`) but the *role* of the cadence: a Class 2 cadence reconciles
work that is fundamentally event-driven (so it declares a `timer_role`); a Class 3 cadence
*is* the origin of the work (so it declares none). The validator keys on that declared
`timer_role` — see §3.

### Class 3 — scheduled-origin work

The work's origin *is* a schedule: a weekly report, a daily health scan, a periodic canary.
There is no upstream webhook that represents "produce this week's cost report" — the
cadence is the requirement.

- **Rule.** A Class 3 workflow's `schedule` is legitimate and primary. It must still obey
  the off-peak scheduling standard (non-zero, staggered minute; AGENTS.md "Scheduled
  workflows"). A `workflow_dispatch` (and, for a post-merge canary, a narrow `push` gate)
  may accompany it; these do not change the class.
- A Class 3 workflow must be **idempotent / self-healing** in the same sense as Class 2:
  extra or missed ticks must not corrupt state. Reports overwrite or dedupe; canaries are
  dry-run.

---

## 3. Class discriminator (the parse contract)

`validate-interaction-model` (#1406) checks each §4 row against reality using this
discriminator. Class 1 vs {2,3} is derivable from the `on:` block alone; Class 2 vs 3 turns
on the row's declared `timer_role` (a timer's *role* is not visible in `on:` — that is why
the contract declares it, §6.1). The validator therefore verifies **consistency invariants**,
not a single derived label:

```text
Let S  = the workflow has a schedule.cron trigger.
Let E  = the workflow has >=1 GitHub webhook event trigger that represents work
         (pull_request, pull_request_review, pull_request_review_comment,
          issue_comment, issues, check_run, check_suite, workflow_run,
          discussion_comment, push, ...), EXCLUDING workflow_dispatch and
          repository_dispatch (a manual/bridge trigger, not a clock and not a
          primary-work webhook).
Let R  = the row's timer_role column is non-empty (backstop | safety-net | self-heal).

Class 1  ⇒  E and not S and not R     (pure event reaction; a schedule here is drift)
Class 2  ⇒  S and R                   (a cadence whose role reconciles event-driven work)
Class 3  ⇒  S and not R               (a cadence that IS the origin: report / canary)
```

Consequences the validator enforces: a **Class 1** row must have no `schedule` and no
`timer_role`; a **Class 2** row must have a `schedule` **and** a declared `timer_role`; a
**Class 3** row must have a `schedule` and **no** `timer_role`. A `push`/`workflow_dispatch`
gate on a Class 3 workflow (e.g. a post-merge canary) is allowed and does not change the
class. `event_fast_path` is a *quality attribute* of a Class 2 timer — a null value marks the
leak in §6.3 — not part of the class discriminator.

---

## 4. Classification of current agentic workflows

**This table is machine-checkable, not prose.** Each row carries the workflow's path, its
asserted trigger class, its `timer_role` (if any), and a one-line justification. The shape
is a **fixed-column markdown table** with exactly these columns, in this order:

`Workflow (path) | Class | timer_role | Justification (cite the on: triggers)`

`validate-interaction-model` (#1406) parses this table and verifies each row's asserted
`Class` against that workflow's actual `on:` block via the §3 discriminator. **The table is
CI-verified, not review-verified** (§10) — treat it as load-bearing. When a workflow's
triggers change, its row here must change in the same PR or the validator fails.

| Workflow (path) | Class | timer_role | Justification (cite the `on:` triggers) |
|---|---|---|---|
| `.github/workflows/dev-lead.yml` | 1 | — | `pull_request`, `pull_request_review`, `pull_request_review_comment`, `issue_comment`, `issues:labeled`, `check_run`, `repository_dispatch` — pure webhook reactions; no `schedule`. |
| `.github/workflows/pr-review-trigger.yml` | 1 | — | `check_suite`, `pull_request_review`, `pull_request`, `repository_dispatch:[pr-review-mention]`, `workflow_dispatch` — webhook reactions; no `schedule`. |
| `.github/workflows/ci-failure-analyst.lock.yml` | 1 | — | `check_run:[completed]` only — reacts to a completing check. |
| `.github/workflows/dismiss-stale-bot-reviews.yml` | 1 | — | `pull_request:[synchronize]`, `pull_request_review:[submitted]` — reacts to a push/re-review. |
| `.github/workflows/issue-triage-runner.yml` | 1 | — | `issues:[opened, reopened]` — reacts to a new/reopened issue. |
| `.github/workflows/pr-review-mention.yml` | 1 | — | Mention router: `issue_comment`, `pull_request_review_comment`, `pull_request:[review_requested]`; parses + dispatches, no clock. |
| `.github/workflows/persona-mention.yml` | 1 | — | Mention router: `issue_comment`, `pull_request_review_comment`, `discussion_comment` — dispatches to the persona runner, no clock. |
| `.github/workflows/pr-review-sweep.yml` | 2 | backstop | `schedule: '2,17,32,47 * * * *'` backstop **plus** `workflow_run:[completed]` fast path (#898) scoped to the completing CI run's PR(s); idempotent, per-branch `cancel-in-progress`. |
| `.github/workflows/initiative-driver.yml` | 2 | safety-net | `issues:[closed, labeled]` fast path **plus** `schedule: '23 */6 * * *'` explicitly "safety net for missed close events"; sweeps every open `initiative:auto` epic idempotently. |
| `.github/workflows/dev-lead-retry.yml` | 2 | self-heal | `schedule: '15 */2 * * *'` + `workflow_dispatch`; re-dispatches `status=rate-limited` PRs once the limit clears. **Leak flagged in §6** — no event fast-path, so it behaves as a de-facto convergence clock rather than a true backstop. |
| `.github/workflows/token-report.yml` | 3 | — | `schedule: '34 8 * * 1'` weekly cost rollup; origin is the cadence. |
| `.github/workflows/reviewer-report.yml` | 3 | — | `schedule: '53 9 * * 1'` weekly review-activity report. |
| `.github/workflows/daily-pr-review-health.yml` | 3 | — | `schedule: '13 6 * * *'` daily health scan of run history. |
| `.github/workflows/feature-ideation.yml` | 3 | — | `schedule: '7 7 * * 5'` weekly ideation run; `workflow_dispatch` bridges the `discussion` event it cannot run inline. |
| `.github/workflows/readme-refresh.yml` | 3 | — | `schedule: '41 9 * * 1'` weekly org-README regeneration. |
| `.github/workflows/standards-sync.yml` | 3 | — | `schedule: '11 9 * * 1'` (guard enforces first-Monday-only) standards sync. |
| `.github/workflows/idea-triage.yml` | 3 | — | `schedule: '37 13 * * 1'` weekly Idea Promotion Queue refresh. |
| `.github/workflows/initiative-planner-canary.yml` | 3 | — | `schedule: '30 6 * * *'` daily dry-run canary of `initiative-planner.yml`. |
| `.github/workflows/initiative-driver-canary.yml` | 3 | — | `schedule: '40 6 * * *'` daily dry-run canary of `initiative-driver.yml`. |
| `.github/workflows/pr-review-canary.yml` | 3 | — | `schedule: '50 6 * * *'` daily canary; the `push:[main]` (paths-gated) trigger is a post-merge gate, not an event fast-path — origin is the cadence. |

> Non-agentic infrastructure workflows (CI, Lint, gate guards such as `holdout-guard.yml`
> and `test-deletion-guard.yml`, dependabot plumbing, thin caller stubs) are out of scope:
> they are not roles that *interact*, so they carry no trigger class here.

---

## 5. The GITHUB_TOKEN event-boundary rule and sanctioned bridges

**The rule.** A workflow step running as the default `GITHUB_TOKEN` **cannot emit webhooks
that trigger other workflows.** GitHub deliberately suppresses recursive workflow triggering
for events created by `GITHUB_TOKEN` (a push, a label, a comment, a `workflow_dispatch`, a
`repository_dispatch` made with `GITHUB_TOKEN` starts no downstream run). This is a
loop-prevention guard — but it also means **an event a Class 1 role is waiting for will
silently never arrive** if the upstream producer runs as `GITHUB_TOKEN`.

This boundary is real and already load-bearing in this repo. `actions-fleet-monitor.yml`
documents it inline where it wakes dev-lead:

> `# github.token events do not trigger issues:labeled workflows; use the`
> `# PAT to fire repository_dispatch so Dev-Lead Agent is explicitly woken.`

Crossing the boundary is allowed **only** via one of two sanctioned bridges:

### Bridge A — PAT-backed `repository_dispatch` (event-preserving)

Fire a `repository_dispatch` (or apply the triggering label) using a **PAT**, not
`GITHUB_TOKEN`. Because the event is authored by a real account, GitHub delivers it and the
downstream Class 1 role wakes. This **preserves the event** — the downstream role still runs
its normal event-driven path, scoped to the payload.

- **Canonical example:** the `check_run` → fix-ci bridge. `scripts/dev-lead-ci-relay.sh`
  resolves the PR from a `check_run` event (falling back to the commits-to-pulls API when
  `check_run.pull_requests` is empty, and skipping forks), and the workflow relays it via a
  **PAT `repository_dispatch`** (`dev-lead-ci-failure`) so dev-lead is explicitly woken. The
  fleet monitor uses the same bridge (`repos/…/dispatches` with `GH_PAT_*`) to wake dev-lead
  on high-failure signal.
- **Requirement:** the PAT is the identity boundary — it must be the role's declared
  `runtime.identity.credential` (AGENTS.md "Agent identity & credential secrets"), never a
  shared token borrowed to punch through the boundary. Note that fine-grained PATs are
  restricted to a single resource owner (one user or organization); if the workflow must span
  multiple organizations, classic PATs or GitHub App installation tokens should be used instead.

### Bridge B — a stop-condition-gated backstop timer

Where a PAT bridge is not available or not warranted, a **Class 2 backstop timer** (§2) may
reconcile the missed event on a cadence. The timer does not preserve the event — it
re-discovers the actionable state by scanning — so it **must** satisfy the full timer
contract in §6 (stop condition, idempotency, human-gated markers). `pr-review-sweep.yml`'s
scheduled backstop is exactly this: the guaranteed ≤15-min net under its `workflow_run`
fast path.

**Never** attempt to cross the boundary by having `GITHUB_TOKEN` emit the triggering event
and hoping it fires — it will not, and the failure is silent.

---

## 6. The timer contract

Every `schedule.cron` on an agentic workflow (Class 2 or Class 3) is bound by this contract.
It mirrors the language already in AGENTS.md "Scheduled workflows" (off-peak, idempotent /
self-healing sweeps) — the two standards are consistent, not competing: AGENTS.md governs
*when* a timer may fire (off-peak, staggered minute, higher cadence only if idempotent);
this contract governs *how a timer must behave* once it fires.

### 6.1 The `timer_role` taxonomy

A timer must declare its role. There are three:

| `timer_role` | Meaning | Reset / stop |
|---|---|---|
| `backstop` | Reconciliation net under a Class 1 event fast-path; bounds worst-case latency when the event misses. | Stops when the work item is closed or human-gated; never re-arms a runaway. |
| `safety-net` | Catches work whose triggering event may be dropped entirely (not just delayed). | Same: acts only on still-open, non-human-gated work. |
| `self-heal` | Recovers a *failed* prior run (retry after a transient failure such as a rate limit). | Bounded by an attempt/state check; a success or a human marker ends it. |

A Class 3 report/canary carries **no** `timer_role` — its cadence is the origin of the
work, not a net under an event.

### 6.2 Requirements every timer must meet

1. **Stop-condition-before-acting.** The timer checks a stop condition *before* any write
   or dispatch, and re-dispatches only work that is still open and actionable (§7 rule 6).
2. **Idempotency.** Extra ticks are harmless; a missed tick self-heals on the next tick.
   State is converged, not accumulated (dedupe by marker/SHA/key, never re-append).
3. **Skip human-gated markers.** The timer must **skip** any work carrying a human-gate
   marker (`needs-human-review`, `dev-lead:needs-human`, the `<!-- pr-automation-budget
   exhausted -->` marker, `initiative:hold`, `dev-lead:hands-off`). A timer that re-ignites
   human-paused work is a runaway amplifier (§7 rules 2, 6).
4. **Never re-arm a runaway.** A timer must never reset a safety cap or re-dispatch work
   that a breaker has already stopped. Its reset path must be **human-gated** (§7 rule 2).

### 6.3 The correct example vs. the leak

- **Correct — `initiative-driver.yml` (Class 2, `safety-net`).** Its `schedule: '23 */6 * *
  *'` is explicitly annotated "safety net for missed close events." The primary path is the
  `issues:[closed, labeled]` event; the 6-hour timer only reconciles a dropped close, sweeps
  every open `initiative:auto` epic idempotently, and never releases `initiative:hold` /
  `dev-lead:hands-off` items. A textbook backstop under an event fast-path.

- **Leak — `dev-lead-retry.yml` (Class 2, `self-heal`).** Its `schedule: '15 */2 * * *'` has
  **no event fast-path** — nothing wakes it the moment a rate limit clears; the 2-hour cron
  is the *only* path. That makes it a de-facto convergence clock rather than a true backstop,
  and the #860 postmortem names it an **amplifier** ("re-ignites stalled loops"). It is
  contract-compliant only because it must still honor §6.2.3 (skip exhausted /
  `needs-human-review` PRs before re-dispatching, per the #860 P1 follow-up) and §7 rule 6.
  The standing remediation is to give it an event fast-path (so the timer reverts to a rare
  backstop) or to fold its retry into the state that already carries the rate-limit signal —
  not to shorten the cron.

---

## 7. The #860 normative rules

The PR #860 runaway (378 commits / 1,582 comments over four days, entirely agent-on-agent,
no human in the thread) is the empirical basis for this standard. Its learnings are lifted
**verbatim** from `docs/postmortems/2026-06-pr-860-runaway.md` "Learnings" and are
**normative rules** of this model — a design that violates one is non-compliant:

1. **An agent must never be triggered by its own output.**
2. **A safety cap whose reset is reachable by the runaway is not a cap** — resets must be
   human-gated.
3. **Bound the work item (the PR), not just each worker script.**
4. **Count actions, not just failures** — success can loop too.
5. **A new SHA is not new intent** — SHA-keyed idempotency can't break a fixup loop.
6. **Re-trigger crons amplify runaways** — they must check a stop condition before
   re-dispatching.
7. **No human noticed for four days** — detection must be pushed, not pulled.

Mapping to the rest of this model: rule 1 is the Class 1 self-trigger prohibition (§2);
rule 6 is the timer stop-condition (§6.2.1); rules 2–4 are why the cost bound in §9 is a
per-PR, since-last-human, action-counting budget rather than a failure counter; rule 7 is
why runaway detection must be a pushed signal (§9).

---

## 8. The per-role interaction-contract schema (decision for Story 2)

Story 2 (#1404) makes each role's interaction pattern a **declared, machine-readable
contract** instead of prose spread across workflow comments. This section fixes the schema
(fields + file location) that Story 2 implements; Story 4's validator (#1406) enforces it.

### 8.1 Fields

A per-role interaction contract declares:

```yaml
interaction:
  triggers:
    events:            # Class 1 webhook subscriptions this role reacts to
      - pull_request_review        # each an on: event this role's workflow subscribes to
    timers:            # Class 2/3 schedules; empty for a pure Class 1 role
      - cron: "23 */6 * * *"
        role: safety-net           # timer_role: backstop | safety-net | self-heal
        justification: "reconciles a dropped issues:closed event"
        stop_condition: "epic still open and not initiative:hold"
        event_fast_path: "issues:[closed, labeled]"   # the Class 1 path this backstops; null ⇒ Class 3
  emits:               # events/markers this role produces — used to prove it never
                       # subscribes to its own output (#860 rule 1)
    - "label:dev-lead"
    - "comment-marker:<!-- pr-automation-budget exhausted -->"
  idempotency_key: "pr_number + head_sha"   # what makes a re-run a no-op
  concurrency_lane: "dev-lead-${{ pr }}"    # the serialization lane
  stop_markers:        # human-gate markers this role MUST skip (§6.2.3)
    - needs-human-review
    - dev-lead:needs-human
  budget: pr-automation-budget              # the ceiling this role obeys (§9); no per-role number
```

The validator cross-checks `interaction.triggers.events` and `interaction.triggers.timers`
against the workflow's real `on:` block (the §3 discriminator), and cross-checks `emits`
against `triggers.events` to prove **no role subscribes to an event class it emits** (§7
rule 1).

### 8.2 File location — decision: **standalone repo-local contract, not `persona.yml` (yet)**

Two options were considered:

- **(a) Extend `persona.yml`** with an `interaction:` block. Attractive (one manifest per
  role) but **blocked cross-repo**: `personas/validate-personas.py` validates every
  `persona.yml` against `persona.schema.json` fetched from **`petry-projects/.github`**
  (`standards/personas/persona.schema.json`). Adding an `interaction` block to `persona.yml`
  requires that **external schema to permit the fields first** — otherwise validation fails
  the moment the field appears. That is a cross-repo change on another repo's release
  cadence (the same "land the schema/producer first" sequencing as the #860 org-first fix
  and the caller-stub input-forwarding rule).

- **(b) A standalone repo-local contract file** co-located with the role (e.g.
  `personas/<id>/interaction.yml`, or an `interaction-contract.yml` keyed by workflow path).
  No dependency on the external schema; Story 2 can land and Story 4 can enforce entirely
  within this repo.

**Decision:** Story 2 implements **option (b)** — a standalone repo-local contract file.
Rationale: it unblocks Stories 2 and 4 immediately with no cross-repo prerequisite, keeps
the validator hermetic, and matches this document's "repo-local first" posture.

**Cross-repo implication to sequence (Story 2 / epic `untracked_prerequisites`):** promoting
the contract into `persona.yml` later is the eventual home, but it is **gated on**
`petry-projects/.github` extending `persona.schema.json` to allow the `interaction` block.
Sequence, in order: (1) land the `interaction` object in the org `persona.schema.json`; (2)
release it on the schema's consumed ref; (3) only then move the contract into `persona.yml`
and delete the standalone file. Doing (3) first breaks `validate-personas.py` for every
persona — the mirror of the caller-stub skew rule.

---

## 9. The cost / run-count bound

**This standard introduces no new count-based circuit breakers.** The #860 learnings (§7
rules 2–4) show that adding numeric caps mostly adds *defeatable* guards: a cap whose reset
is reachable by the runaway is not a cap, and a failure counter never sees a success loop.
More numbers would be more false comfort.

The ceiling is therefore the **existing** two controls, and they remain authoritative:

1. **The per-PR automation budget** — `MAX_PR_AUTOMATION_CYCLES=10` in
   `scripts/lib/pr-automation-budget.sh`. It counts agent-authored commits + review cycles +
   acks **since the last human interaction** (action-counting, not failure-counting; per-PR,
   not per-worker — §7 rules 3, 4). On exhaustion it stops all automated writes, adds
   `needs-human-review`, disables auto-merge, and posts one deduped escalation. Re-engagement
   is **human-gated** (§7 rule 2); `FORCE_REVIEW` does not bypass it.
2. **The runaway detector** — the pushed detection signal in
   `daily-pr-review-health` / `scripts/fleet_monitor.sh` that flags open PRs over soft
   thresholds (commit/comment/cycle counts, or open >48h with active agent churn), so a
   runaway is surfaced rather than waited-on (§7 rule 7).

**Rule.** A new agentic role or timer must obey these two ceilings and declare which via its
contract's `budget` field (§8.1). It must **not** invent its own numeric cap as a substitute
— correctness comes from event-first design, stop conditions, and human-gated resets, not
from a bigger pile of counters.

---

## 10. How this document is enforced

This document is **CI-verified, not review-verified.** The enforcing check is
`validate-interaction-model` (Story 4 / #1406). It is what makes the §4 classification table
load-bearing rather than decorative — a contributor who changes a workflow's triggers must
update the table (and the role's §8 contract) in the same PR, or CI fails.

`validate-interaction-model` verifies:

- **Classification rows vs. real `on:` blocks.** Every row of the §4 table is parsed (fixed
  columns: `Workflow (path) | Class | timer_role | Justification`) and its asserted `Class`
  is checked against that workflow's actual `on:` triggers via the §3 discriminator. A row
  whose class no longer matches the workflow fails.
- **Per-role contracts vs. workflows** (once Story 2 lands): each contract's
  `triggers.events` / `triggers.timers` match the workflow's `on:` block, `emits` does not
  intersect subscribed `events` (§7 rule 1), and every Class 2 timer declares a
  `timer_role` + `stop_condition` (§6).

The table's exact shape is fixed **here** (this document is the normative source); #1406
consumes it. If the shape must change, it changes here first and #1406's fixtures change with
it — never the reverse.
