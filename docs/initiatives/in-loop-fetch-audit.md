# In-loop data-fetch audit + frozen ET baseline (epic #1101, Story 1)

**Status:** accepted · **Issue:** #1102 · **Epic:** #1101 (in-loop-fetch refactor)

## Purpose

Catalog every LLM-initiated (**in-loop**) data fetch each agentic review tier
performs, classify each fetch as **deterministic** (preflightable — the same bytes
every time for a given PR head) or **dynamic** (must stay in-loop — the model
decides what to read based on the diff), and freeze a per-tier Effective-Tokens
(ET) baseline for the deep and audit tiers. This makes the Story 2 refactor target
**exactly** the redundant deterministic fetches, and forces every later ET claim to
be measured against an immutable before-number (`tests/fixtures/et-baseline/`)
rather than a guess.

The refactor removes the **redundant deterministic FETCH**, not the exploration
**tools**. `Bash`, `Read`, `Grep`, `Glob` stay — they are how a tier dynamically
explores the repo. What moves to a preflight is the fixed `gh pr view` metadata +
`gh pr diff` that every tier re-fetches identically today.

## Cascade shape (where the fetches happen)

Entrypoint: `scripts/review-one-pr.sh`. The cascade is
triage → (single | deep + rubber-duck → audit) → cascade-action:

- **Tier 1 — triage** (`scripts/review-one-pr.sh` ~L509–726): runs **tool-free**
  (`run_triage` uses `--disallowed-tools`, `scripts/engine.sh` ~L950). It
  **prefetches** `PR_METADATA` (`gh pr view --json <fields>,files`, L528) and
  `PR_DIFF` (`gh pr diff`, **truncated** to `_diff_limit` = 3000 lines, or 1000 for
  copilot; L549–555) and inlines them into the prompt. It then
  **`unset PR_DIFF PR_METADATA`** at L726, so nothing downstream can reuse them.
- **Agentic tiers** — launched via `run_agentic` / `run_duck`
  (`scripts/engine.sh`), each of which grants `--allowed-tools "Bash,Read,Grep,Glob"`
  (`_mcp_review_flags "Bash,Read,Grep,Glob"`, engine.sh L1053/L1489), plus opt-in
  MCP (secret-scanning, LSP) appended only when enabled:
  - single-review (L810), deep + rubber-duck (L883/L894), security-audit (L1053),
    cascade-action (L1015/L1094).

Because triage **unsets** the prefetched context and the agentic tiers each carry
`gh`, **every agentic tier re-fetches the same metadata + diff in-loop**. That
duplicate deterministic read is the initiative's target.

## Out of scope (explicitly not changed by this initiative)

- **Triage tier** — already prefetches (`PR_METADATA` + `PR_DIFF`) and runs
  tool-free. It is the *model* for the Story 2 preflight, not a target. No change.
- **`scripts/review-batch.sh` `gh` calls** — these are **shell orchestration**
  (PR enumeration / dispatch that runs *before* any agent is invoked, i.e.
  pre-agentic). They are not in-loop LLM fetches and are out of scope.
- **`cascade-action` tier** — see the per-tier table: it performs **no** `gh`
  data fetch. It reads the resolving tier's verdict JSON (`$FINAL_RESULT`) and
  composes the review body. Nothing to preflight.

## Per-tier in-loop fetch inventory

Prompts live in `prompts/`. "Fetch" = an `gh`/tool call the tier issues *itself*
during the model loop.

### Tier: deep — `prompts/deep-review.md` (engine: `claude-sonnet-4-6`)

| Fetch | Source | Class | Rationale |
|-------|--------|-------|-----------|
| `gh pr view --json <24 fields>,files` | step 3 (L64) | **deterministic** | Fixed field set for a given PR head; identical bytes every run — preflightable. |
| `gh pr diff "$PR_URL"` | step 4 (L65) | **deterministic** | The unified diff for a fixed head SHA is immutable — preflightable (**full** diff; see constraint C1). |
| Fetch linked issues | step 6 | **dynamic** | Which issues, and whether to read them, depends on `closingIssuesReferences` in the diff/metadata — model-directed. |
| `mcp__github__run_secret_scanning` (opt-in MCP) | step 5 | **dynamic** | Runs on the raw added/modified content the model selects; only present when Secret Protection is enabled. Stays in-loop. |
| `mcp__lsp__find_references` / `get_diagnostics` (opt-in MCP) | step 8 | **dynamic** | Grounds cross-file/semantic claims the model chooses to make; inherently model-directed. |
| Repo exploration via `Bash`/`Read`/`Grep`/`Glob` (e.g. duplication search, step 10) | tool grant | **dynamic** | The model decides what to read to adjudicate findings. **Stays in-loop.** |

