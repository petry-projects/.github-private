# Documentation Index

This repository contains several documentation files describing the PR Review Agent system. Start here to understand which document you need.

## Quick Start
- **[SETUP.md](SETUP.md)** ⭐ Start here!
  - Quick reference for configuration and usage
  - Lists required secrets and variables
  - Shows how to run manually or check logs
  - Includes troubleshooting for common issues

## Understanding the System
- **[AGENT.md](AGENT.md)** — Full system documentation
  - Architecture and design philosophy
  - How PR reviews are performed
  - Agent capabilities and limitations
  - Configuration options

- **[IMPLEMENTATION.md](IMPLEMENTATION.md)** — Technical deep dive
  - Why GitHub Apps over bot accounts
  - How PR enumeration works
  - Review pipeline architecture
  - Separation of agent vs infrastructure concerns
  - Rate limiting and fallback logic
  - Stuck PR cleanup explained

## Setting Up GitHub App (If Rebuilding)
- **[GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)** — Step-by-step app creation
  - Create the GitHub App in your organization
  - Configure permissions
  - Install to organization and repos
  - Generate and store secrets
  - Test authentication

## Current Implementation Details
- **App Name:** `petry-projects-pr-review-agent`
- **App ID:** `3505640`
- **Installation:** https://github.com/organizations/petry-projects/settings/installations/127129996

## File Organization

```
.github/workflows/
├── pr-review.yml           # Main hourly review workflow
└── fix-stuck-prs.yml       # Cleanup for stuck PRs

scripts/
├── list-prs.sh             # Find candidate PRs
├── review-one-pr.sh        # Orchestrate review
├── post-pr-review.sh       # Post approval and auto-merge
└── fix-stuck-prs.sh        # Fix old stuck PRs

prompts/
├── shared.md               # Shared context
├── triage.md               # Quick assessment
├── deep-review.md          # Code analysis
├── security-audit.md       # Vulnerability check
└── synthesize.md           # Final verdict

docs/
├── SETUP.md                # Quick start (read first)
├── AGENT.md                # Full documentation
├── IMPLEMENTATION.md       # Technical details
├── GITHUB_APP_SETUP.md     # App creation guide
└── DOCUMENTATION.md        # This file
```

## Common Tasks

### I want to understand what this agent does
→ Read [AGENT.md](AGENT.md)

### I need to set up the agent in a new organization
→ Follow [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)

### The agent isn't working, help!
→ Check [SETUP.md#troubleshooting](SETUP.md#troubleshooting)

### I want to understand the architecture
→ Read [IMPLEMENTATION.md](IMPLEMENTATION.md)

### I need to update configuration
→ See [SETUP.md#repository-variables](SETUP.md#repository-variables)

### I want to run a manual review
→ See [SETUP.md#running-manually](SETUP.md#running-manually)

## Authentication Method

The agent uses **GitHub Apps** for authentication:

**Why GitHub Apps?**
- ✅ No human account required
- ✅ Auto-expiring tokens (1 hour) — more secure
- ✅ Fine-grained permissions
- ✅ Better audit trail
- ✅ GitHub's recommended approach

**Why not a bot user account?**
- Would require creating and maintaining a separate GitHub user
- Long-lived PATs (1 year) with higher security risk
- Less audit visibility
- More complex permissions management

## Required Secrets

All secrets must be set in the repository (`Settings → Secrets and variables → Actions`):

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code API access |
| `APP_ID` | GitHub App ID (3505640) |
| `APP_INSTALLATION_ID` | App installation in org (127129996) |
| `APP_PRIVATE_KEY` | GitHub App private key (.pem) |
| `COPILOT_GITHUB_TOKEN` | Optional fallback engine |

## Review Workflow

```
1. Enumerate open PRs (hourly or manual trigger)
   ↓
2. For each PR, perform triage assessment
   ↓
3. If promising, proceed to deep review + security audit
   ↓
4. Synthesize findings and make approval/rejection decision
   ↓
5. Post approval review to GitHub
   ↓
6. Enable auto-merge (if approved)
   ↓
7. Update labels and log results
```

## Support and Troubleshooting

- **Workflow failing to authenticate**: Check [SETUP.md#troubleshooting](SETUP.md#troubleshooting)
- **Questions about design**: See [IMPLEMENTATION.md](IMPLEMENTATION.md)
- **Setup instructions**: Follow [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)
- **Agent capabilities**: Read [AGENT.md](AGENT.md)

## Document Maintenance

These documents are kept in sync with the actual implementation. When updating the system:
1. Update the relevant scripts/workflows
2. Update the corresponding documentation
3. Ensure SETUP.md reflects current state
4. Update IMPLEMENTATION.md if architecture changes

Last updated: April 26, 2026
