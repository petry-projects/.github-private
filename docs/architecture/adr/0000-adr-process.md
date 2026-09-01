# 0000. ADR process and conventions

## Status

accepted

## Context

The solution-architect persona (and the humans it advises) needs a normative
**intent-of-record** to cite by number, instead of reverse-engineering intent
from drifted code. `AGENTS.md` already carries the structural doctrine, but it
is prose organized for readers, not a numbered, immutable, quotable record. We
need a stable place to lift that doctrine into discrete, citable decisions.

This repo is a shell + reusable-workflow infrastructure repo. Its architecture
decisions are about *code and module conventions* (thin-caller tiers, the
rubric registry, the pure-logic + bats split), not product/system design. The
closest reputable genre match is a platform/tooling ADR log such as
[Backstage's](https://github.com/backstage/backstage/tree/master/docs/architecture-decisions).

## Decision

We will keep Architecture Decision Records under `docs/architecture/adr/`, one
Markdown file per decision, and govern them by these rules:

- **Filenames** are sequential: `NNNN-title.md`, zero-padded to four digits,
  starting at `0000` (this process record). The number, once assigned, is
  permanent and is the citable identity of the decision.
- **Template** is Nygard's five sections, in order: `Title` / `Status` /
  `Context` / `Decision` / `Consequences`. We do not use MADR (its
  decision-drivers and considered-options sections are overhead for doctrine
  whose alternatives were never weighed here) and we keep `Status` (Backstage's
  variant omits it) because the immutability rule below is unimplementable
  without it.
- **`Decision` is written in the active voice, beginning "We will…"** — that
  phrasing is what turns a description into a checkable invariant.
- **`Status`** is one of: `proposed` | `accepted` | `superseded-by-NNNN`.
- **An accepted ADR is immutable.** A reversal or change of direction is a NEW
  ADR that supersedes it — never an in-place edit of the accepted record. When
  ADR `M` replaces ADR `N`, `N`'s status becomes `superseded-by-M` (the single
  permitted edit to an accepted ADR) and `M`'s `Context` names what it
  supersedes. This keeps the log an append-only audit trail.
- **`Consequences` names real trade-offs**, not only benefits — a consequences
  section that lists only upsides is a marketing document, not an ADR.

## Consequences

- Intent is now citable by a stable number, so review and drift-detection can
  reference `ADR-000N` rather than re-deriving intent from code.
- The append-only / supersede-not-edit rule costs a little ceremony: correcting
  a decision means writing a new file, not editing the old one. That ceremony is
  the point — it preserves the history of *why* a rule changed.
- Structure is human-reviewed here. There is deliberately no machine validator
  for ADR shape in this cut; enforcing ADR structure by CI is a later,
  separate decision.
