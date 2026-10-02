# 0010. agent-ingress jobs may declare a bounded job-level `concurrency:`; the ingress schema is an allowlist

## Status

proposed

## Context

ADR-0007 collapses each consumer repo's per-role Class-1 caller stubs into one
`agent-ingress.yml`. Its Decision says "The allowed schema is:", lists the keys,
and then forbids "any logic outside the `if:` guard". It does not list
`concurrency:`.

The markets pilot collapse (#1729, package `docs/initiatives/agent-ingress-collapse-markets.md`,
merged in PR #1977) hits this gap. Three of its source stubs (`pr-auto-review`,
`pr-review`, `ci-failure-analyst`) carry a workflow-level `concurrency:` block. One
collapsed workflow cannot host three workflow-level groups without one role
cancelling another, so §3 of the package renders each one as a **job-level**
block and §4 flags that this needs a ruling. The rendered groups all read
`github.event.*`, and two of them choose a group name with a conditional
expression. That is logic outside the `if:` guard, so permitting it is a **new
decision**. It is not a reading of ADR-0007. The Solution Architect ruled this
on issue #2001.

ADR-0000 makes an accepted ADR immutable, and its only permitted edit is the
`superseded-by-NNNN` status. An addendum to ADR-0007 is therefore not available.
This decision also does not reverse ADR-0007. It adds one key to ADR-0007's
schema and leaves the rest of that ADR standing. So the decision is recorded
here as a new ADR that **extends ADR-0007 without superseding it**, the same way
ADR-0007 extended ADR-0001.

