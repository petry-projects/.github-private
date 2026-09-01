# solution-architect — persona

Formalized under the [Agentic Persona Standard](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
Follows the **wrap-a-vendored-framework-agent, advisory-everywhere** path
established by [`security-lead`](../security-lead/README.md) and
[`qa-lead`](../qa-lead/README.md).

## What solution-architect is

`solution-architect` wraps the vendored [BMAD Method](../../frameworks/bmad-method/VENDOR.md)
solutioning agent (`bmad-agent-architect`, pinned `v6.8.0`), consumed **by path**
as plain markdown. It advises on **structural review**: it reads the recorded
architecture decisions in [`docs/architecture/adr/`](../../docs/architecture/adr/)
(the S1 ADRs) and measures a proposed change against them, **citing the governing
ADR by number**. It is **advisory on every surface and writes nowhere** — the
safe default for a new persona. The advisory contract lives in
[`prompts/solution-architect/advisory.md`](../../prompts/solution-architect/advisory.md).

The load-bearing rule in that prompt: **if it cannot cite a governing ADR, it
says so** rather than asserting invented doctrine. That is what keeps it off the
ratchet — an advisor with no recorded decision to measure against would otherwise
ratify drift by dressing preference up as policy.

## Why `solution-architect` and not the upstream agent's name

The vendored agent has a person-name upstream ("Winston"). We do not use it. A
persona is named for its **role** ([§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)):
`@petry-projects/solution-architect` tells a reader in a PR comment who is being
addressed and why; the upstream cast list does not. It also means swapping the
agent underneath — or replacing it with a first-party layer — never changes how
this persona is addressed. Upstream is referenced only by its technical skill id
(`framework.skill: bmad-agent-architect`).

## How it is addressed

```text
@petry-projects/solution-architect please measure this design against our ADRs
```

The handle is the org **team** `petry-projects/solution-architect`, **never** the
bare `@solution-architect` account — a bare role mention would notify a stranger
on every use. The team is `privacy: closed` with
`notification_setting: notifications_disabled`: it exists to route a webhook, not
to page anyone. See
[§4.1](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).

## Overlap with existing review surfaces

`solution-architect` is **advisory, not a replacement** for the org's existing
review paths. It is the one lens positioned to notice *structural* drift and told
to measure it against the ADRs — a gap the surfaces below deliberately leave open:

- [`prompts/deep-review-style.md`](../../prompts/deep-review-style.md) is the
  style/behavior-preservation lens in the pr-review cascade. It is explicitly
  told **not** to block a correct, consistent change over subjective preference —
  to *approve* it (see its "Keep findings proportional … approve it" close). That
  is correct for style, but it means structural drift that is internally
  consistent gets waved through. `solution-architect` is the lens that measures
  such a change against the recorded architecture decision instead of ratifying
  it — it advises, it does not gate the cascade.
- The **pr-review cascade** (`prompts/deep-review.md` / triage → deep review)
  classifies risk and can escalate, but does not read `docs/architecture/adr/` or
  cite an ADR. `solution-architect` complements it with ADR-grounded structural
  framing when mentioned; it does not run the cascade or block merges.
- [`dev-lead`](../../.github/workflows/dev-lead.yml) implements issues and opens
  PRs. `solution-architect` reviews *structure* on request and never writes — it
  is an advisor a maintainer summons, not a replacement for the implementer.

Neither is superseded — `solution-architect` is a mention-invoked advisor that
sits alongside them.

## Status: draft

`solution-architect` ships **no dedicated reusable workflow yet** (it is served
by the shared mention router, not a per-persona stub), so:

- there is **no `agents.solution-architect` entry in `canary-rings.json`** yet
  (nothing to roll out via rings until it has a reusable).

The `address` block and the `mention` surface are declared and served by the
shared router; the `interaction.yml` in this directory records what is actually
deployed (`issue_comment` / `pull_request_review_comment` / `discussion_comment`),
not aspirational surfaces.

To promote `solution-architect` past `draft`:

1. Wire a dedicated advisory workflow (if one is needed beyond the shared router)
   as a caller stub + reusable, or promote via the router's release channel.
2. Expand the held-out eval set under
   [`evals/solution-architect/holdout/`](../../evals/solution-architect/holdout/cases.jsonl).
   It carries a synthetic starter set; grow it to `min_cases` with real
   (de-identified) cases and wire the scorer/judge before promotion. The set
   lives under the repo `evals/` tree so `validate-cases.py` and
   `holdout-guard.yml` already cover it.
3. Register the one `agents.solution-architect` entry in `canary-rings.json` and
   cut `solution-architect/v0.1.0`.
4. Soak `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

This persona's behavior lives upstream in `bmad-code-org/BMAD-METHOD`. Do not
hand-edit `frameworks/`. Org-specific behavior is layered via
`definition.layers[].local_overrides`; anything general enough to help other BMAD
users should be raised upstream (`upstream_candidate: true`) rather than kept as
private drift.
