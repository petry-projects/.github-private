# Third-Party Reviewer Scorecard — Weekly Report

Org-wide, **deterministic** visibility into the agentic third-party code reviewers that
participate in PR review across `petry-projects` — GitHub Copilot, Gemini Code Assist,
Codex, CodeRabbit, and SonarCloud. Every figure is computed with `jq`/`awk` from GitHub's
own review data. **No LLM is involved** in this pipeline: a narrative / quality-scoring
layer is a deliberately separate, human-approved add-on (see [Roadmap](#roadmap-v2--llm-optional-human-approved)).

## The problem it solves

We rely on several external reviewer bots, but had no measured view of how each one
actually performs: Does it show up? How fast? Does it approve or ask for changes? Is it
being rate-limited? Are its comments acted on? Because the bots run as **org-level GitHub
Apps** that review PRs in every product repo, a single-repo view sees only a sliver. This
report sweeps **all non-archived repos** and rolls the answers into one weekly scorecard,
matching the delivery pattern of the [Token Cost Observatory](./token-report.md).

## Reviewers tracked

Identity comes from each bot's GraphQL App **login** — the single source of truth is the
advisory-review gate (`scripts/lib/advisory-review-gate.sh`), so this report can never
drift from the approval gate's notion of who these bots are.

| Reviewer | GraphQL login |
|---|---|
| GitHub Copilot | `copilot-pull-request-reviewer` |
| Gemini Code Assist | `gemini-code-assist` |
| Codex | `chatgpt-codex-connector` |
| CodeRabbit | `coderabbitai` |
| SonarCloud | `sonarqubecloud` |

The org's own Claude reviewer (`donpetry-bot`) is intentionally **out of scope** here — its
cost lives in the [Token Cost Observatory](./token-report.md); this report is about the
external vendors.

## Data source: one batched GraphQL query per repo

For each repo we paginate PRs newest-first and pull, in a **single round-trip per page**,
each PR's `reviews`, `reviewThreads` (with `isResolved` / `isOutdated` and reaction
counts), and issue `comments`. Pagination stops as soon as a page's PRs predate the
lookback window (PRs are ordered by `UPDATED_AT` descending), so we never walk a repo's
entire history. This is far fewer API calls than per-PR REST fetches.

Each PR node is normalized (pure `jq`) into two record kinds:

- `{kind:"pr", …}` — one per PR (the eligible-PR **denominator**).
- `{kind:"bot_pr", …}` — one per tracked bot that touched the PR, carrying its
  `real_responses` / `refusals` split (a rate-limit-only touch is a refusal), latency to
  first real response, verdict counts, inline-comment count, thread resolution, and reactions.

Human authors and untracked bots are dropped at normalization time.

## Metrics

Everything is deterministic. The headline is a **three-bucket partition of the eligible
(non-draft) PRs, per reviewer**: every eligible PR is exactly one of Reviewed, Rate-limited,
or No response for a given bot, so the three always sum to the eligible-PR count. This makes
"did the reviewer actually do its job?" legible at a glance and separates *refused* work
(out-of-quota) from *absent* work (never showed up).

| Metric | Definition |
|---|---|
| **Reviewed** | PRs where the bot delivered a real review or comment. A PR still counts as Reviewed if the bot *also* posted a rate-limit notice — only the real response matters. |
| **Rate-limited** | PRs where the bot's **sole** action was to decline (out-of-quota / rate-limit notice, detected by body text via the shared gate pattern). It refused to review. |
| **No response** | Eligible PRs the bot never appeared on. `= eligible − Reviewed − Rate-limited`. |
| **✅ / 🔄** | APPROVED / CHANGES_REQUESTED review counts. A rate-limit notice is never counted as a review. |
| **Latency p50 / p95** | Seconds from PR creation to the bot's first **real** response (refusals excluded, so quota notices don't pollute the percentiles). Targets the "review arrived after auto-approval" failure mode (PR #453). |
| **Coverage overlap** | PRs reviewed by ≥2 bots — a redundancy vs specialization signal. |
| **Trend** | Week-over-week Δ (▲/▼) on Reviewed and Rate-limited vs last week's snapshot. Arrows are directional only. |

Thread-resolution and reaction counts are still computed and stored in the snapshot for
downstream use, but are kept out of the headline table to keep it legible.

### Week-over-week deltas

The report has no external time-series store. Instead each run writes a compact per-bot
**snapshot** (`reviewer-report-state.json`) which the workflow uploads as an artifact; the
next run fetches the most recent prior snapshot via the GitHub API and diffs against it.
First-ever runs (or an expired artifact) simply omit the deltas — never an error.

## Known gaps (stated in every report)

- **Cost is not measured.** These reviewers are external SaaS GitHub Apps and emit no
  token-usage artifacts, so per-review `$` cost is not observable from our side. For our
  own Claude reviewer's spend, see the [Token Cost Observatory](./token-report.md).
- **Comment usefulness / false-positive rate** requires judgment and is intentionally out
  of this deterministic report (see roadmap).
- **Latency baseline** is PR-creation time in v1; a refinement to last-human-push is
  tracked for v2.

## Roadmap (v2 — LLM-optional, human-approved)

The following need model judgment and are therefore **out of the deterministic pipeline**.
They would run only behind an explicit, human-triggered `workflow_dispatch` opt-in — never
unattended:

- Comment usefulness / true-positive vs noise scoring per reviewer.
- Semantic de-duplication of findings across reviewers (who found it first / uniquely).
- Finding categorization (bug / security / style / perf).
- A narrative "what changed and why it matters" synthesis with recommendations.

## Delivery

| Channel | Cadence | Where |
|---|---|---|
| **Tracking issue comment** | Weekly (Mon 09:53 UTC) | A single pinned issue in `.github-private` labelled `reviewer-report`; each run adds a comment. |
| **Step Summary** | Weekly | Actions run summary of `reviewer-report.yml`. |

Scheduled one hour after the token report (Mon 08:00 UTC) to avoid contending for the same
cross-repo token budget.

## Usage

Runs automatically every Monday. To trigger manually:

```bash
gh workflow run reviewer-report.yml \
  --repo petry-projects/.github-private \
  --field org=petry-projects \
  --field lookback_days=7
```

To generate the report locally (requires a token with org-wide repo read):

```bash
ORG=petry-projects LOOKBACK_DAYS=7 GH_TOKEN="$(gh auth token)" \
  bash scripts/reviewer_report.sh
```

## Architecture

| File | Role |
|---|---|
| `scripts/lib/advisory-review-gate.sh` | Single source of truth for bot logins + rate-limit body patterns (reused, not forked). |
| `scripts/reviewer_report.sh` | Org-wide GraphQL collection (`main` / `collect_org_reviews`) + pure normalization, aggregation, and rendering (`aggregate_snapshot`, `render_reviewer_report`). |
| `tests/reviewer_report.bats` | Unit tests for the pure normalize / aggregate / render path (no network). |
| `.github/workflows/reviewer-report.yml` | Weekly cron → snapshot upload + tracking-issue comment. |

## Environment variables (script)

| Variable | Description |
|---|---|
| `ORG` | Org to scan (default `petry-projects`). All non-archived repos discovered automatically. |
| `LOOKBACK_DAYS` | Rolling window of PR activity to include (default `7`). |
| `GH_TOKEN` | PAT with repo read across the org — PRs + reviews are per-repo. Uses `GH_PAT_WORKFLOWS` in CI. |
| `REVIEWER_REPORT_OUT` | Optional path to also write the report to (used by the workflow to post the issue comment). |
| `REVIEWER_SNAPSHOT_OUT` | Optional path to write this week's per-bot snapshot (uploaded as the WoW artifact). |
| `REVIEWER_PREV_SNAPSHOT` | Optional path to last week's snapshot for deltas; `main()` fetches it automatically in CI. |
| `GH_OP_TIMEOUT` / `COLLECT_CONCURRENCY` / `MAX_PR_PAGES` | Per-call timeout (s), concurrent per-repo sweeps, and PR-page cap per repo. |

## Known limitations

- **GraphQL login form**: bot logins are matched without the `[bot]` suffix (the GraphQL
  form). If a bot ever posts under a different identity, add it to the shared registry.
- **Latency denominator**: PRs opened as drafts and later marked ready use creation time
  as the latency baseline in v1, which can overstate latency for long-draft PRs.
- **Per-repo pagination**: bounded by `MAX_PR_PAGES` (default 20 × 25 PRs). A repo with
  more in-window PRs than that cap would be truncated; the cap is generous for this org.