**Process gap in ADR-0000, recorded here and not fixed here.** ADR-0000's
`Status` vocabulary is `proposed` | `accepted` | `superseded-by-NNNN`. It has no
`amended-by` or `extended-by` status. An extending ADR therefore cannot be linked
from the ADR it extends: ADR-0007 is immutable and will not name ADR-0010, and a
reader who starts at ADR-0007 has no in-record pointer to this one. Today the only
links are backward (this ADR's references) and out-of-band (issues #2001
and #1729). Closing the gap needs an ADR-0000 change, which is a separate decision.

## Decision

We will permit a **job-level `concurrency:` block** on an `agent-ingress.yml`
job. It is the one key this ADR adds to ADR-0007's schema. Every other part of
ADR-0007, including the rest of its key list and the forbidden `steps:`/`run:`,
stays as written. The block is bounded:

- **`group` reads only the event-payload surface already permitted for a
  job-level `if:`.** That is `github.event_name`, `github.event.action`, and
  payload fields. It must not reach repo state, `needs.` or step outputs, or
  make API calls. Any `${{ }}` expression in the group must pass the same
  predicate an ingress `if:` must pass.
- **`cancel-in-progress` must be a literal boolean** (`true` or `false`), never
  an expression.

We will apply a **collision rule** to every such group:

- Each `group` must carry the **role name as a prefix** (`<role>-…`). For a
  group written as one whole expression, every group-name literal it can
  produce must carry that prefix.
- A `group` must **not match any group declared by that role's pinned
  reusable**, at workflow or job level. A caller-tier group and a
  reusable-tier group that resolve to the same name block or cancel each other
  across the two nested runs. This is a live case and not a hypothetical one:
  `dev-lead` centralizes its concurrency inside `dev-lead-reusable.yml`
  (`dev-lead-pr-{n}`, `dev-lead-issue-{n}`, …), so a caller group that reuses
  one of those names would queue the caller behind its own reusable.

We will **record the precedent explicitly: the ADR-0007 enumerated schema is
exhaustive. It is an allowlist.** A key that is not listed is forbidden.
`caller_stub_freeze` and `validate-caller-inputs` can only enforce a closed list.
An open list "bounded by principle" would push every new key into a case-by-case
argument that no tool can settle. Adding a key costs one ADR, deliberately.
ADR-0000 says that ceremony is the point. This ADR admits `concurrency:` only.
It does **not** admit `strategy:` (and in particular `strategy.matrix`, which is
plainly logic), `env:`, or `continue-on-error:`. Each of those needs its own ADR.

We will enforce the bounds in the existing guards rather than in new ones:

- `scripts/validate-ingress-if.sh` (the #1725 `if:`-as-event-filter checker)
  runs each `concurrency.group` expression through the **same** `viif_forbidden`
  predicate it applies to `if:`. There is no second predicate. It also rejects
  a non-literal `cancel-in-progress` and a group without the role-name prefix.
- `scripts/validate-caller-inputs.sh` already resolves each ingress job's
  reusable at its **pinned ref**. It now also fails a caller group whose literal
  stem (the text before the first placeholder) equals a stem of a group that
  reusable declares. A job that forwards no `with:` inputs is still resolved
  when it declares a group.

## Consequences

- The pilot is no longer blocked on a schema question. Each role keeps its own
  grouping in isolation, and concurrency does not have to be pushed down into
  four reusables. This follows ADR-0007's own reason for one job per role:
  per-role state cannot be merged into one shared value.
- **The markets §3 rendering does not conform as written, and must change
  before it is adopted.** Run against the new checks:
  - `pr-auto-review` falls back to `github.run_id` in its group, and its
    `cancel-in-progress` is an expression — both fail the bounded rule.
  - `pr-review` falls back to `inputs.pr_url` and `github.run_id` — both fail
    the bounded rule.
  - `ci-failure-analyst` renders as `group: "ci-failure-analyst-${{
    github.event.check_run.head_sha }}"` with `cancel-in-progress: false` —
    this conforms to all three bounds.

  The role-prefix half passes for all three roles. The no-collision half,
  checked against each pinned reusable, also passes for all three:
  - `pr-auto-review-reusable.yml@pr-auto-review/v1-stable` and
    `ci-failure-analyst-reusable.yml@7974717…` declare no concurrency.
  - `pr-review.yml@pr-review/stable` declares `pr-review-pr-{…}` and
    `pr-review-batch`, which do not equal the caller's `pr-review-{n}`.

  The cost is real. The `run_id` fallback gave every non-PR event a unique,
  never-cancelled slot. Without it, those events must either share one
  role-prefixed literal slot or keep their uniqueness inside the reusable. That
  is the trade this ADR makes by drawing the line at the event payload.
- The collision check compares **literal stems**. It is a tripwire, not a
  proof. Two groups whose stems differ but whose expression suffixes could still
  render the same string are not caught, and review remains the backstop. The
  check is also only as current as the pinned ref: a channel promotion that adds
  a reusable group can create a collision that the next `lint` run on the
  caller catches, not the promotion itself.
- Every future ingress-schema request now has a fixed price: one ADR. That is
  slower than "obviously harmless, allow it". It is the deliberate cost of a
  list that tools can enforce.
- ADR-0007 stays unchanged and does not point forward to this ADR (see the
  ADR-0000 gap in Context). A reader who starts at ADR-0007 must find this one
  through the ADR directory or the linked issues.

## References

- ADR-0007 (one agent-ingress stub per repo): the schema this extends by one
  key. Not superseded.
- ADR-0001 (thin-caller / reusable two-tier): the no-logic caller boundary
  ADR-0007 loosened only for `if:`.
- ADR-0000 (ADR process): immutability of accepted ADRs, and the missing
  `extended-by` status recorded above.
- #2001: the Solution Architect ruling this ADR implements. #2002: the
  implementing story.
- #1729 / PR #1977, `docs/initiatives/agent-ingress-collapse-markets.md` §3, §3a,
  §4: the rendered ingress and the flagged design point.
- #1725: the `if:`-as-event-filter checker (`scripts/validate-ingress-if.sh`)
  and its frozen rulings, `tests/fixtures/agent-ingress/if-filter-rulings.tsv`.
- `scripts/validate-caller-inputs.sh` (#1253): pinned-ref reusable resolution,
  reused for the collision check.
