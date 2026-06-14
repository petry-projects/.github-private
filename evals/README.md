# `evals/` — held-out eval sets for self-improving skills

This directory holds the evaluation cases that the self-improving-skills pipeline
(epic #581, Discussion #572) uses to decide whether a proposed change to a skill
is a real improvement. Its single job is **held-out hygiene**: keeping the cases
the gate scores against out of sight of the proposer that is trying to pass them.

This directory is **data, structure, and validation only**. No scorer, model
invocation, or proposer logic lives here (consistent with #582).

## The dev/holdout split

Every skill's cases are partitioned into two splits:

```
evals/
  <skill>/
    dev/cases.jsonl       # proposer-visible
    holdout/cases.jsonl   # CODEOWNER-gated; the gate scores against this
```

- **`dev/`** — the **proposer-visible** split. Any proposer prompt or context
  (Phase 3 proposer, #587) is constructed from the **dev split only**.
- **`holdout/`** — the **held-out** split. The scorer (#583) and the
  strict-improvement gate (#586) score against the **holdout split only**. The
  proposer must never tune a skill to these specific cases.

`cases.jsonl` is [JSON Lines](https://jsonlines.org/): one JSON object per line.
Blank lines are ignored. Every case **must** carry a non-empty string `id`. The
rest of the case payload (e.g. `prompt`, `expected`, rubric fields) is owned by
the scorer story (#583); this directory's validator is deliberately agnostic to
it and only governs the split structure and `id` discipline.

`example-skill/` is a template: copy its `dev/` and `holdout/` layout when adding
a new skill's eval set.

## The no-overlap rule

**A case must never appear in both splits.** `id`s are unique within each split
*and* disjoint across the two splits (checked over their union). If the same case
lived in both, the proposer could see — and overfit to — a case the gate later
scores against, which defeats the entire held-out guarantee ("teaching to the
test").

`validate-cases.py` enforces this. Run it over the whole tree:

```bash
python3 evals/validate-cases.py            # validates evals/ (this dir)
python3 evals/validate-cases.py <root>     # validates an alternate root
```

It fails (non-zero) on malformed JSONL, a missing/empty `id`, a duplicate `id`
within a split, an `id` shared across splits, or a skill missing either split.
The validator is exercised by `tests/test_validate_cases.bats` in CI.

## De-identification requirement (decision A3)

All cases — in **both** splits — must be **de-identified** before they are
committed. Do not paste real customer data, secrets, tokens, internal hostnames,
personal names, or any other PII into a case. Cases are synthetic or redacted
reconstructions of a behavior, not raw captured transcripts. Because the `dev/`
split is proposer-visible (and the whole repo is readable by other automation),
treat every committed case as world-readable within the org.

## The hard CI immutability gate (#692)

CODEOWNERS only **requests** review — it blocks a merge only when branch
protection's "require review from code owners" is enabled, an unstated
dependency. The actual immutability guarantee is a **CI gate** that fails any
proposer-authored PR touching a held-out path, independent of CODEOWNER review.

- **Workflow:** [`.github/workflows/holdout-guard.yml`](../.github/workflows/holdout-guard.yml)
  runs on every PR (no `paths:` filter, so it is a stable required check).
- **Decision logic:** [`scripts/lib/holdout-guard.sh`](../scripts/lib/holdout-guard.sh),
  keyed on **PR author + changed paths**:
  - author is **not** the proposer identity → **pass** (humans/CODEOWNERS, and
    the dev-lead bot authoring eval *stories*, edit `evals/` freely);
  - author **is** the proposer but changes only non-`evals/` paths (e.g.
    `prompts/triage.md`) → **pass**;
  - author **is** the proposer **and** changes any `evals/` path → **fail**.
- **Proposer identity:** the proposer runs as `GITHUB_TOKEN`, whose PR author
  login is `github-actions[bot]` (the resolved default). It is intentionally
  distinct from the dev-lead bot (`donpetry-bot`), which authors the eval
  stories themselves. Override the identity list (and guarded prefixes) via the
  `HOLDOUT_PROPOSER_IDENTITIES` / `HOLDOUT_GUARDED_PREFIXES` env vars when the
  Phase-3 proposer (#587) lands with its own bot account.
- **Coverage:** [`tests/test_holdout_guard.bats`](../tests/test_holdout_guard.bats),
  wired into the `bats` job in `.github/workflows/lint.yml`.

This **complements, does not replace, CODEOWNERS**: CODEOWNERS routes review;
this gate is the immutability guarantee. Land it before the Phase-3 proposer
(#587) activates so the proposer can never self-edit its own test set even if
branch protection is misconfigured.

## Why CODEOWNER-gating the holdout is sufficient (AC1/AC4)

The held-out guarantee rests on two independent controls:

1. **Tamper protection (enforced here, plus a CI check enforces it).** `holdout/`
   is CODEOWNER-gated in [`.github/CODEOWNERS`](../.github/CODEOWNERS) with an
   explicit rule, on top of the repo-wide default, **and** the CI gate above
   (#692) hard-fails any proposer-authored change to `evals/`. The proposer runs
   as `GITHUB_TOKEN` and therefore **cannot merge** any edit to a holdout file —
   it can neither rewrite the holdout to match a weak skill nor move cases
   between splits. The reward-hacking guard from #582 (CODEOWNERS over `evals/`)
   is what this rule specialises.

2. **Context isolation (enforced by the consumer).** The proposer prompt is built
   from `dev/` only; the gate reads `holdout/` only. This is a contract the
   Phase 3 proposer (#587) and the scorer/gate (#583/#586) implement at
   prompt-/context-assembly time — the directory split is the structural boundary
   they key off.

**Residual risk and future hardening.** Because this repo is a single git tree,
control (2) is a *contract*, not a hard wall: a proposer that read raw files under
`holdout/` instead of using the sanctioned dev-only context builder could still
see them. Directory split + CODEOWNERS removes the *tampering* and *accidental
inclusion* vectors and is sufficient for the current single-repo pipeline. Making
the holdout truly **unreadable** by the proposer's checkout (a separate
access-controlled store, an encrypted/rotating holdout, or fetching the holdout
only inside the gate's isolated job) is the stronger mechanism and is left as
follow-up hardening — tracked against the proposer/gate stories rather than this
structural deliverable.
