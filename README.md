# .github-private

Org-wide Copilot custom agents, Claude Code skills, and agentic workflow infrastructure for `petry-projects`.

## What This Repo Does

This is the [`.github-private` convention](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/create-custom-agents) repo for the petry-projects org.
Agent profiles in `/agents/` are available org-wide — invocable from GitHub.com, VS Code, JetBrains, and Copilot CLI.

It also contains the scheduled PR review automation (workflows + scripts + prompts) that runs hourly across the org.

## Structure

```
agents/                   # Copilot custom agent profiles (org-wide)
  agentic-workflows.md    # Agentic workflow orchestration
  compliance-auditor.md   # Org standards compliance checking
  feature-ideator.md      # Feature idea generation
  pr-reviewer.md          # Multi-tier cascading PR review
prompts/                  # Prompt libraries used by workflows
scripts/                  # Shell orchestration for GitHub Actions
frameworks/               # Installed agentic frameworks (git subtree)
  bmad-method/            # BMAD-METHOD v6.8.0: multi-agent development lifecycle
  bmad-test-architecture/ # bmad-method-test-architecture-enterprise v1.19.0
.github/workflows/        # Scheduled automation (PR review, health checks)
```

## Agents

| Agent | Purpose | Invoke with |
|-------|---------|-------------|
| `agentic-workflows` | Agentic workflow orchestration | `@agentic-workflows` in any org repo |
| `compliance-auditor` | Audit repo against org standards | `@compliance-auditor` in any org repo |
| `feature-ideator` | Generate and prioritize feature ideas | `@feature-ideator` in any org repo |
| `pr-reviewer` | Cascading PR review (triage → deep → security audit) | `@pr-reviewer` in any org PR |

## PR Review Automation

The scheduled workflow reviews all open PRs across `petry-projects` hourly:
- Classifies risk (LOW/MEDIUM/HIGH) via cascading tiers
- Auto-approves LOW/MEDIUM risk PRs with passing CI
- Cross-engine adversarial review (Claude + Copilot rubber duck)
- Escalates HIGH risk or failing PRs to human review

Trigger manually: `gh workflow run pr-review.yml --repo petry-projects/.github-private`

Mention trigger: Comment `@petry-review-bot` on any org PR for immediate review.

## Standards

Engineering standards live in `petry-projects/.github/standards/`.
Notable subtopics are listed below to aid discoverability; see the standards directory for full documentation.

| Standard | Notable subtopics |
|----------|-------------------|
| `advanced-security` | Code Security Configurations, push-protection live-fire (canary), custom secret scanning patterns, compliance audit checks |
| `agent-standards` | Required files, compliance exemptions, AgentShield CI workflow, decision-making reusables, BMAD Method Workflows |
| `ci-standards` | Staged promotion through concentric rings, reusable workflow versioning (`stable` channel), action pinning policy, permissions policy, Dev-Lead Agent |
| `codeowners-standard` | Team composition, required setup for new bots, branch protection, bypass actors |
| `copilot-instructions-standard` | Canonical instruction files, adding a new language, required sections, content quality rules |
| `dependabot-policy` | Configuration files, auto-merge workflow, vulnerability audit CI check, applying to a repository |
| `feature-ideation-sources` | AI/ML vendor & lab sources, developer tooling changelogs, security & compliance sources, newsletters, podcasts |
| `github-settings` | Org-level settings, repository rulesets, required checks ruleset, GitHub Apps & integrations, org-level secrets |
| `initiatives-project` | Project board fields, Theme → Initiative, how auto-add works, initiative classification |
| `persona-standards` | Canary onboarding (the last step), trigger matrix, trust & permissions, definition of done |
| `pr-limits` | Exempt actors, operator runbook, reconciliation with the Dependabot cap |
| `push-protection` | Layer 1 (GitHub push protection), Layer 2 (local pre-commit), Layer 3 (CI secret scanning), incident response |
| `ruleset-remediation-runbook` | Bypass actors, migrate checks into `code-quality`, delete legacy rulesets, rollback procedure |

## Documentation

- [Architecture & Capabilities](docs/pr-review-agent/pr-review-agent.md)
- [Setup Guide](docs/pr-review-agent/setup.md)
- [Machine User Setup](docs/pr-review-agent/machine-user-setup.md)
