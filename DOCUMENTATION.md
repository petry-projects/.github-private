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
  - Authentication: machine user with PAT
  - How PR enumeration works
  - Review pipeline architecture
  - Separation of agent vs infrastructure concerns
  - Rate limiting and fallback logic
  - Stuck PR cleanup explained

## Setting Up Authentication
- **[MACHINE_USER_SETUP.md](MACHINE_USER_SETUP.md)** — Machine user and PAT setup
  - Create machine user account and org team
  - Configure CODEOWNERS for code owner approvals
  - Generate fine-grained PAT
  - Store secrets and rotate tokens

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
├── MACHINE_USER_SETUP.md   # Machine user and PAT setup
└── DOCUMENTATION.md        # This file
```

## Common Tasks

### I want to understand what this agent does
→ Read [AGENT.md](AGENT.md)

### I need to set up the agent in a new organization
→ Follow [MACHINE_USER_SETUP.md](MACHINE_USER_SETUP.md)

### The agent isn't working, help!
→ Check [SETUP.md#troubleshooting](SETUP.md#troubleshooting)

### I want to understand the architecture
→ Read [IMPLEMENTATION.md](IMPLEMENTATION.md)

### I need to update configuration
→ See [SETUP.md#repository-variables](SETUP.md#repository-variables)

### I want to run a manual review
→ See [SETUP.md#running-manually](SETUP.md#running-manually)

## Authentication Method

The agent uses a **machine user account** with a fine-grained PAT:

**Why Machine User?**
- ✅ Can be listed in CODEOWNERS via org team membership
- ✅ Approvals satisfy `require_code_owner_review` branch protection
- ✅ Simple PAT-based auth — no JWT generation step needed
- ✅ Works identically to a human reviewer

Previously used GitHub Apps, but they cannot be listed in CODEOWNERS (GitHub platform limitation). See [issue #27](https://github.com/don-petry/pr-review-agent/issues/27).

## Required Secrets

All secrets must be set in the repository (`Settings → Secrets and variables → Actions`):

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code API access |
| `DON_PETRY_BOT_PETRY_PROJECT_PAT` | Machine user fine-grained PAT |
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
- **Setup instructions**: Follow [MACHINE_USER_SETUP.md](MACHINE_USER_SETUP.md)
- **Agent capabilities**: Read [AGENT.md](AGENT.md)

## Document Maintenance

These documents are kept in sync with the actual implementation. When updating the system:
1. Update the relevant scripts/workflows
2. Update the corresponding documentation
3. Ensure SETUP.md reflects current state
4. Update IMPLEMENTATION.md if architecture changes

Last updated: April 26, 2026
