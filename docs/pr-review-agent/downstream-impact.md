# Downstream-Impact Pass (Operator Guide)

The downstream-impact pass annotates a PR review with the org repos ("consumers")
that pin the shared surface a PR changes — a reusable workflow, a `scripts/lib/*.sh`
helper, or a `prompts/*` file. It answers: *"if this change is wrong, which
downstream repos does it break?"*

It ships **default-off**. With the flag off it is a strict no-op: zero extra `gh`
calls and a byte-identical triage prompt / verdict (epic #748, Story 5 / #753).

## What the pass does

When enabled, for each reviewed PR `scripts/review-one-pr.sh`:

1. **Maps** the PR's changed files to impacted shared surfaces and the consumers
   that pin them. This is the *pure* mapper (`compute_downstream_impact` in
   `scripts/lib/downstream-impact.sh`) — bash + jq over the consumer manifest,
   **no network**. Matching is single-hop and exact-path (issue #653):
   - a changed reusable-workflow path a consumer pins exactly → a **direct** surface;
   - a changed `scripts/lib/*.sh` / `prompts/*` path listed in a reusable's
     `surface_sources` → that **reusable** surface → its consumers.
2. **Fetches** each impacted consumer's referencing workflow file(s) via `gh`
   (`assemble_downstream_impact`) and writes a human-readable
   `DOWNSTREAM_IMPACT` block to `/tmp/cascade/downstream-impact.txt`
   (path exported as `DOWNSTREAM_IMPACT_FILE`).
3. **Inlines** that block into the triage prompt (triage has no tools, so it must
   be inlined as text) and surfaces a **Downstream impact** section in the posted
   verdict.

The signal is **informational** — it is annotated for the reviewer, not an
auto-escalation trigger (it is weighed the same way advisory-bot findings are).

## How to enable it

Set the feature flag to the literal string `true`:

```
DOWNSTREAM_IMPACT_ENABLED=true
```

Anything other than `true` (unset, `false`, empty) leaves the pass off. Set it as
a repository/environment variable consumed by the pr-review workflow, or export it
when running `scripts/review-one-pr.sh` manually.

## Token scope it needs

The fetch step reads workflow files in **other org repos**, so it needs a
cross-repo read token. It reuses the existing pr-review machine-user PAT surfaced
as `GH_PAT` (preferred; falls back to whatever `GH_TOKEN`/`gh` auth is present) —
**no new secret is introduced** (issue #751). The required scope is the same
cross-repo `contents: read` the pr-review workflows already hold (#653):

- Fine-grained PAT: **Contents → Read-only** on the consumer repos (org-wide).
- A private/unreadable consumer (or a missing scope) degrades to an explicit
  `unreadable` note for that entry — it never fails the review.

## Per-PR fetch and size caps

The pass is bounded so a large consumer set cannot blow up cost or the prompt:

| Cap | Env var | Default | Effect |
|-----|---------|---------|--------|
| Consumer repos fetched per PR | `DOWNSTREAM_IMPACT_MAX_REPOS` | `10` | Only the first N exact-matched consumers (sorted by repo) are fetched; the rest are noted as "not fetched". |
| Assembled block size | `DOWNSTREAM_IMPACT_MAX_BYTES` | `8000` | The block is truncated to N bytes (mirrors the 8 KB advisory-feedback cap). |

Only exact-matched consumers are fetched — never the whole org. With no impacted
surfaces, the block is the literal `(none)` and **zero** fetches are performed.

## Refreshing the consumer manifest

The mapper reads `scripts/lib/consumer-manifest.json`. Its `consumers` map is
**empirically generated** (not hand-curated) by enumerating the org and detecting
which provider reusable workflows each repo pins. Refresh it when consumers are
added/removed or when they change which reusables they pin:

```bash
# Dry-run prints the regenerated manifest; review the diff before writing.
GH_TOKEN="$GH_PAT" scripts/refresh-consumer-manifest.sh --dry-run

# Write it in place, then commit the diff.
GH_TOKEN="$GH_PAT" scripts/refresh-consumer-manifest.sh
```

The script refreshes only `consumers`; the `providers` list and the hand-maintained
`surface_sources` map are preserved verbatim. Output is deterministic (sorted keys,
consumers sorted by repo, refs sorted + de-duplicated) for clean diffs. Edit
`surface_sources` by hand when a reusable starts (or stops) sourcing a
`scripts/lib/*.sh` or `prompts/*` file. See `scripts/refresh-consumer-manifest.sh`
(Story 1, #749) for details.

## Regression guard

The mapping **logic** is pinned by a golden-fixture regression guard,
`tests/test_downstream_impact_regression.bats`, against a frozen manifest and
expected outputs under `tests/fixtures/downstream-impact/golden/`. The golden
manifest is intentionally independent of the live `consumer-manifest.json` so a
legitimate manifest refresh does not break the guard — only a change to the
mapper's output does. Changing the expected output requires an explicit,
reviewable fixture update (visible in the diff), preventing silent drift. The
guard runs on every PR via the `bats` job in `.github/workflows/lint.yml`.
