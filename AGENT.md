# PR Review Agent

A scheduled GitHub Action that reviews open PRs on don-petry's behalf.
Runs hourly, classifies risk, auto-approves low/medium-risk PRs that pass all
quality gates, and escalates high-risk or gated PRs for human review.

Supports two LLM engines via the `REVIEW_ENGINE` repo variable: **Claude** (default)
and **Copilot**.

## How it works

1. **Cron** — `.github/workflows/pr-review.yml` runs at `:07` every hour
   (and on `workflow_dispatch`).
2. **Enumerate** — `scripts/list-prs.sh` queries GitHub for open PRs where
   `@me` is the author OR a requested reviewer, across every repo the PAT can
   see. Output: one URL per line.
3. **Per-PR review** — `scripts/review-one-pr.sh` runs a cascading review
   where each tier only fires if the previous one flagged concerns:

   ```
   Tier 1: Triage (~15s, no tools, pre-fetched context)
     └─ clean? → single confirmation → approve + auto-merge
     └─ concerns? ↓
   Tier 2: Deep review (~2 min, full agentic)
     └─ clean? → approve + auto-merge
     └─ HIGH risk? ↓
   Tier 3: Security audit (~3 min, full agentic)
     └─ final decision → approve or escalate
   ```

   ### Engine model mapping

   | Tier | Claude engine | Copilot engine |
   |---|---|---|
   | Triage | Haiku 4.5 | GPT-5-mini |
   | Deep review | Sonnet 4.6 | GPT-5.2 |
   | Security audit | Opus 4.6 | GPT-5.4 |
   | Action / single review | Sonnet 4.6 / Opus 4.6 | GPT-5.2 / GPT-5.4 |

   **Cost profile:**
   - ~80% of PRs: triage + single confirm (2 calls, ~30s)
   - ~15% of PRs: + deep review (3 calls, ~2.5 min)
   - ~5% of PRs: + security audit (4 calls, ~5.5 min)

4. **Post-review actions** — after the review is posted, the action tier takes
   additional actions depending on the decision:
   - **If approved:** enables auto-merge (`gh pr merge --auto --squash`),
     rebases the branch if behind base, and removes the `needs-human-review`
     label. GitHub merges automatically once all required checks pass.
   - **If escalated + AI delegation enabled:** posts a follow-up comment
     with specific fix instructions. An AI agent watches for these comments,
     pushes fixes → next cron tick detects new SHA → cascade re-reviews →
     approve + auto-merge when clean. This creates an autonomous fix loop.
   - **If escalated + no delegation (or max cycles reached):** labels
     `needs-human-review` and re-requests don-petry as reviewer.
   - **Cycle guard:** after `MAX_REVIEW_CYCLES` (default 3) rounds of AI
     delegation without resolution, the agent stops delegating and escalates
     to human to prevent infinite loops.

5. **Idempotency + iterative review cycles** — every posted review starts with
   an HTML marker on line 1:

   ```
   <!-- pr-review-agent v1 sha=<full-commit-sha> decision=... risk=... -->
   ```

   Before invoking the cascade, `scripts/review-one-pr.sh` fetches the PR's
   current head SHA and scans existing reviews/comments for the marker. If a
   marker matching the current head SHA exists, the script skips the PR
   without spending tokens. If a marker exists for an older SHA, the script
   knows the PR has new commits since the last review and runs the cascade
   again — handling iterative review cycles cleanly.

## Setup

### 1. Create a fine-grained PAT

Go to <https://github.com/settings/personal-access-tokens/new>. Settings:

- **Resource owner:** `don-petry`
- **Repository access:** "All repositories" (or pick the ones you want the
  agent to act on).
- **Repository permissions:**
  - Contents: **Read**
  - Issues: **Read and write** (needed to create labels and add `needs-human-review`)
  - Metadata: **Read** (auto)
  - Pull requests: **Read and write**
- **Expiration:** as long as you're comfortable with. Set a calendar reminder
  to rotate.

