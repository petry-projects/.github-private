# Delivering the Release-Strategy initiative agentically

Companion to `agentic-release-strategy.md` (not yet published). This doc explains how the
10 child issues of epic #495 are delivered by the existing **per-item dev-lead agent** in dependency
order — without changing the agent itself.

## The problem this solves

Dev-lead is purely reactive and **per-item**: it works one issue only when the `dev-lead` label is
applied (`issues: [labeled]`), opens a PR that `Closes #N`, and drives that PR to merge. It has **no
ordering or dependency awareness** — labelling all 10 issues at once runs them in parallel and produces
PRs racing to merge with no regard for "#496 must land before #497".

**Reframe:** coordinating an initiative = deciding *when* the `dev-lead` label is applied to each
ready issue. That decision is what `scripts/initiative-driver.sh` + `.github/workflows/initiative-driver.yml`
automate.

## How the driver works

```
dev-lead merges a PR ──► "Closes #N" closes issue #N
        │
        ▼
initiative-driver  (on: issues:[closed] / issues:[labeled initiative:auto]
                       +  safety-net cron  +  workflow_dispatch)
        │   sweep: for each OPEN epic carrying `initiative:auto`
        │   (workflow_dispatch may target a single epic instead)
        │   gate: epic carries `initiative:auto`?  ── no ─► no-op (human-driven)
        │   for each OPEN sub-issue of the epic:
        │     • all `blocked_by` deps CLOSED?
        │     • not `dev-lead:hands-off` / `initiative:hold`?
        │     • in-flight < MAX_IN_FLIGHT?
        ▼
   apply `dev-lead` label ──► dev-lead picks up the next ready issue
```

- **Native dependencies.** Edges are GitHub "blocked by" relationships (set on #496–#506), visible in
  the issue UI and queried via `…/issues/{n}/dependencies/blocked_by`.
- **Event-driven, self-propelling.** A merge closes an issue, which fires the driver, which releases
  the now-unblocked successors. The cron (`23 */6 * * *`) is only a backstop for missed events.
- **Arming starts it.** Adding `initiative:auto` to an epic fires the driver via `issues:[labeled]`,
  so the first ready wave is released immediately — no waiting for the next cron tick.
- **Epic-agnostic.** The automatic triggers run in *sweep* mode: the driver discovers **every** open
  epic carrying `initiative:auto` and drives each, so it is not pinned to one hard-coded epic. A
  `workflow_dispatch` with an `epic` input targets a single epic (blank = sweep).
- **Bounded.** `MAX_IN_FLIGHT` (default 2) caps how many sub-issues run at once — controlling parallel
  token cost and blast radius. Per-issue concurrency lanes in dev-lead keep concurrent items isolated.

### The PAT requirement (important)

A label applied with the default `GITHUB_TOKEN` does **not** start a new workflow run (GitHub
loop-prevention — the same mechanism behind pr-review #463). The driver therefore applies the
`dev-lead` label using **`GH_PAT_WORKFLOWS`**, so the resulting `issues:[labeled]` event actually
triggers dev-lead. The workflow fails fast if that PAT is absent.

### Safety gates

| Gate | Effect |
|---|---|
| `initiative:auto` on the **epic** | Master switch. Absent ⇒ driver no-ops. Phase 1 stays human-driven until you add it. |
| `dev-lead:hands-off` on an **issue** | Never released (needs a human — e.g. PRs that modify dev-lead/pr-review themselves). |
| `initiative:hold` on an **issue** | Never released (temporary human hold). |
| `MAX_IN_FLIGHT` | Upper bound on concurrently-released sub-issues. |

## The dependency DAG (epic #495)

```
#496 ──┬─► #497 ──┬─► #498
       │          ├─► #499 ──► #500 ──┐
       └─► #505   └─► #506 ──────────►#501 ──► #502 ──► #503
                        #505 ───────────┘
```

| Wave | Issues | Gated on |
|---|---|---|
| 1 | #496 cut `vX.Y.Z` + create `stable` | — |
| 2 | #497 pin callers · #505 tag protection | #496 |
| 3 | #498 runbook · #499 next/ring tags · #506 caller-ref integrity | #497 |
| 4 | #500 rings | #499 |
| 5 | #501 promotion workflow | #500, #505, #506 |
| 6 | #502 rollback + observability | #501 |
| 7 | #503 SC2 game-day | #502 |

## Bootstrap order: human-driven → agent-driven

This initiative modifies dev-lead/pr-review themselves, so the rollout order is also a **safety
bootstrap**, not just a technical dependency:

- **Phase 1 (#496, #497, #505, #498) — human-in-the-loop.** Until `@stable` exists and production duty
  is pinned to it (#497), there is no known-good fallback; letting the agent autonomously merge changes
  that could brick itself is exactly the failure mode we're removing. Leave `initiative:auto` **off**;
  apply the `dev-lead` label by hand, wave by wave (or merge by hand). Issues that edit
  `dev-lead.yml`/`pr-review.yml` carry `dev-lead:hands-off` and require human merge regardless.
- **Phase 2 (#499 onward) — agent-driven.** Once #497 lands, production review/dev duty runs `@stable`,
  so a broken `main`/`next` can no longer block its own fix. **Now** add `initiative:auto` to the epic
  and let the driver run the rest.

## Operating the driver (runbook)

- **Dry-run / preview** what would be released:
  `gh workflow run initiative-driver.yml -f dry_run=true` (or run the script with `DRY_RUN=true`).
- **Arm an initiative:** `gh issue edit <epic> --add-label initiative:auto` — this fires the driver
  immediately (labeled event) and the epic is picked up by every later sweep.
- **Pause one issue:** add `initiative:hold`; **hand back to a human:** add `dev-lead:hands-off`.
- **Throttle:** `gh workflow run initiative-driver.yml -f max_in_flight=1`.
- **Disarm:** remove `initiative:auto` from the epic — in-flight items finish; nothing new is released.

## Follow-ups (not in this scaffold)

- ~~A bats test that mocks `gh` to assert the gate / blocker / cap logic.~~ Done — `tests/test_initiative_driver.bats`.
- ~~Generalize `EPIC` beyond the hard-coded `495` default if a second initiative adopts the driver.~~
  Done — automatic triggers now sweep every `initiative:auto` epic; `workflow_dispatch` can still target one.
