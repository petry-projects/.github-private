# PR Review Agent Setup

This repository automates PR reviews for the `petry-projects` organization using
Claude Code, Google Gemini, or GitHub Copilot.

## Quick Start

### Prerequisites
- GitHub organization: `petry-projects`
- Machine user account (e.g., `donpetry-bot`) added to org team in CODEOWNERS
- Secrets configured in the repository

### Repository Secrets Required

Store these in the repository settings (`Settings → Secrets and variables → Actions`):

| Secret | Description | Source |
|--------|-------------|--------|
| `DON_PETRY_BOT_GH_PAT` | Machine user PAT for GitHub API access | Generated from machine user account settings |
| `GH_PAT` | User PAT with Copilot subscription (for fallback) | GitHub PAT with Copilot scope |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code authentication token | `claude setup-token` |
| `GOOGLE_API_KEY` | Gemini API authentication token | Google AI Studio / Vertex AI |

### Repository Variables (Optional)

| Variable | Default | Purpose |
|----------|---------|---------|
| `REVIEW_ENGINE` | `claude` | Primary review engine: `claude`, `gemini`, or `copilot` |
| `LIVE_MODE` | `false` | If `true`, reviews are posted live; if `false`, dry-run only |
| `DELEGATION_ORGS` | Empty | Comma-separated orgs where AI can auto-fix: `petry-projects,don-petry` |
| `MAX_REVIEW_CYCLES` | `3` | Max review iterations before escalating to human |
| `MAX_PRS` | `10` | Max reviews posted per scheduled run |
| `CANDIDATE_LIMIT` | `100` | Max candidates scanned per run |

## How It Works

### PR Enumeration
The agent reviews open PRs authored by you that meet these criteria:
- Open status
- Not a draft
- No existing approval review from the agent
- Passing CI (checked via `--checks success` for external reviews)

See `scripts/list-prs.sh` for enumeration logic.

### Review Pipeline
1. **Triage** → Assess scope and priority
2. **Deep Review** → Analyze code quality and correctness
3. **Security Audit** → Check for vulnerabilities
4. **Synthesis** → Combine findings into approval/rejection decision

See `prompts/` directory for review prompts.

### Approval & Auto-Merge
When the agent approves a PR:
1. Posts an approval review via GitHub API
2. Enables auto-merge with squash strategy
3. Updates labels (`needs-human-review` removed if present)

## Running Manually

### Dry-run (test without posting)
```bash
gh workflow run pr-review.yml \
  --repo petry-projects/.github-private \
  -f dry_run=true
```

### Review a specific PR
```bash
gh workflow run pr-review.yml \
  --repo petry-projects/.github-private \
  -f pr_url=https://github.com/petry-projects/ContentTwin/pull/123 \
  -f dry_run=false
```

### Fix stuck PRs
If PRs have agent comments but no approval reviews (from an older bug), use:
```bash
gh workflow run fix-stuck-prs.yml \
  --repo petry-projects/.github-private \
  -f dry_run=true
```

Then apply fixes with `dry_run=false`.

## Scheduled Runs

The `pr-review.yml` workflow runs hourly at `:07` to avoid the top-of-hour cron stampede.

To check recent runs:
```bash
gh run list --repo petry-projects/.github-private -w pr-review.yml -L 5
```

## Troubleshooting

### Workflow fails: "Resource not accessible by integration"
- Verify the `DON_PETRY_BOT_GH_PAT` secret is set and the token hasn't expired
- Check the machine user has access to the target repos
- Ensure the PAT has the required scopes (Contents: read, Pull requests: read/write, Checks: read)

### Reviews not posting
- Run a dry-run to verify agent decision
- Check `scripts/review-one-pr.sh` and `scripts/post-pr-review.sh` for errors
- Verify branch protection rules allow the machine user as a reviewer

### PRs not auto-merging despite approval
- Check branch protection rules require approval (they do)
- Verify auto-merge is enabled in GitHub organization settings
- Confirm no other branch protection rules are blocking merge (e.g., required status checks)

## Machine User Details

The bot authenticates as a machine user account with a fine-grained PAT stored as the `DON_PETRY_BOT_GH_PAT` secret. The machine user is added to an org team listed in CODEOWNERS, so its approvals satisfy code owner review requirements.

For full setup instructions, see [machine-user-setup.md](machine-user-setup.md).

## Architecture

```
.github/workflows/
├── pr-review.yml           # Main hourly review workflow
└── fix-stuck-prs.yml       # Cleanup workflow for legacy stuck PRs

scripts/
├── list-prs.sh             # Find candidate PRs for review
├── review-one-pr.sh        # Orchestrate review for a single PR
├── post-pr-review.sh       # Post approval review and enable auto-merge
└── fix-stuck-prs.sh        # Fix PRs with comments but no approvals

prompts/
├── triage.md               # Initial scope assessment
├── deep-review.md          # Code quality analysis
├── security-audit.md       # Security assessment
├── cascade-action.md       # Used by agent for review coordination
└── shared.md               # Shared context for all prompts
```

## Security Considerations

- **Fine-grained PAT** scoped to only the permissions needed (Contents: read, Pull requests: read/write, Checks: read)
- **90-day expiry** on PAT — set a calendar reminder to rotate
- **PAT** stored only in GitHub Secrets, never logged or committed
- **Rotation** — generate a new PAT, update `DON_PETRY_BOT_GH_PAT` secret, revoke old token

## Related Documentation

- [pr-review-agent.md](pr-review-agent.md) — Full agent capabilities and design
- [machine-user-setup.md](machine-user-setup.md) — Machine user creation, PAT setup, and rotation
