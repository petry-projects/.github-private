# Agent versioning & release channels

Status: **active** (Phase 1 of the [Safe Release Strategy](../initiatives/agentic-release-strategy.md)
initiative, epic #495). Implements issue #496.

This defines how the **dev-lead** and **pr-review** agents are versioned and how callers select a
version. It is the foundation the rest of the initiative (rings, promotion, rollback) builds on.

## What is versioned

A "release" of an agent is the reusable workflow **plus the scripts it executes** — they move
together, so a version is a single repo commit that contains a known-good combination:

| Agent | Reusable workflow | Key scripts (non-exhaustive) |
|---|---|---|
| `pr-review` | `.github/workflows/pr-review.yml` | `scripts/review-one-pr.sh`, `scripts/review-batch.sh`, `scripts/post-pr-review.sh`, `scripts/engine.sh`, `scripts/lib/*` |
| `dev-lead` | `.github/workflows/dev-lead-reusable.yml` | `scripts/dev-lead-*.sh`, `scripts/engine.sh`, `scripts/lib/*` |
| `feature-ideation` | `petry-projects/.github` → `.github/workflows/feature-ideation-reusable.yml` (**cross-repo**) | reusable-owned (lives in the public repo; this repo holds only the thin caller `.github/workflows/feature-ideation.yml`) |

`pr-review` and `dev-lead` both live in this repo, so a release tag points at a whole-repo commit; the
tag *name* scopes it to one agent so the two can be released and promoted independently.

`feature-ideation` is the exception: its reusable lives in **`petry-projects/.github`** (this repo holds
only the thin caller stub), so a `feature-ideation` "release" is a commit on that public repo, and its
release/channel tags must be cut **against `petry-projects/.github`, not this repo's `origin`**. See
[Cross-repo: feature-ideation](#cross-repo-feature-ideation) below.

## Tag scheme

Two kinds of tag, per agent:

| Kind | Format | Mutable? | Purpose |
|---|---|---|---|
| **Immutable release** | `<agent>/vMAJOR.MINOR.PATCH` | No (annotated, never moved) | Audit trail + rollback target |
| **Channel** | `<agent>/<channel>` | Yes (moved on promotion) | What callers pin to |

Channels (Phase 1 defines `stable`; Phase 2 adds `next` and per-ring channels):

- `<agent>/stable` — the production channel (blue). Callers in production pin here.
- `<agent>/next` — the candidate channel (green). *(Phase 2, #499.)*
- `<agent>/ring1`, … — per-ring channels for staged promotion. *(Phase 2, #499/#500.)*

Examples: `pr-review/v1.0.0`, `pr-review/stable`, `dev-lead/v1.0.0`, `dev-lead/stable`.

`feature-ideation` uses the full per-ring channel set — `{next, ring0, ring1, stable}` — so it can be
promoted through the same canary → ring → stable model. Its tags follow the identical name scheme
(`feature-ideation/vX.Y.Z`, `feature-ideation/next`, `feature-ideation/ring0`,
`feature-ideation/ring1`, `feature-ideation/stable`) but are cut against `petry-projects/.github`
(see [Cross-repo: feature-ideation](#cross-repo-feature-ideation)).

### Semantic versioning

- **MAJOR** — breaking change to the caller contract (workflow inputs/secrets, required permissions,
  the merge-gate behavior a consumer relies on).
- **MINOR** — backward-compatible capability (new safety check, new optional input).
- **PATCH** — backward-compatible fix (bug fix, prompt tweak, resilience hardening).

## How callers select a version (no per-caller churn)

GitHub does **not** allow an expression in a `uses:` ref, so version selection is **a moving channel
tag**, not a variable. Each caller pins **once** to a channel and is never edited again; promotion is a
central move of the channel tag (see the initiative doc §5.1):

```yaml
# A consumer / self-host caller pins once to the per-agent channel:
uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/stable
uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable
```

> Shorthand: the initiative doc writes `@stable`; the concrete tag is the **per-agent** channel
> (`pr-review/stable`, `dev-lead/stable`) so the agents promote independently.

## The v1.0.0 baseline

The first release was cut from the production `main` at the time of issue #496:

- `pr-review/v1.0.0`, `dev-lead/v1.0.0` — immutable baselines.
- `pr-review/stable`, `dev-lead/stable` — channels pointing at v1.0.0.

`v1.0.0` is **"what is in production today,"** the current rollback floor — *not* a certified-perfect
version. The health-gated promotion added in Phase 2 (#501) is what makes *future* promotions to
`stable` genuinely validated before they become production.

## Cross-repo: feature-ideation

Everything above assumes the agent's reusable workflow lives **in this repo**, so a release tag is a
whole-repo commit here and tags are cut against this repo's `origin`. That holds for `pr-review` and
`dev-lead`. It does **not** hold for `feature-ideation`:

- `feature-ideation`'s reusable lives in **`petry-projects/.github`**
  (`.github/workflows/feature-ideation-reusable.yml`); this repo carries only the thin caller stub
  `.github/workflows/feature-ideation.yml`.
- Therefore a `feature-ideation` release is a commit on **`petry-projects/.github`**, and its
  `feature-ideation/vX.Y.Z` immutable + `feature-ideation/<channel>` tags must be cut **against that
  repo**, not this repo's `origin`.
- `scripts/cut-release.sh` already recognizes `feature-ideation` and formats its tag names, and its
  `--dry-run` prints the intended immutable + channel tags. **Live cross-repo pushes are not wired
  yet** — the push target mechanism (a `--repo`/remote argument vs. dispatching against the public
  repo) is an open question reserved for a human decision, so the script refuses a non-dry-run cut for
  `feature-ideation` (see the `TODO(#872)` in `cut-release.sh`). Use `--dry-run` to preview tag names
  until the target is decided.
- Because `feature-ideation`'s channel tags live on `petry-projects/.github`, the protective ruleset
  that bounds them (the mutable-ref exception) is created **there**, not on this repo — see
  [`AGENTS.md`](../../AGENTS.md) "Release channel tags & the mutable-ref exception".

## Cutting / moving tags

Use `scripts/cut-release.sh` (tested in `tests/test_cut_release.bats`) rather than ad-hoc `git tag`:

```bash
# Cut an immutable release for an agent at a ref (default ref: origin/main):
scripts/cut-release.sh pr-review 1.1.0 --push

# Cut a release AND advance that agent's stable channel to it (a promotion):
scripts/cut-release.sh pr-review 1.1.0 --channel stable --push

# Preview without touching anything:
scripts/cut-release.sh pr-review 1.1.0 --channel stable --dry-run

# feature-ideation: dry-run only for now (cross-repo target unresolved — see above).
# Prints feature-ideation/v1.4.0 and feature-ideation/ring0 without mutating anything:
scripts/cut-release.sh feature-ideation 1.4.0 --channel ring0 --dry-run
```

The promote/rollback **runbook** (when to move `stable`, how to roll back, verify, gotchas) lives in
[`runbook.md`](./runbook.md). The automated, health-gated promotion workflow is issue #501; tag-protection
so only the promotion workflow may move a channel tag is issue #505.
