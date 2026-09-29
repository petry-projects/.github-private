# Agent-ingress collapse package — `petry-projects/markets` (pilot, ADR-0007 Phase 3)

> **What this document is.** A reviewable *collapse package* for the pilot repo
> `petry-projects/markets`, produced by dev-lead in `.github-private` under
> issue #1729. It is **not** the markets pull request and cannot be — a
> `.github-private` agent has no write path into `markets`. Everything here is
> built by *reading* markets' live stubs (`gh api …/contents/.github/workflows`),
> never by authoring in that repo. The markets PR is opened by markets' own
> dev-lead, driven by the companion issue this package ships (§10).
>
> The package is complete on its own: it carries the exact `agent-ingress.yml`
> content for markets, the enumerated eligible set with justified carve-outs, the
> old→new required-check name mapping, the baseline citation (§1), the
> skip-billing statement (§7), and the pre-merge gate + rollback for both
> half-landed states (§8).

---

## 1. Baseline (AC5)

The **structural byte-identity baseline** every Phase-1 story hashes and consumes
is the canonical reference, emittable as a machine artifact:

- `docs/architecture/reference/agent-ingress.yml` — the 2-role canonical shape
  (dev-lead + pr-review-mention), emittable via
  `scripts/seed-repo-template.sh --emit-workflow agent-ingress.yml` (#1724 AC #3).

The **behavioral baseline** this collapse must preserve is markets' current fleet
of per-role Class-1 caller stubs on `main`, read live on 2026-09-29:

| Role stub (markets `.github/workflows/…`) | Pinned reusable ref |
| --- | --- |
| `dev-lead.yml` | `…/.github-private/…/dev-lead-reusable.yml@dev-lead/v139-stable` |
| `pr-auto-review.yml` | `…/.github/…/pr-auto-review-reusable.yml@pr-auto-review/v1-stable` |
| `pr-review.yml` | `…/.github-private/…/pr-review.yml@pr-review/stable` |
| `pr-review-mention.yml` | `…/.github/…/pr-review-mention-reusable.yml@pr-review-mention/v2-stable` |
| `ci-failure-analyst.yml` | `…/.github-private/…/ci-failure-analyst-reusable.yml@79747178007d3238bb3afddf7f4d952a293987bd` |

> **Gap (named, not silently carried):** the delivery brief cites a baseline doc
> at `docs/initiatives/agent-ingress-collapse-baseline.md`. That file **does not
> exist** on `main`. The authoritative baseline is the pair above (the canonical
> reference for structure + the live pre-collapse stubs for behavior). If a
> dedicated baseline doc is wanted, it should be filed separately; this package
> does not fabricate one.

The collapse is **behavior-preserving**: each job in the ingress copies its
source stub's pin, `permissions:`, `secrets:`, and event subscription verbatim,
modulo the mechanical `on:`→union / per-role `if:` reconstruction below.

---

## 2. Enumerated eligible set (what collapses) with justified carve-outs

markets carries 18 workflow files. Classification of every one:

### 2a. COLLAPSE — Class-1, event-driven, non-`pull_request_target` agentic roles (5)

| Role | Trigger family | Why eligible |
| --- | --- | --- |
| `dev-lead` | pull_request / review / comment / issues / check_run / repository_dispatch | Class-1 event-driven; no `pull_request_target`. |
| `pr-auto-review` | workflow_run / check_suite / pull_request_review / pull_request | Class-1 event-driven; no `pull_request_target`. |
| `pr-review` | check_suite / pull_request_review / pull_request / workflow_dispatch / repository_dispatch | Class-1 event-driven; no `pull_request_target`. |
| `pr-review-mention` | issue_comment / pull_request_review_comment / pull_request(review_requested) | Class-1 event-driven; no `pull_request_target`. |
| `ci-failure-analyst` | check_run | Class-1 event-driven; no `pull_request_target`. |

### 2b. CARVE-OUT — keep their own per-role stub

| Workflow | Reason (ADR-0007 boundary) |
| --- | --- |
| `add-to-project.yml` | `pull_request_target` role — excluded, not negotiable on file-count grounds. |
| `dependabot-automerge.yml` | `pull_request_target` role. |
| `dependabot-rebase.yml` | `pull_request_target` role. |
| `auto-rebase.yml` | Documented repo-local trigger stub; keeps its own stub. |
| `feature-ideation.yml` | Class-3 (scheduled/clock-origin) — excluded. |
| `initiative-driver.yml` | Class-3 (scheduled/clock-origin) — excluded. |

> Each carve-out above must be re-confirmed by markets' dev-lead against the live
> file before merge (trigger type can change). The classification is read from
> the `on:` block and the class table in `docs/agentic-interaction-model.md` §4.

### 2c. EXPLICITLY EXCLUDED — required-check gate workflows (decision recorded)

| Workflow | Decision | Why |
| --- | --- | --- |
| `agent-shield.yml` | **EXCLUDE** | It is a **required-check gate** (`agent-shield / AgentShield`, see §6), not an agentic role. ADR-0007 puts CI/gate workflows out of scope; `agent-shield.yml` is additionally a protected thin-caller exempt from modification (AGENTS.md / CLAUDE.md). It also triggers on `push`, which the ingress `on:` union does not carry. |
| `dependency-audit.yml` | **EXCLUDE** | It is a **required-check gate** (`dependency-audit / Detect ecosystems`, see §6), not an agentic role. Out of scope per ADR-0007; also `push`-triggered. |

### 2d. Out of scope entirely — non-agentic CI / plumbing

`ci.yml`, `sonarcloud.yml`, `shell-tests.yml`, `apply-repo-settings.yml`,
`copilot-setup-steps.yml` — non-agentic CI, settings, or setup workflows. Never
in scope for the ingress collapse.

---

## 3. The exact `agent-ingress.yml` content for `markets`

Behavior-preserving collapse of the 5 roles in §2a. Built to the #1724 canonical
structure: `on:` = union of the five stubs' triggers; `permissions: {}` at top
level; exactly one job per role carrying the role name; each job with its own
per-job pin (moved down a tier from the per-file pin, ADR-0002), its own
`permissions:`, its own `secrets:`, and a **pure event-filter `if:`** that
reconstructs that role's original subscription.

> **Two pins below are defective and are preserved *as-is for pilot parity* while
> being NAMED here — see §5 for the follow-up corrections.** A behavior-preserving
> collapse must not silently "fix" a pin in the same change that moves it; the
> corrections are separate follow-ups.
>
> **Design-point flag — job-level `concurrency:` (see §4).** Three source stubs
> carry a *workflow-level* `concurrency:` block. A single collapsed workflow
> cannot host three workflow-level groups, so they are rendered as **job-level**
> `concurrency:` below. ADR-0007's enumerated ingress schema
> (`on:`/`permissions:`/`jobs:` with `uses`/`with`/`secrets`/`if`/`permissions`/
> `name`) does **not** list `concurrency:`. This needs an explicit ruling before
> merge (§4).

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# Agent Ingress — petry-projects/markets (ADR-0007, epic #1723, story #1729)
#
# ONE ingress for this repo's eligible Class-1 event-driven agentic roles. The
# on: block is the UNION of the collapsed roles' triggers; each job below is ONE
# role, guarded by a PURE event-filter if: that reconstructs that role's original
# subscription. pull_request_target roles (add-to-project, dependabot-automerge,
# dependabot-rebase), repo-local (auto-rebase), Class-3 (feature-ideation,
# initiative-driver), and required-check gates (agent-shield, dependency-audit)
# keep their own stubs — see docs/initiatives/agent-ingress-collapse-markets.md.
# ─────────────────────────────────────────────────────────────────────────────

name: Agent Ingress

on:
  pull_request:
    # opened/reopened/synchronize ← dev-lead(base=main), pr-auto-review, pr-review;
    # ready_for_review ← pr-auto-review, pr-review; review_requested ← pr-review-mention.
    types: [opened, reopened, synchronize, ready_for_review, review_requested]
  pull_request_review:
    # submitted ← dev-lead, pr-auto-review, pr-review; dismissed ← pr-auto-review, pr-review.
    types: [submitted, dismissed]
  pull_request_review_comment:
    types: [created]
  issue_comment:
    types: [created]
  issues:
    types: [labeled]
  check_run:
    types: [completed]
  check_suite:
    types: [completed]
  workflow_run:
    workflows: ["CI"]
    types: [completed]
  workflow_dispatch:
    inputs:
      pr_url:
        description: "Optional: review a single PR URL instead of enumerating"
        required: false
        type: string
      dry_run:
        description: "If true, never submit reviews or comments"
        required: false
        default: "false"
        type: string
      force_review:
        description: "If true, bypass idempotency and re-review at the same head SHA"
        required: false
        default: "false"
        type: string
  repository_dispatch:
    types: [dev-lead-ci-failure, dev-lead-reviews-retry, dev-lead-issue-retry, pr-review-mention]

permissions: {}

jobs:
  # ── dev-lead ────────────────────────────────────────────────────────────────
  dev-lead:
    if: >-
      (github.event_name == 'pull_request'
        && contains(fromJSON('["opened","reopened","synchronize"]'), github.event.action)
        && github.event.pull_request.base.ref == 'main')
      || (github.event_name == 'pull_request_review' && github.event.action == 'submitted')
      || github.event_name == 'pull_request_review_comment'
      || github.event_name == 'issue_comment'
      || github.event_name == 'issues'
      || github.event_name == 'check_run'
      || (github.event_name == 'repository_dispatch'
          && contains(fromJSON('["dev-lead-ci-failure","dev-lead-reviews-retry","dev-lead-issue-retry"]'), github.event.action))
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v139-stable  # NOSONAR(githubactions:S7637) first-party channel ref
    with:
      agent_ref: dev-lead/v139-stable
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
      checks: read
      statuses: read

  # ── pr-auto-review ──────────────────────────────────────────────────────────
  pr-auto-review:
    if: >-
      (github.event_name == 'pull_request'
        && contains(fromJSON('["opened","reopened","synchronize","ready_for_review"]'), github.event.action))
      || (github.event_name == 'pull_request_review'
          && contains(fromJSON('["submitted","dismissed"]'), github.event.action))
      || github.event_name == 'check_suite'
      || github.event_name == 'workflow_run'
    # Workflow-level concurrency in the source stub → job-level here (see §4).
    concurrency:
      group: >-
        ${{
        (github.event_name == 'pull_request' && format('pr-auto-review-ready-check-pr-{0}', github.event.pull_request.number))
        || (github.event_name == 'pull_request_review' && format('pr-auto-review-ready-check-pr-{0}', github.event.pull_request.number))
        || format('pr-auto-review-ready-check-unique-{0}', github.run_id)
        }}
      cancel-in-progress: ${{ github.event_name == 'pull_request' || github.event_name == 'pull_request_review' }}
    permissions:
      pull-requests: read
      checks: read
      actions: read
    uses: petry-projects/.github/.github/workflows/pr-auto-review-reusable.yml@pr-auto-review/v1-stable  # NOSONAR(githubactions:S7637) first-party channel ref
    secrets:
      GH_PAT_WORKFLOWS: ${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}

  # ── pr-review ─────────────────────────────────────────────────────────────────
  pr-review:
    # Subscription filter AND the source stub's check_suite-with-no-PR skip, both
    # pure event predicates over the delivered payload.
    if: >-
      (
        (github.event_name == 'pull_request'
          && contains(fromJSON('["ready_for_review","reopened","synchronize"]'), github.event.action))
        || (github.event_name == 'pull_request_review'
            && contains(fromJSON('["submitted","dismissed"]'), github.event.action))
        || github.event_name == 'check_suite'
        || github.event_name == 'workflow_dispatch'
        || (github.event_name == 'repository_dispatch' && github.event.action == 'pr-review-mention')
      )
      && (github.event_name != 'check_suite' || github.event.check_suite.pull_requests[0] != null)
    concurrency:
      group: >-
        pr-review-${{
          github.event.pull_request.number
          || github.event.check_suite.pull_requests[0].number
          || inputs.pr_url
          || github.event.client_payload.pr_url
          || github.run_id
        }}
      cancel-in-progress: true
    permissions:
      contents: read
      pull-requests: write
      checks: read
    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/stable  # NOSONAR(githubactions:S7637) first-party channel ref  # DEFECTIVE PIN — see §5
    with:
      agent_ref: pr-review/stable
      pr_url: ${{ inputs.pr_url || '' }}
      dry_run: ${{ inputs.dry_run || '' }}
      force_review: ${{ inputs.force_review || '' }}
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable

  # ── pr-review-mention ──────────────────────────────────────────────────────────
  pr-review-mention:
    if: >-
      (
        (github.event_name == 'pull_request' && github.event.action == 'review_requested')
        || github.event_name == 'issue_comment'
        || github.event_name == 'pull_request_review_comment'
      )
      && github.event.sender.type != 'Bot'
    permissions:
      pull-requests: write
    uses: petry-projects/.github/.github/workflows/pr-review-mention-reusable.yml@pr-review-mention/v2-stable  # NOSONAR(githubactions:S7637) first-party channel ref
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable

  # ── ci-failure-analyst ─────────────────────────────────────────────────────────
  ci-failure-analyst:
    if: >-
      github.event_name == 'check_run'
      && github.event.check_run.conclusion == 'failure'
      && !startsWith(github.event.check_run.name, 'CI Failure Analyst')
    concurrency:
      group: "ci-failure-analyst-${{ github.event.check_run.head_sha }}"
      cancel-in-progress: false
    permissions:
      pull-requests: write
      issues: write
      actions: read
      contents: read
      checks: read
    uses: petry-projects/.github-private/.github/workflows/ci-failure-analyst-reusable.yml@79747178007d3238bb3afddf7f4d952a293987bd  # DEFECTIVE PIN — bare SHA, see §5
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### 3a. `if:` predicate provenance (every guard is a pure event filter)

Each construct below is either an explicit ALLOW row in
`tests/fixtures/agent-ingress/if-filter-rulings.tsv` or a plain read of a
delivered-event payload field (the ALLOW principle: "payload fields read as a
plain predicate are the delta that woke the ingress"). None reaches
vars/secrets/needs/hashFiles/repo-identity/default_branch/standing-labels.

| Construct used | Ruling |
| --- | --- |
| `github.event_name == …` | ALLOW (`event-name`) |
| `github.event.action == …` / `contains(fromJSON('[…]'), github.event.action)` | ALLOW (`event-action`) |
| `github.event.pull_request.base.ref == 'main'` | ALLOW (`base-ref`) |
| `github.event.sender.type != 'Bot'` | payload field as predicate — PASSES the guard |
| `github.event.check_run.conclusion` / `.name` | payload field as predicate — PASSES the guard |
| `github.event.check_suite.pull_requests[0] != null` | event-association null-check on the delivered payload (NOT the standing labels array) — PASSES the guard |

> **Verified empirically.** The exact §3 ingress was run through the frozen #1725
> guard (`.dev-lead/scripts/validate-ingress-if.sh`, which consumes the rulings
> TSV directly) against this repo's rulings fixture:
> `ingress-if: OK — every agent-ingress job is a thin caller with a pure
> event-filter if:` (exit 0). The three payload-predicate rows above have no
> dedicated named ruling row but pass the allowlist backstop as reads of the
> delivered event. markets' dev-lead re-runs the same guard at PR time (§8a) as
> the authority; if a future rulings change flips any to FORBID, that predicate
> moves into the reusable — a change to the reusable, not to this ingress shape.

---

## 4. Design-point flag — job-level `concurrency:` needs a ruling

`pr-auto-review.yml`, `pr-review.yml`, and `ci-failure-analyst.yml` each carry a
**workflow-level** `concurrency:` block in their source stubs; `dev-lead.yml`
centralizes concurrency inside its reusable (no caller block). One collapsed
workflow cannot host three distinct workflow-level groups without cross-role
cancellation, so §3 renders each as a **job-level** `concurrency:` block —
GitHub Actions supports job-level concurrency, and it preserves each role's
grouping in isolation.

**The ruling needed:** ADR-0007's enumerated ingress schema is
`on:`/`permissions:`/`jobs:` (with `uses`/`with`/`secrets`/`if`/`permissions`/
`name`). It does **not** enumerate `concurrency:`. Two readings:

1. **Allow job-level `concurrency:`** as a non-logic, declarative grouping key
   (it carries no `steps:`/`run:` and is not a repo-state reach) — the reading
   §3 assumes, because dropping it would regress the duplicate-run collapse the
   source stubs added (#1126, cancelled-runs fix).
2. **Forbid it** as outside the enumerated schema — which would force the
   concurrency grouping down into each reusable.

**Recommendation:** ratify reading (1) with a one-line schema addendum to
ADR-0007 (concurrency is a declarative grouping key, not logic). Do this
*before* the markets PR merges, so the ingress is not blocked on an unresolved
schema question. Reading (2) is viable but is a reusable change per role and
should not gate the pilot.

---

## 5. The two defective pins (named, with follow-up corrections)

Both are preserved as-is in §3 for behavior parity in the pilot, and flagged
inline with `# DEFECTIVE PIN`. Neither is silently carried:

### 5a. `pr-review` → `@pr-review/stable` (stale / non-standard channel)

- **Defect:** every other first-party pin rides a `<name>/v<MAJOR>-<tier>`
  channel (`dev-lead/v139-stable`, `pr-auto-review/v1-stable`,
  `pr-review-mention/v2-stable`). `pr-review/stable` is a bare tier with **no
  major version** — a pre-ADR-0002 channel name that skips the MAJOR ring. It is
  exposed to the channel-skew defect class (#1052/#1034).
- **Follow-up:** repoint to the current `pr-review/v<MAJOR>-stable` channel once
  it is published, and confirm the reusable's `workflow_call.inputs` match the
  forwarded `agent_ref`/`pr_url`/`dry_run`/`force_review`. Track as a separate
  issue against the `pr-review` reusable owner; **do not** bundle into the
  collapse PR.

### 5b. `ci-failure-analyst` → `@79747178007d3238bb3afddf7f4d952a293987bd` (bare SHA aliased to `main`)

- **Defect:** a frozen commit SHA (commented `# main`), not a moving channel tag
  — a direct ADR-0002 violation. It pins to a raw commit that will never advance
  and is not covered by the ring-promotion model; a fix to
  `ci-failure-analyst-reusable.yml` cannot reach markets without editing this
  pin by hand.
- **Follow-up:** publish/adopt a `ci-failure-analyst/v<MAJOR>-stable` channel tag
  and repoint. Track against the `ci-failure-analyst` reusable owner in
  `.github-private`; **do not** bundle into the collapse PR.

> Keeping both as-is in the collapse is the correct pilot call: a
> behavior-preserving collapse changes *where* the pin lives (per-file → per-job),
> not *what* it points at. Correcting a channel in the same change would confound
> "the collapse is behavior-identical" with "the pin changed," making rollback
> attribution ambiguous.

---

## 6. Old → new required-check name mapping (AC — name mapping)

Check context format is `<caller-job-key> / <reusable-internal-job-name>`.
Reusable internal job names, read on 2026-09-29:

| Role | Reusable internal job(s) | Old check context (per-role stub job key) | New check context (ingress job key) |
| --- | --- | --- | --- |
| dev-lead | `dispatch`, `ci-relay`, `resume` (dev-lead-reusable.yml) | `dev-lead / dispatch` etc. | `dev-lead / dispatch` etc. (job key unchanged) |
| pr-auto-review | reusable internal job (pr-auto-review-reusable.yml) | `pr-auto-review / <job>` | `pr-auto-review / <job>` |
| pr-review | `review` (pr-review.yml) | `review / review` | `pr-review / review` |
| pr-review-mention | reusable internal job (pr-review-mention-reusable.yml) | `pr-review-mention / <job>` | `pr-review-mention / <job>` |
| ci-failure-analyst | `analyze` (ci-failure-analyst-reusable.yml) | `analyze / analyze` | `ci-failure-analyst / analyze` |

> **KEY FINDING — no required-status-check edit is coupled to this merge.**
> markets' branch ruleset (`GET /repos/petry-projects/markets/rules/branches/main`,
> read 2026-09-29) requires exactly:
>
> ```
> CodeQL, SonarCloud, agent-shield / AgentShield, dependency-audit / Detect ecosystems
> ```
>
> **None of the 5 collapsing roles is a required check.** The check contexts that
> change (e.g. `review / review` → `pr-review / review`,
> `analyze / analyze` → `ci-failure-analyst / analyze`) are **not** in the required
> set, so no ruleset edit needs to land atomically with the collapse. ADR-0007's
> "branch-protection check names change with the workflow and job names, updating
> required status checks must land in the same change" warning is **discharged by
> observation here**: there is nothing to update. The two required agentic-ish
> gates (`agent-shield`, `dependency-audit`) are the very workflows §2c EXCLUDES
> from the collapse, so their check contexts are untouched.
>
> markets' dev-lead must **re-read the ruleset at PR time** and abort the merge if
> any of the 5 roles has since been added as a required check (would reactivate
> the atomic-rename requirement below).

---

## 7. Skip-billing statement (AC10 — kind (a) only)

Every skip introduced by this collapse is **kind (a): job-level `if:` event-filter
skip** — evaluated by the Actions service *before* a runner is assigned, costing
**zero runner minutes**. When markets receives a union event a given role does not
subscribe to (e.g. `dev-lead` on a `check_suite` completion), that role's job is
`if:`-skipped with no runner.

This collapse introduces **no kind (b)** skips. Kind (b) — a reusable-internal
changed-path check that holds a runner before skipping — arises only when a
`paths:` filter is pushed down into a reusable (ADR-0007 consequence, e.g.
`dependency-advisory.yml`). **None of the 5 markets roles uses a `paths:` filter**
in its source stub, so no `paths:` filter moves down a tier and no per-event
runner cost is incurred. The billing profile is therefore strictly
event-filtered, no-runner skips.

---

## 8. Pre-merge gate + rollback for both half-landed states (AC3 / AC8)

This is a **package deliverable describing the gate and rollback**, not a merge
performed here.

### 8a. Pre-merge gate (markets dev-lead runs this before merging the collapse PR)

1. **Re-read the ruleset** (`GET …/markets/rules/branches/main`) and confirm none
   of `dev-lead`, `pr-auto-review`, `pr-review`, `pr-review-mention`,
   `ci-failure-analyst` has become a required check. If any has, STOP — the
   atomic rename in §8d applies.
2. **Confirm carve-outs unchanged** — the 6 files in §2b still carry their
   `pull_request_target` / repo-local / Class-3 triggers.
3. **Run the #1725 if-linter** over `agent-ingress.yml` — every job `if:` must
   pass as a pure event filter (validates the three "ALLOW-consistent" predicates
   in §3a).
4. **Resolve the §4 concurrency ruling** — job-level `concurrency:` must be
   ratified (or the blocks removed and pushed into the reusables) before merge.
5. **Confirm byte-identity** of each job block against the canonical
   agent-ingress template once published (§9) via `caller_stub_freeze.sh` /
   `fleet_monitor.sh` role-path.

### 8b. The collapse PR is a two-file change in markets

- **ADD** `.github/workflows/agent-ingress.yml` (§3 content).
- **DELETE** the 5 per-role stubs (`dev-lead.yml`, `pr-auto-review.yml`,
  `pr-review.yml`, `pr-review-mention.yml`, `ci-failure-analyst.yml`).

Both halves in **one PR, one commit** so the add and the deletes land atomically.

### 8c. The two half-landed states and why both are safe here

Because **no collapsing role is a required check** (§6), neither half-landed state
can block a merge:

- **State A — ingress added, stubs not yet deleted (double-dispatch window).**
  Both `agent-ingress.yml` and the old stubs fire → each role runs *twice* per
  event. Wasteful and log-noisy, but not a correctness or gating failure (agentic
  roles are idempotent per-head-SHA; `pr-review`/`pr-auto-review` concurrency
  groups collapse duplicates). **Rollback:** revert the ingress add; the stubs
  alone resume normal single dispatch.
- **State B — stubs deleted, ingress not yet added (coverage gap window).**
  No event-driven agent runs in markets until the ingress lands. No required
  check depends on them, so **merges are not blocked** — only agent assistance is
  paused. **Rollback:** restore the 5 stubs (revert the delete); dispatch resumes.

Landing both halves in one commit (§8b) means neither transient state is ever
committed to `main`; they are described here only to prove rollback safety.

### 8d. Atomic-rename contingency (only if §8a step 1 fails)

If, at PR time, any of the 5 roles has become a required check, then the ruleset
edit renaming the old check context to the new (§6 mapping) **must land in the
same change** as the collapse (ADR-0007), because branch protection would
otherwise block on a check that no longer exists (State A) or wait forever on one
never produced (State B). As read on 2026-09-29 this contingency does **not**
apply.

---

## 9. AC11 (prepared, activation deferred) — STUB_REGISTRY rows + canonical template

Two AC11 pieces are **cross-repo or post-collapse and cannot be completed from
`.github-private` now**; they are prepared here ready-to-apply.

### 9a. Ready-to-apply `STUB_REGISTRY` rows (scripts/fleet_monitor.sh)

Row format (from `fleet_monitor.sh`):
`name⇥label⇥stub_path⇥canonical_path⇥role⇥legacy_path⇥legacy_canonical_path`.
The per-job **role** selector makes the comparison unit the extracted
`<role>` job block of `agent-ingress.yml`; **legacy_path** is the pre-collapse
per-role stub consulted only while a repo carries no `agent-ingress.yml` (#1726
AC #4).

```
$'dev-lead\tDev-Lead\t.github/workflows/agent-ingress.yml\t<CANONICAL agent-ingress path>\tdev-lead\t.github/workflows/dev-lead.yml\t<legacy dev-lead canonical>'
$'pr-auto-review\tPR-Auto-Review\t.github/workflows/agent-ingress.yml\t<CANONICAL agent-ingress path>\tpr-auto-review\t.github/workflows/pr-auto-review.yml\tstandards/workflows/pr-auto-review.yml'
$'pr-review\tPR-Review\t.github/workflows/agent-ingress.yml\t<CANONICAL agent-ingress path>\tpr-review\t.github/workflows/pr-review.yml\t<legacy pr-review canonical>'
$'pr-review-mention\tPR-Review-Mention\t.github/workflows/agent-ingress.yml\t<CANONICAL agent-ingress path>\tpr-review-mention\t.github/workflows/pr-review-mention.yml\tstandards/workflows/pr-review-mention.yml'
$'ci-failure-analyst\tCI-Failure-Analyst\t.github/workflows/agent-ingress.yml\t<CANONICAL agent-ingress path>\tci-failure-analyst\t.github/workflows/ci-failure-analyst.yml\t<legacy ci-failure-analyst canonical>'
```

> `<CANONICAL agent-ingress path>` and the three `<legacy … canonical>` cells
> resolve to wherever the org publishes the canonical `agent-ingress.yml` template
> (§9b) and each role's existing per-role canonical. They are left as markers
> because publishing the canonical template is the cross-repo step below.

### 9b. Canonical `agent-ingress.yml` template — publish is cross-repo (DEFERRED)

The canonical, per-repo-parameterized `agent-ingress.yml` template that markets'
copy must byte-match lives in the canonical stub repo
(`CANONICAL_STUB_REPO`, default `petry-projects/.github`). **Publishing it is a
write to another repo and cannot be done from `.github-private`.** The §3 content
is the pilot instance; the generalized template (repo-agnostic pins, the
role-superset `on:` union, adopter notes) is authored in the canonical repo by
its owner.

### 9c. Why in-repo activation is premature

- Adding the `STUB_REGISTRY` rows (§9a) before the canonical template exists
  makes `fleet_monitor.sh` compare markets' ingress against a `canonical_path`
  that 404s.
- ALIGNED verification via the role-path needs a **post-collapse** markets
  carrying `agent-ingress.yml`; today markets is pre-collapse, so every role
  would fall back to the legacy per-role path.

Activation lands after the markets PR merges and the canonical template is
published — this package hands both artifacts to that follow-up.

---

## 10. Companion issue for `petry-projects/markets` (prepared; filing is remaining)

`.github-private` dev-lead cannot open the markets PR, and this package cannot
file cross-repo either from here. The companion-issue body below is the committed
artifact; **filing it in `petry-projects/markets` is the remaining post-merge
step** (AC7 evidence is the filed issue link + the markets PR it drives).

```markdown
Title: [ADR-0007] Collapse per-role Class-1 stubs into agent-ingress.yml (pilot)

Body:
Implements ADR-0007 for this repo: collapse the 5 event-driven Class-1 agentic
caller stubs into a single `.github/workflows/agent-ingress.yml`.

Collapse package (source of truth, in .github-private):
docs/initiatives/agent-ingress-collapse-markets.md

## Do this
1. ADD `.github/workflows/agent-ingress.yml` with the exact content in §3 of the
   package.
2. DELETE the 5 per-role stubs: dev-lead.yml, pr-auto-review.yml, pr-review.yml,
   pr-review-mention.yml, ci-failure-analyst.yml.
3. Both changes in ONE commit / ONE PR (§8b).

## Before you merge (§8a gate)
- Re-read the branch ruleset; confirm none of the 5 roles is a required check
  (as of 2026-09-29 none is — see §6). If one has become required, apply the
  atomic ruleset rename in §8d in the same PR.
- Run the #1725 if-linter over agent-ingress.yml (every job if: is a pure event
  filter — §3a).
- Confirm the §4 job-level concurrency ruling is ratified.
- Keep the 6 carve-out stubs (§2b) and both required-gate stubs (§2c) untouched.

## Known follow-ups (do NOT bundle into this PR — §5)
- pr-review pin `@pr-review/stable` is a stale bare-tier channel — repoint after
  a `pr-review/v<MAJOR>-stable` channel is published.
- ci-failure-analyst pin is a bare SHA (`7974717…` # main) — repoint to a moving
  `ci-failure-analyst/v<MAJOR>-stable` channel.

## Rollback (§8c)
- Both half-landed states are safe (no required check depends on the 5 roles):
  revert the ingress add (State A) or restore the stubs (State B).
```

---

## 11. Honest gap list (what is NOT done, and why)

| Item | Status | Reason |
| --- | --- | --- |
| markets PR (add ingress + delete 5 stubs) | **Not done — cannot be** | Cross-repo write; only markets' dev-lead can author it. Driven by §10. |
| Companion issue filed in markets | **Prepared, not filed** | Cross-repo write from `.github-private` not available in this run. Body is committed in §10. |
| Canonical `agent-ingress.yml` template published | **Deferred (§9b)** | Write to `petry-projects/.github`; cross-repo. |
| `STUB_REGISTRY` rows activated in fleet_monitor.sh | **Prepared, not applied (§9a)** | Would 404 against an unpublished canonical path and can't be ALIGNED-verified pre-collapse (§9c). |
| §4 job-level concurrency schema ruling | **Flagged, needs decision** | ADR-0007 schema doesn't enumerate `concurrency:`; recommendation is reading (1). |
| pin corrections (§5a/§5b) | **Named, not applied** | Behavior-preserving collapse must not change pins; separate follow-ups. |
| Dedicated baseline doc at the brief's cited path | **Does not exist (§1)** | Not fabricated; real baseline is the reference file + live stubs. |