Save the token, then add it as a repo secret on `don-petry/self`:

```
gh secret set GH_PAT --repo don-petry/self
```

### 2. Add your LLM engine auth token

#### Claude engine (default)

Routes the agent's usage through your Claude Max plan. Generate the token:

```
claude setup-token
```

Store as a repo secret:

```
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo don-petry/self
```

#### Copilot engine

Create a GitHub PAT with Copilot scope. Store as a repo secret:

```
gh secret set COPILOT_GITHUB_TOKEN --repo don-petry/self
```

### 3. Choose your engine

```
# Use Copilot (GPT models):
gh variable set REVIEW_ENGINE --body copilot --repo don-petry/self

# Use Claude (default — no variable needed, or set explicitly):
gh variable set REVIEW_ENGINE --body claude --repo don-petry/self
```

### 4. Test with a dry run

```
gh workflow run pr-review.yml --repo don-petry/self -f dry_run=true
gh run watch --repo don-petry/self
```

To review a single PR ad-hoc:

```
gh workflow run pr-review.yml --repo don-petry/self \
  -f pr_url=https://github.com/owner/repo/pull/123 \
  -f dry_run=true
```

## Going live

The cron defaults to **dry-run mode** — it gathers context and prints decisions
but never posts reviews, comments, labels, or reviewer requests. To enable
live mode:

```
gh variable set LIVE_MODE --body true --repo don-petry/self
```

To go back to dry-run:

```
gh variable delete LIVE_MODE --repo don-petry/self
```

A specific run can always be forced either way via the `dry_run` workflow input:

```
gh workflow run pr-review.yml --repo don-petry/self -f dry_run=false
```

## Tuning

- **Review engine** — `REVIEW_ENGINE` repo variable: `claude` (default) or
  `copilot`. Controls which CLI and model family is used.
- **Risk rules** — edit `prompts/shared.md` (taxonomy), or the per-tier
  prompts (`prompts/deep-review.md`, `prompts/security-audit.md`).
- **Cron frequency** — change the `cron:` line in the workflow file.
- **Scope** — edit `scripts/list-prs.sh` to add/remove queries (e.g. to include
  PRs from a specific org, or to exclude certain repos).
- **AI delegation** — set `DELEGATION_ORGS` to a comma-separated list of
  GitHub orgs where AI-assisted fix delegation is enabled:
  `gh variable set DELEGATION_ORGS --body "petry-projects,don-petry" --repo don-petry/self`
- **Max review cycles** — how many times the agent delegates to AI before
  escalating to human (default 3):
  `gh variable set MAX_REVIEW_CYCLES --body 5 --repo don-petry/self`
- **Models** — change model IDs in `scripts/engine.sh`. The cascade tiers
  map to: triage → deep → audit → action.
- **Max PRs per run** — defaults to 10 per cron tick to stay within the 60-min
  job timeout. Override:
  `gh variable set MAX_PRS --body 15 --repo don-petry/self`

## Architecture

```
scripts/engine.sh         ← LLM abstraction (claude/copilot dispatch)
scripts/review-one-pr.sh  ← Cascade orchestrator (sources engine.sh)
scripts/list-prs.sh       ← PR enumeration

prompts/triage.md         ← Tier 1: fast risk triage (no tools)
prompts/deep-review.md    ← Tier 2: thorough review (agentic)
prompts/security-audit.md ← Tier 3: paranoid security check (agentic)
prompts/single-review.md  ← Fast path: small/incremental/triage-approved
prompts/cascade-action.md ← Post-review: post, merge, delegate
prompts/shared.md         ← Shared risk taxonomy and decision gates
```

## Cost

Uses the configured engine's billing:
- **Claude:** Max plan via OAuth token — no per-token API billing.
- **Copilot:** Included in GitHub Copilot subscription.

GitHub Actions cost is ~720 runs/month (hourly × 30 days). Runs with zero
candidate PRs finish in ~10s. Each PR reviewed costs ~2-5 min of runner time
depending on how many cascade tiers fire.
