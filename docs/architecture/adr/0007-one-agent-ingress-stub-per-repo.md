# 0007. One agent-ingress stub per repo, not one stub per role

## Status

accepted

## Context

The fleet invokes its agentic roles through per-repo thin caller stubs
(ADR-0001). That works, but the stub count grows as the product of repos and
roles: `scripts/lib/consumer-manifest.json` records **8 consumer repos carrying
9–13 pinned refs each**, and the drift apparatus built to keep those copies
honest is now four tools deep (`fleet_stub_drift.sh`, `template_stub_drift.sh`,
`caller_stub_freeze.sh`, and `validate-caller-inputs` in `lint.yml`, #1253).
The recurring question — asked again in the thread that produced this ADR — is
whether an **org- or repo-level webhook** could trigger the roles directly and
delete the stub tier outright.

ADR-0001 fixed the boundary between the stub and the reusable. It is **silent
on ingress**: it says what a stub may contain, never how the stub is woken.
That gap is what this ADR fills.

A stub is doing three separable jobs: **ingress** (subscribe to the event),
**enrollment** (this repo opted in), and the **ring pin** (which channel tag it
rides, ADR-0002). A webhook replaces only the first.

Four facts, verified on `main` 2026-09-07, decide this:

1. **A webhook is not an executor.** An org webhook delivers JSON to an
   endpoint we would have to host. It cannot start a workflow. It can only call
   back into GitHub (`repository_dispatch`) or run the agent on compute we own
   and operate.
2. **Most of the fleet is not webhook-shaped.** The CI-verified classification
   table in `docs/agentic-interaction-model.md` §4 carries 35 agentic rows: 15
   Class 1 (and one of those, `initiative-planner.yml`, is `workflow_dispatch`
   only — 14 real webhook subscriptions), 3 Class 2 whose *fast path* is an
   event but whose backstop timer is not, and **17 Class 3 rows whose origin is
   a clock**. No webhook exists for "it is Monday." A webhook ingress addresses
   at most ~40% of the fleet; the rest needs a scheduler regardless.
3. **The auth model does not port.** Off Actions there is no `GITHUB_TOKEN` —
   no per-run, repo-scoped, auto-expiring credential shaped by the job's
   `permissions:` block. Org Actions secrets are unreachable from a receiver;
   `secrets: inherit` has no analogue, so `CLAUDE_CODE_OAUTH_TOKEN`,
   `GH_PAT_DON_PETRY` and `GOOGLE_API_KEY` would need a second store and a
   second rotation path. Worst, the §5 recursion suppression — events authored
   by `GITHUB_TOKEN` trigger nothing — is a **free loop-brake that a receiver
   does not get**. After `docs/postmortems/2026-06-pr-860-runaway.md` (1,481
   acknowledgements in 4.5 hours) we are not making the marker guard the sole
   defense. A receiver would also change the acting identity from `don-petry`
   (`runtime.identity.credential`, checked by `verify-persona-identity.sh`) to
   an App actor, and approval-by-actor is already load-bearing under the
   last-push rule.
4. **Hub-and-spoke is already how the fleet works, and the stub is only the
   doorbell.** `persona-mention.yml` parses a mention and bridges via
   `repository_dispatch` to `persona-runner.yml`, which serves all nine
   personas from one runtime — Bridge A in `docs/agentic-interaction-model.md`
   §5, and the shape ADR-0006 recorded as "a persona is a caller of the shared
   runtime." The centralization a webhook promises is already in hand. What is
   *not* consolidated is the ingress file, and consolidating that needs no
   receiver.

Two alternatives were weighed and rejected. An **org-level GitHub App as
ingress** dispatching into hub Actions keeps execution and secrets inside
Actions (neutralizing most of fact 3) and removes the per-repo file entirely,
but it buys that with a hosted 24/7 endpoint, our own dedup and replay handling
on at-least-once delivery, and rings demoted to receiver state — cost that 8
repos do not justify. A **webhook-native runtime** running the agent off
Actions additionally rebuilds run logs, concurrency groups, timeouts,
artifacts, and the secret store, and takes every delta in fact 3 at once.

## Decision

We will **collapse each consumer repo's per-role caller stubs into a single
`.github/workflows/agent-ingress.yml`**, and we will **not** introduce an
off-GitHub webhook receiver at the current fleet size.

The ingress stub remains a thin caller under ADR-0001. The allowed schema is:
`on:` (the union of triggers), `permissions:` (the role's required scopes),
`jobs:` (one per role, each with `uses:` to the pinned reusable, `with:` to
forward declared inputs, `secrets:` (if the reusable declares them), and an `if:`
guarded by event predicates only — see the job-level filter rule below). Explicitly
forbidden: `steps:`, `run:`, and any logic outside the `if:` guard. Each job
must carry the role name to preserve traceability (per ADR-0001), and each `with:`
must forward only inputs the pinned channel's `workflow_call.inputs` declares.
This ADR does not supersede ADR-0001; it fills its ingress gap and adds one
boundary to it.

The checkable boundaries:

- **One ingress per repo.** `agent-ingress.yml` is the only entrypoint for
  eligible Class 1 agentic roles in a consumer repo — those that are not
  `pull_request_target` triggered and are not carve-outs under repository-local
  exceptions (see boundaries below). Its `on:` block is the union of the
  collapsed roles' triggers. `pull_request_target`, Class 2, and Class 3 roles
  keep their own per-role stubs; documented repository-local triggers keep
  per-role stubs as well.
- **A job-level `if:` may act as an event filter, and only as an event
  filter.** The ingress declares **one job per role**, each guarded by an
  expression referencing only `github.event_name`, `github.event.action`, and
  event-payload fields used as a pure predicate. An `if:` that reaches for repo
  state, or any expression that is a script in disguise, is logic and belongs
  in the reusable. One job per role is required, not stylistic: each role needs
  its own `permissions:` block and its own channel pin, and a single
  dispatching job would have to grant the union of every role's permissions.
- **The ring pin moves one tier down, it does not disappear.** The ingress pins
  the router/role reusables at their own ADR-0002 channel tags per job.
  Promotion is still a tag move; it is no longer a per-repo, per-role stub edit.
- **`pull_request_target` roles are excluded and keep their own stub.** Mixing
  `pull_request_target` into the shared ingress makes the whole file's
  privileged-context surface the union of every role in it. That carve-out is
  not negotiable on file-count grounds.
- **Class 2 and Class 3 roles are excluded.** Scheduled and backstop workflows
  keep their own stubs. §5 Bridge B backstops remain required — webhook
  delivery is not a guarantee, under this decision or any other.
- **Non-agentic CI and gate workflows are out of scope** (`ci.yml`, `lint.yml`,
  `holdout-guard.yml`, `duplicate-decl-gate.yml`, `test-deletion-guard.yml`) —
  several are required checks and none is an agentic role.
- **A repo may keep a per-role stub** where it needs genuinely repo-local
  trigger behavior, on the same documented-exception terms ADR-0001 already
  allows.

## Consequences

- The ingress surface per consumer repo collapses from many files to one, and
  a new role reaches the whole fleet by editing eight files instead of eight
  times N. Onboarding a role becomes closer to what onboarding a persona
  already is under ADR-0006 — nearly a data change.
- **The blast radius per repo becomes total.** A syntax error or a bad edit in
  `agent-ingress.yml` disables *every* event-driven agent in that repo at once,
  where today a broken `dev-lead.yml` leaves pr-review alive. This is the real
  price of the decision. `caller_stub_freeze.sh` becomes correspondingly more
  load-bearing: one file, one byte-identity baseline, and a freeze violation is
  now a fleet-wide event rather than a single-role one.
- **Per-repo, per-role staging is lost.** A repo that adopts the ingress
  reaches every role routed by it; narrowing one role's reach in one repo is
  not a lever this ADR provides. This is the same trade ADR-0006 made for
  personas, made knowingly a second time.
- **Run attribution coarsens.** The fleet monitor and the health scans sample
  by `run_workflow`; collapsing many workflow names into one means a failure in
  any routed role samples against the same workflow — the attribution problem
  ADR-0006 fact 3 names for personas, arriving here for roles. Job names must
  carry the role, and any monitor that keys on workflow name must be retargeted
  to job level in the same change.
- **Union subscription starts more runs.** Per-event `paths:` filters are
  per-file, so a role that relied on one (`dependency-advisory.yml`) must move
  that filter down to the job's `if:` guard or into the reusable. The job-level
  guard requires the caller stub to perform a `git diff` against the base branch
  to determine changed paths, and must gracefully skip the job if the check
  cannot determine paths (e.g., on a `workflow_dispatch` or initial push). Roles
  that filter by path in the ingress job must declare the permission their
  changed-path check requires (typically `contents: read`). If the filter is
  moved into the reusable instead, the caller must forward the base branch or
  diff context as declared inputs. Matching changes run the job; unrelated union
  events are skipped and cost no minutes but do cost log legibility.
- **Branch-protection check names change** with the workflow and job names.
  Updating required status checks must land in the same change as the collapse,
  or protection blocks merges on a check that no longer exists.
- The four drift tools all key on per-role stub paths and must be retargeted to
  the single ingress path; `validate-caller-inputs` (#1253) must learn to
  validate one file forwarding to several pinned refs.
- **The webhook option stays open and is not foreclosed.** Reopen it when a
  concrete trigger appears: the fleet outgrowing a stub fanout (roughly, when
  the eight-file edit is itself the bottleneck), a need for events GitHub
  Actions cannot subscribe to inline, or cross-org routing that fine-grained
  PATs cannot span (§5). Reopening means a new ADR, because it moves the
  boundary this one just set.

## References

- ADR-0001 (thin-caller / reusable two-tier) — the boundary this extends; its
  silence on ingress is the gap this fills. Not superseded.
- ADR-0002 (channel-tag release and rings) — unchanged; this ADR records that
  the pin moves from the per-role stub to the ingress job.
- ADR-0006 (shared-runtime personas are not ring-registered) — the same
  consolidation trade, already accepted once for personas.
- `docs/agentic-interaction-model.md` §4 (the CI-verified class table this
  ADR's coverage numbers are read from) and §5 (the `GITHUB_TOKEN` event
  boundary and the two sanctioned bridges).
- `docs/postmortems/2026-06-pr-860-runaway.md` — why the free recursion brake
  is not traded away for topology.
- `scripts/lib/consumer-manifest.json` — the 8-repo fleet size this decision is
  sized against.
