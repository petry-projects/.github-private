# Review artifact contract & rubric registry

This directory holds the **artifact contract** and **rubric registry** for the
org's review automation (issue #611, epic #610).

The goal: review *logic* (engine routing, cascade orchestration, verdict
posting) should be reusable across different *things to review* — PR diffs
today, plans and skills later — without forking the reviewer three ways. The
contract names the small, stable interface between "what is being reviewed" and
"how it gets reviewed"; the registry is the lookup table that binds them.

The registry is an input-adapter layer **above** `engine.sh`. It does **not**
change engine/model routing — it only decides which rubric and output channel
apply to a given artifact. Phase 1 registers a single type, `pr_diff`, which
resolves to today's PR-review behavior with no change.

## The artifact contract

Every reviewable thing is described by four fields:

| Field | Meaning | Allowed values |
| --- | --- | --- |
| `artifact_type` | What kind of thing is being reviewed. The registry key. | A type registered in the manifest. Phase 1: `pr_diff` only. |
| `content_ref` | A pointer to the concrete content to review (not the content itself). | Opaque to the registry; interpreted by the output channel / caller. For `pr_diff` it is a PR URL (as passed to `review-one-pr.sh`). |
| `rubric` | The standard the content is scored against — an ordered cascade of prompt files, applied in sequence. | Resolved from the manifest. For `pr_diff`: `prompts/triage.md` → `prompts/deep-review.md` → `prompts/synthesize.md`. |
| `output_channel` | How the verdict is delivered. | Resolved from the manifest. For `pr_diff`: `scripts/post-pr-review.sh` (GitHub inline review comments + an approve/escalate review). |

`artifact_type` and `content_ref` are supplied by the caller (the input). The
registry resolves `rubric` and `output_channel` from the `artifact_type`.

## The registry manifest

[`review-registry.tsv`](./review-registry.tsv) is the versioned source of truth.
Data, not code — register a new artifact_type by adding a row; never fork the
reviewer.

- A `# schema_version: N` comment carries the manifest version.
- Each data row is tab-separated: `artifact_type<TAB>rubric<TAB>output_channel`.
  - `rubric` is an ordered, comma-separated list of repo-root-relative prompt files.
  - `output_channel` is a repo-root-relative script.
- Lines beginning with `#` (after optional whitespace) and blank lines are ignored.

## The lookup helper

[`review-registry.sh`](./review-registry.sh) is sourced (`#!/usr/bin/env bash`,
`set -euo pipefail`) and exposes:

```bash
source scripts/lib/review-registry.sh

review_registry_version                         # -> 1
review_registry_types                           # -> pr_diff
review_registry_lookup pr_diff rubric           # -> prompts/triage.md,prompts/deep-review.md,prompts/synthesize.md
review_registry_lookup pr_diff output_channel   # -> scripts/post-pr-review.sh
```

`review_registry_lookup` returns `1` for an unknown `artifact_type` and `2` for
a missing or unknown field.

Override `REVIEW_REGISTRY_MANIFEST` to point the helper at a different manifest
(used by tests).

## Ownership & tests

The registry and helper are covered by the repo's global CODEOWNERS rule
(`* @petry-projects/org-leads` in `.github/CODEOWNERS`), so changes here are
gated by default. Unit tests live in
[`tests/test_review_registry.bats`](../../tests/test_review_registry.bats).
