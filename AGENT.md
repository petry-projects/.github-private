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
3. **Review** — for each PR, the workflow runs the Claude Code CLI with
   `prompts/review-pr.md`. The prompt instructs the agent to:
   - Fetch the PR, its diff, the linked issue, CI checks, and review threads.
   - Classify risk as LOW / MEDIUM / HIGH using explicit rules (auth, secrets,
     migrations, security warnings, violations of best practice / org standards).
   - Auto-approve only if risk is LOW or MEDIUM **and** all gates pass:
     CI green, linked issue addressed, no unresolved review threads,
     well-structured PR.
   - Otherwise: post a `--comment` review (not a request-changes), re-request
     don-petry as reviewer, and add the `needs-human-review` label.
4. **Idempotency** — the agent looks for its own footer in existing reviews and
   skips PRs it has already reviewed at the current head SHA.

## Setup

### 1. Create a fine-grained PAT

Go to <https://github.com/settings/personal-access-tokens/new>. Settings:

- **Resource owner:** `don-petry`
- **Repository access:** "All repositories" (or pick the ones you want the
  agent to act on).
- **Repository permissions:**
  - Contents: **Read**
  - Issues: **Read**
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

## Tuning

- **Risk rules** live in `prompts/review-pr.md`. Edit there.
- **Cron frequency** — change the `cron:` line in the workflow file.
- **Scope** — edit `scripts/list-prs.sh` to add/remove queries (e.g. to include
  PRs from a specific org, or to exclude certain repos).

## Cost

Hourly cron × ~30 days = ~720 runs/month. If most hours have zero candidate PRs
the cost is just GitHub Actions minutes (~10s each). Anthropic API cost scales
with PR count and diff size — expect a few cents per non-trivial PR review.
