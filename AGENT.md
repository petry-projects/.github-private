# PR Review Agent

A scheduled GitHub Action that reviews open PRs on don-petry's behalf.
Runs hourly, classifies risk, auto-approves low/medium-risk PRs that pass all
quality gates, and escalates high-risk or gated PRs for human review.

## How it works

1. **Cron** — `.github/workflows/pr-review.yml` runs at `:07` every hour
   (and on `workflow_dispatch`).
2. **Enumerate** — `scripts/list-prs.sh` queries GitHub for open PRs where
   `@me` is the author OR a requested reviewer, across every repo the PAT can
   see. Output: one URL per line.
3. **Per-PR review** — for each PR, `scripts/review-one-pr.sh` orchestrates a
   council of three Claude models, each with a focused lens, then a synthesizer
   that posts a single combined review:

   | Lens | Model | What it looks for |
   |---|---|---|
   | Security | Opus 4.6 | auth, secrets, injection, supply chain, GH Actions security smells |
   | Correctness | Sonnet 4.6 | linked-issue alignment, logic bugs, edge cases, test coverage, CI |
   | Maintainability | Sonnet 4.6 | org standards, conventions, clarity, dependency hygiene |
   | Synthesis | Sonnet 4.6 | combines verdicts, takes max risk, dedupes findings, posts to GitHub |

   The three council members run in parallel, each writing a JSON verdict to
   `/tmp/council/<lens>.json`. None of them touch GitHub. The synthesizer then
   reads all three, takes `max(risk)` and `escalate if any escalates`, dedupes
   findings, and posts **one** PR review:
   - If approved: `gh pr review --approve` with the combined summary.
   - If escalated: `gh pr review --comment`, re-requests don-petry as a
     reviewer, and adds the `needs-human-review` label.

4. **Post-review actions** — after the review is posted, the synthesizer takes
   additional actions depending on the decision:
   - **If approved:** enables auto-merge (`gh pr merge --auto --squash`),
     rebases the branch if behind base, and removes the `needs-human-review`
     label. GitHub merges automatically once all required checks pass.
   - **If escalated + Claude App available:** posts a follow-up comment tagging
     `@claude` with specific fix instructions derived from the council findings.
     Claude pushes fixes → next cron tick detects new SHA → council re-reviews
     → approve + auto-merge when clean. This creates an autonomous fix loop.
   - **If escalated + no Claude App (or max cycles reached):** labels
     `needs-human-review` and re-requests don-petry as reviewer.
   - **Cycle guard:** after `MAX_REVIEW_CYCLES` (default 3) rounds of @claude
     delegation without resolution, the agent stops delegating and escalates
     to human to prevent infinite loops.

5. **Idempotency + iterative review cycles** — every posted review starts with
   an HTML marker on line 1:

   ```
   <!-- pr-review-agent v1 sha=<full-commit-sha> decision=... risk=... -->
   ```

   Before invoking the council, `scripts/review-one-pr.sh` fetches the PR's
   current head SHA and scans existing reviews/comments for the marker. If a
   marker matching the current head SHA exists, the script skips the PR
   without spending tokens. If a marker exists for an older SHA, the script
   knows the PR has new commits since the last review and runs the council
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

### 2. Add your Claude Code OAuth token

This routes the agent's Claude usage through your Claude Max plan instead of
per-token API billing. Generate the token locally with:

```
claude setup-token
```

It prints a long-lived OAuth token. Store it as a repo secret:

```
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo don-petry/self
```

(Paste the token when prompted, then Ctrl+D.)

### 3. Test with a dry run

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

- **Risk rules** — edit `prompts/shared.md` (taxonomy), or per-lens in
  `prompts/council/{security,correctness,maintainability}.md`.
- **Cron frequency** — change the `cron:` line in the workflow file.
- **Scope** — edit `scripts/list-prs.sh` to add/remove queries (e.g. to include
  PRs from a specific org, or to exclude certain repos).
- **Claude delegation** — set `CLAUDE_ORGS` to a comma-separated list of GitHub
  orgs where the Claude App is installed:
  `gh variable set CLAUDE_ORGS --body "petry-projects,don-petry" --repo don-petry/self`
- **Max review cycles** — how many times the agent tags @claude before
  escalating to human (default 3):
  `gh variable set MAX_REVIEW_CYCLES --body 5 --repo don-petry/self`
- **Max PRs per run** — defaults to 10 per cron tick to stay within the 60-min
  job timeout (~5 min per PR with 3 council members). Override:
  `gh variable set MAX_PRS --body 15 --repo don-petry/self`
- **Models** — change model IDs in `scripts/review-one-pr.sh` (`run_member`
  calls and the synthesis invocation). See the script for current assignments.

## Cost

Uses the Claude Max plan via OAuth token — no per-token API billing. GitHub
Actions cost is ~720 runs/month (hourly × 30 days). Runs with zero candidate
PRs finish in ~10s. Each PR reviewed costs ~5 min of runner time (4 model
invocations: 3 council + 1 synthesis).