### Tier: rubber-duck — `prompts/rubber-duck.md` (engine: cross-family, e.g. gemini/copilot)

| Fetch | Source | Class | Rationale |
|-------|--------|-------|-----------|
| `gh pr view --json <24 fields>,files` | step 2 (L35) | **deterministic** | Same as deep, but note the field list uses **`repository`** (not `headRepository,headRepositoryOwner`) — see constraint C2. |
| `gh pr diff "$PR_URL"` | step 3 (L36) | **deterministic** | Immutable for a fixed head — preflightable (full diff; C1). |
| Fetch linked issues | step 4 | **dynamic** | Model-directed, as in deep. |
| Repo exploration via `Bash`/`Read`/`Grep`/`Glob` | tool grant | **dynamic** | Adversarial exploration is the tier's whole value. **Stays in-loop.** |

### Tier: security-audit — `prompts/security-audit.md` (engine: `claude-opus-4-7`)

| Fetch | Source | Class | Rationale |
|-------|--------|-------|-----------|
| `gh pr view --json <24 fields>,files` | step 2 (L32) | **deterministic** | Same fixed field set as deep — preflightable. |
| `gh pr diff "$PR_URL"` | step 3 (L33) | **deterministic** | Immutable for a fixed head — preflightable (full diff; C1). |
| Fetch linked issues | step 4 | **dynamic** | Model-directed. |
| `gh api` for CONTRIBUTING.md / AGENTS.md / CODEOWNERS | step 5 (L35) | **dynamic** | A **standards lookup** against repo files the model selects, not fixed PR data. Stays in-loop. |
| `mcp__lsp__*` (opt-in MCP) | step 6 | **dynamic** | Model-directed finding verification. |
| Repo exploration via `Bash`/`Read`/`Grep`/`Glob` | tool grant | **dynamic** | Paranoid trace of the flagged areas. **Stays in-loop.** |

### Tier: single-review — `prompts/single-review.md` (engine: `ENGINE_SINGLE_MODEL`)

| Fetch | Source | Class | Rationale |
|-------|--------|-------|-----------|
| `gh pr view --json <24 fields>,files` | context step 1 (L38) | **deterministic** | Fixed field set — preflightable. |
| `gh pr diff "$PR_URL"` | context step 2 (L41) | **deterministic** | Immutable for a fixed head — preflightable (full diff; C1). |
| `gh api .../compare/$PRIOR_REVIEW_SHA...$PR_HEAD_SHA` | incremental mode (L44–45) | **dynamic** | The since-last-review delta depends on the *prior review SHA* (review-cycle state), not just the current head — not a fixed preflight input. Stays in-loop. |
| `mcp__github__run_secret_scanning` (opt-in MCP) | step 3 | **dynamic** | Same as deep. |
| Fetch linked issues / `statusCheckRollup` inspection | steps 4–5 | **dynamic** | Model-directed. |
| Repo exploration via `Bash`/`Read`/`Grep`/`Glob` | tool grant | **dynamic** | Stays in-loop. |

### Tier: cascade-action — `prompts/cascade-action.md` (engine: `ENGINE_ACTION_MODEL`)

