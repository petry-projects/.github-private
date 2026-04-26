# PR Review Agent Setup

This repository automates PR reviews for the `petry-projects` organization using Claude Code or GitHub Copilot.

## Quick Start

### Prerequisites
- GitHub organization: `petry-projects`
- GitHub App: `petry-projects-pr-review-agent` (ID: `3505640`)
- Secrets configured in the repository

### Repository Secrets Required

Store these in the repository settings (`Settings → Secrets and variables → Actions`):

| Secret | Description | Source |
|--------|-------------|--------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code authentication token | `claude setup-token` |
| `APP_ID` | GitHub App ID | `3505640` |
| `APP_INSTALLATION_ID` | App installation ID in petry-projects org | `127129996` |
| `APP_PRIVATE_KEY` | GitHub App private key (.pem file) | Downloaded from app settings |
| `COPILOT_GITHUB_TOKEN` | GitHub Copilot token (optional, for fallback) | GitHub PAT with Copilot scope |

### Repository Variables (Optional)

| Variable | Default | Purpose |
|----------|---------|---------|
| `REVIEW_ENGINE` | `claude` | Primary review engine: `claude` or `copilot` |
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
  --repo don-petry/pr-review-agent \
  -f dry_run=true
```

### Review a specific PR
```bash
gh workflow run pr-review.yml \
  --repo don-petry/pr-review-agent \
  -f pr_url=https://github.com/petry-projects/ContentTwin/pull/123 \
  -f dry_run=false
```

### Fix stuck PRs
If PRs have agent comments but no approval reviews (from an older bug), use:
```bash
gh workflow run fix-stuck-prs.yml \
  --repo don-petry/pr-review-agent \
  -f dry_run=true
```

Then apply fixes with `dry_run=false`.

## Scheduled Runs

The `pr-review.yml` workflow runs hourly at `:07` to avoid the top-of-hour cron stampede.

To check recent runs:
```bash
gh run list --repo don-petry/pr-review-agent -w pr-review.yml -L 5
```

## Troubleshooting

### Workflow fails: "Resource not accessible by integration"
- Verify GitHub App is installed to `petry-projects` organization
- Check App has correct permissions (Contents: read, Pull requests: read/write, Checks: read)
- Ensure `APP_ID`, `APP_INSTALLATION_ID`, and `APP_PRIVATE_KEY` secrets are set correctly

### Workflow fails: "Invalid private key"
- Download a fresh .pem file from the app settings
- Verify no whitespace at beginning/end when pasting into secret
- Store with: `gh secret set APP_PRIVATE_KEY --repo don-petry/pr-review-agent < path/to/file.pem`

### Reviews not posting
- Run a dry-run to verify agent decision
- Check `scripts/review-one-pr.sh` and `scripts/post-pr-review.sh` for errors
- Verify branch protection rules don't block the app as a reviewer

### PRs not auto-merging despite approval
- Check branch protection rules require approval (they do)
- Verify auto-merge is enabled in GitHub organization settings
- Confirm no other branch protection rules are blocking merge (e.g., required status checks)

## GitHub App Details

**Name:** `petry-projects-pr-review-agent`  
**ID:** `3505640`  
**Homepage:** https://github.com/don-petry/pr-review-agent  
**Installed to:** `petry-projects` organization (Installation ID: `127129996`)  
**Permissions:**
- Contents: Read-only
- Pull requests: Read & write
- Commit statuses: Read-only
- Checks: Read-only
- Members: Read-only (org level)

For full setup instructions including app creation, see [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md).

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

- **GitHub App tokens** expire automatically (1 hour) — more secure than long-lived PATs
- **Private key** stored only in GitHub Secrets, never logged or committed
- **Fine-grained permissions** — app cannot access organization members or other sensitive data beyond PRs
- **Audit trail** — all app actions logged in GitHub, visible in app settings → Recent deliveries
- **Rotation** — regenerate private key quarterly; update `APP_PRIVATE_KEY` secret with new .pem

## Related Documentation

- [AGENT.md](AGENT.md) — Full agent capabilities and design
- [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md) — Detailed GitHub App creation and configuration
