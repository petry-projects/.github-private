# Documentation Index

This repository contains several documentation files describing the PR Review Agent system. Start here to understand which document you need.

## Quick Start
- **[setup.md](setup.md)** ⭐ Start here!
  - Quick reference for configuration and usage
  - Lists required secrets and variables
  - Shows how to run manually or check logs
  - Includes troubleshooting for common issues

## Understanding the System
- **[pr-review-agent.md](pr-review-agent.md)** — Full system documentation
  - Architecture and design philosophy
  - How PR reviews are performed
  - Agent capabilities and limitations
  - Configuration options

- **[implementation.md](implementation.md)** — Technical deep dive
  - Authentication: machine user with PAT
  - How PR enumeration works
  - Review pipeline architecture
  - Separation of agent vs infrastructure concerns
  - Rate limiting and fallback logic
  - Stuck PR cleanup explained

- **[downstream-impact.md](downstream-impact.md)** — Downstream-impact pass (operator guide)
  - What the pass does and the informational signal it adds
  - How to enable it (`DOWNSTREAM_IMPACT_ENABLED`, default-off)
  - The `GH_PAT` cross-repo read scope it needs
  - Per-PR fetch + size caps
  - How/when to refresh the consumer manifest

- **[maintainer-comment-gate.md](maintainer-comment-gate.md)** — Maintainer issue-comment gate (#1290)
  - Why a review thread blocks merge but a plain PR comment did not
  - How pr-review withholds approval on an unaddressed maintainer issue comment
  - Its fail-closed semantics, what clears it, and the `FORCE_REVIEW` bypass

- **[concurrency-and-coverage.md](concurrency-and-coverage.md)** — Concurrency, coverage & the cancelled-check surface (#1422)
  - What `cancel-in-progress: false` does and does not protect (in-flight yes, pending no)
  - Why the concurrency group is keyed by head SHA, and the SHA-source per trigger
  - The argument that at least one review completes at the final head SHA per push
  - The #1408 sweep-narrowing interaction and how the outcome mix is now tracked

## Setting Up Authentication
- **[machine-user-setup.md](machine-user-setup.md)** — Machine user and PAT setup
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

docs/pr-review-agent/
    ├── setup.md                # Quick start (read first)
    ├── pr-review-agent.md                # Full documentation
    ├── implementation.md       # Technical details
    ├── machine-user-setup.md   # Machine user and PAT setup
    └── documentation-index.md        # This file
```

## Common Tasks

### I want to understand what this agent does
→ Read [pr-review-agent.md](pr-review-agent.md)

### I need to set up the agent in a new organization
→ Follow [machine-user-setup.md](machine-user-setup.md)

### The agent isn't working, help!
→ Check [setup.md#troubleshooting](setup.md#troubleshooting)

### I want to understand the architecture
→ Read [implementation.md](implementation.md)

### I want to enable or tune the downstream-impact pass
→ Read [downstream-impact.md](downstream-impact.md)

### I need to update configuration
→ See [setup.md#repository-variables](setup.md#repository-variables)

### I want to run a manual review
→ See [setup.md#running-manually](setup.md#running-manually)

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
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code authentication |
| `DON_PETRY_BOT_GH_PAT` | Machine user fine-grained PAT |
| `GH_PAT` | User PAT with Copilot subscription |

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

- **Workflow failing to authenticate**: Check [setup.md#troubleshooting](setup.md#troubleshooting)
- **Questions about design**: See [implementation.md](implementation.md)
- **Setup instructions**: Follow [machine-user-setup.md](machine-user-setup.md)
- **Agent capabilities**: Read [pr-review-agent.md](pr-review-agent.md)

## Document Maintenance

These documents are kept in sync with the actual implementation. When updating the system:
1. Update the relevant scripts/workflows
2. Update the corresponding documentation
3. Ensure setup.md reflects current state
4. Update implementation.md if architecture changes

Last updated: May 11, 2026