| Fetch | Source | Class | Rationale |
|-------|--------|-------|-----------|
| *(none)* | — | — | Reads `$FINAL_RESULT` (the resolving tier's verdict JSON) and composes the review body. **No `gh` data fetch; nothing to preflight.** |

## Exact metadata field set + diff read today (AC #3)

The `gh pr view --json` field list is **identical across deep / audit / single**
(24 metadata fields + `files`); rubber-duck differs only in the repository field. Verifying
these here proves the Story 2 preflight can be a **superset** of every tier's need.

**deep / security-audit / single-review** (`deep-review.md` L64, `security-audit.md`
L32, `single-review.md` L38):

```
number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,url,
headRepository,headRepositoryOwner,labels,reviewDecision,mergeable,
mergeStateStatus,statusCheckRollup,reviewRequests,reviews,comments,commits,
closingIssuesReferences,additions,deletions,changedFiles,files
```

**rubber-duck** (`rubber-duck.md` L35): same list except it requests
**`repository`** in place of `headRepository,headRepositoryOwner`.

**Diff:** every tier reads `gh pr diff "$PR_URL"` (the full unified diff for the
head SHA).

### Superset check vs. the triage prefetch

Triage prefetches `_meta_fields` + `files` (`review-one-pr.sh` L524/L528):

```
number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,url,labels,
reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviewRequests,
closingIssuesReferences,additions,deletions,changedFiles   (+ files, SIMPLIFIED)
```

The agentic superset the Story 2 preflight must therefore add on top of the triage
set is:

- `reviews`, `comments`, `commits` — requested by the agentic tiers, **not** by triage.
- `headRepository`, `headRepositoryOwner` (deep/audit/single) **and** `repository`
  (rubber-duck) — triage requests none of these.
- The **full, unsimplified** `files` list — triage rewrites `files` to
  `{path,status,additions,deletions}` (L529–531) to save tokens; the agentic tiers
  expect the full objects.

## Constraints for Story 2 (the preflight)

- **C1 — the diff-truncation trap (AC #5).** The triage prefetch **truncates**
  `PR_DIFF` to `_diff_limit` (3000 lines; 1000 for copilot) via
  `head -"$_diff_limit"` (`review-one-pr.sh` L549–555) **and then `unset`s
  `PR_DIFF`/`PR_METADATA`** at L726. The Story 2 agentic preflight therefore
  **must fetch the FULL `gh pr diff`** — it must **not** reuse the truncated triage
  copy, or a large PR would silently review only its first 3000 diff lines. The
  preflight is a *new, full* fetch, not a handoff of triage's truncated buffer.
- **C2 — repository-field divergence.** The preflight metadata must include
  **both** `headRepository,headRepositoryOwner` **and** `repository` (or normalize
  between them) so it is a superset of both the deep/audit/single field list and
  the rubber-duck one.
- **C3 — keep the exploration tools.** `Bash,Read,Grep,Glob` (and opt-in MCP)
  remain granted. The preflight only removes the redundant deterministic
  metadata+diff re-fetch; it does not restrict dynamic exploration.
- **C4 — 300-file / HTTP-406 fallback.** `gh pr diff` is hard-capped at 300 changed
  files (HTTP 406). The triage prefetch already assembles a per-file REST fallback
  (`review-one-pr.sh` L564–587, see AGENTS.md "Oversized PRs"). The Story 2 full-diff
  preflight must preserve that same fallback so oversized PRs still get a (partial)
  diff rather than a fatal error.

## Frozen ET baseline (AC #4)

- **Artifact:** `tests/fixtures/et-baseline/pre-change-baseline-2026-06.jsonl`
  (provenance: `tests/fixtures/et-baseline/PROVENANCE.md`).
- **Metric:** Effective Tokens, `ET = m × (1.0×I + 0.1×C + 4.0×O)`, precomputed per
  call by `scripts/lib/token-metrics.sh` and aggregated by `scripts/token_report.sh`
  (Token Cost Observatory, #464). No new metric is introduced.
- **Sample:** `run_id = baseline-2026-06`, dated window 2026-06-15 → 2026-06-17 (UTC),
  deep + audit tiers only (the two tiers whose redundant in-loop fetch is removed).
- **Frozen figures Story 6 compares against:**

  | Tier  | Model             | Records | Total ET |
  |-------|-------------------|---------|----------|
  | deep  | claude-sonnet-4-6 | 3       | 170,400  |
  | audit | claude-opus-4-7   | 3       | 378,500  |

- **Immutability:** each record is priced at the multiplier in effect on its **own
  date** (`model-pricing.tsv` selection rule), so appending a future price row
  cannot move the numbers. The fixture is owner-locked in `.github/CODEOWNERS`,
  protected from silent deletion by `test-deletion-guard.yml`, and pinned by
  `tests/test_et_baseline_regression.bats` — which recomputes every `et` with the
  same `calculate_et`/`et_multiplier_for` tooling and pins the per-tier count and
  total, so any change to the frozen data fails CI as an explicit, reviewable diff.

## References

- `scripts/review-one-pr.sh` — tier-1 prefetch (L509–726), tier launches (L810, L883/894, L1053, L1015/1094)
- `scripts/engine.sh` — `run_triage` (L929), `run_agentic` (L1015), `run_duck` (L1471), tool grants (L1053/L1489)
- `prompts/{deep-review,rubber-duck,security-audit,single-review,cascade-action}.md`
- `scripts/lib/token-metrics.sh` — `emit_token_record`, `calculate_et`, ET formula
- `scripts/token_report.sh` — per workflow/tier/model aggregation
- `AGENTS.md` — "Cost reporting", "Oversized PRs (> 300 changed files)"
- `tests/fixtures/et-baseline/` — frozen baseline + provenance
