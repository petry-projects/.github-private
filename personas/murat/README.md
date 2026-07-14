# Murat — Master Test Architect & Quality Advisor

Worked example for the [Agentic Persona Standard](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
Murat is the reference for the **wrap-a-vendored-framework-agent, advisory-everywhere** path.

## What Murat is

Murat is the vendored [BMAD Test Architecture](../../frameworks/bmad-test-architecture/VENDOR.md)
agent (`bmad-tea`, pinned `v1.19.0`), consumed **by path** as plain markdown.
He advises on risk-based test strategy, fixture architecture, ATDD, API/UI
automation, CI/CD quality gates, and test review. He is **advisory on every
surface and writes nowhere** — the safe default for a new persona.

Today he is already consulted during planning by Bob (see
[`prompts/bmad/scrum-master.md`](../../prompts/bmad/scrum-master.md), Step 4).
This manifest makes him a first-class, addressable persona.

## Status: draft

Murat ships **no dedicated reusable workflow yet**, so:

- there is **no `agents.murat` entry in `canary-rings.json`** yet (nothing to
  roll out via rings until he has a reusable), and
- the manifest carries no `runtime:` block.

To promote Murat past `draft`:

1. Wire a dedicated advisory workflow (e.g. mention- or `check_run`-triggered
   test review) as a caller stub + reusable, and add its `runtime:` block.
2. Expand the held-out eval set under
   [`evals/murat/holdout/`](../../evals/murat/holdout/cases.jsonl). It already
   carries a synthetic starter set that clears the `min_cases` gate (6 held-out,
   4 dev); grow it with real (de-identified) cases and wire the scorer/judge
   before promotion. The set lives under the repo `evals/` tree so
   `validate-cases.py` and `holdout-guard.yml` already cover it.
3. Register the one `agents.murat` entry in `canary-rings.json` and cut
   `murat/v0.1.0`.
4. Soak `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the Definition of Done in `persona-standards.md` §7.

## Contributing upstream

Murat's behavior lives upstream in `bmad-code-org/bmad-method-test-architecture-enterprise`.
Do not hand-edit `frameworks/`. Org-specific behavior is layered via
`definition.layers[].local_overrides`; anything general enough to help other
BMAD users should be raised upstream (`upstream_candidate: true`) rather than
kept as private drift.
