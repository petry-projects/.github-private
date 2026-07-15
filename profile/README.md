# petry-projects — Member Hub

Welcome, org member. This page is your internal reference for the org's projects, automation,
standards, and agentic infrastructure.

## Projects

| Repository | Description | Language |
|---|---|---|
| [.github](https://github.com/petry-projects/.github) | Organization-wide GitHub configuration and workflows | Shell |
| [.github-private](https://github.com/petry-projects/.github-private) | Org-wide Copilot custom agents, Claude Code skills, and agentic workflow infrastructure | Shell |
| [ContentTwin](https://github.com/petry-projects/ContentTwin) | AI-powered Social Media Agent for small organizations — enterprise-quality social presence at non-profit pricing | Shell |
| [TalkTerm](https://github.com/petry-projects/TalkTerm) | | HTML |
| [bmad-bgreat-suite](https://github.com/petry-projects/bmad-bgreat-suite) | BMad Operations Suite — SRE and DevOps agents and workflows for the BMad Method ecosystem | Shell |
| [broodly](https://github.com/petry-projects/broodly) | A test implementation of the BMAD method | HTML |
| [broodminder-export](https://github.com/petry-projects/broodminder-export) | Extract all of your data from the BroodMinder API into portable files — resumable, rate-limit-aware. | Python |
| [google-app-scripts](https://github.com/petry-projects/google-app-scripts) | A place to share Google AppScripts for personal productivity | JavaScript |
| [incubator](https://github.com/petry-projects/incubator) | Product incubator: pre-product idea Discussions, decision briefs/PRD-lite, and disposable POCs. Ideas graduate to their own product repo once a POC proves out. Front-of-funnel for the .github-private ideation pipeline. | Shell |
| [markets](https://github.com/petry-projects/markets) | | HTML |
| [repo-template](https://github.com/petry-projects/repo-template) | Org template repository: one-click scaffold for new petry-projects repos. Files via 'Use this template'; non-file standards via bootstrap. See epic petry-projects/.github-private#964. | Shell |

## Standards & Practices

Engineering standards live in
[`petry-projects/.github/standards/`](https://github.com/petry-projects/.github/tree/main/standards).

| Standard | Purpose | Key sections |
|---|---|---|
| [`advanced-security`](https://github.com/petry-projects/.github/blob/main/standards/advanced-security.md) | GitHub Advanced Security configuration | Enablement via Code Security Configurations · Push-protection live-fire test (canary) · Licensing & billing · Compliance audit checks |
| [`agent-standards`](https://github.com/petry-projects/.github/blob/main/standards/agent-standards.md) | Guidelines for building and deploying AI agents | Required Files · Compliance Exemptions · AgentShield CI Workflow · Decision-Making Reusables · BMAD Method Workflows |
| [`ci-standards`](https://github.com/petry-projects/.github/blob/main/standards/ci-standards.md) | CI/CD pipeline conventions | Staged promotion through concentric rings · Action Pinning Policy · Permissions Policy · Required Workflows · Dev-Lead Agent |
| [`codeowners-standard`](https://github.com/petry-projects/.github/blob/main/standards/codeowners-standard.md) | CODEOWNERS file requirements | Team Composition · Required Setup for New Bots · Branch Protection |
| [`copilot-instructions-standard`](https://github.com/petry-projects/.github/blob/main/standards/copilot-instructions-standard.md) | Copilot custom instruction guidelines | Canonical Instruction Files · Required Sections · Content Quality Rules |
| [`dependabot-policy`](https://github.com/petry-projects/.github/blob/main/standards/dependabot-policy.md) | Dependency update and automerge policy | Dependabot Templates · Auto-Merge Workflow · Vulnerability Audit CI Check · CODEOWNERS Approval Timing |
| [`feature-ideation-sources`](https://github.com/petry-projects/.github/blob/main/standards/feature-ideation-sources.md) | Sources and process for feature ideation | AI / ML — Vendor & Lab Primary Sources · Developer Tooling & Platform Changelogs · Security & Compliance · Conferences |
| [`github-settings`](https://github.com/petry-projects/.github/blob/main/standards/github-settings.md) | Repository settings baselines | Repository Rulesets · Organization-Level Secrets · GitHub Apps & Integrations · Labels — Standard Set · Compliance Audit Process |
| [`initiatives-project`](https://github.com/petry-projects/.github/blob/main/standards/initiatives-project.md) | Project board for tracking org initiatives | What belongs on the board · Fields · Theme → Initiative · How the auto-add works |
| [`persona-standards`](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md) | Agent and Copilot persona guidelines | The trigger matrix (onboarding checklist) · Canary onboarding · Trust, permissions, and safety · Definition of Done |
| [`pr-limits`](https://github.com/petry-projects/.github/blob/main/standards/pr-limits.md) | Pull request size and scope limits | What is limited · Exempt actors · Reconciliation with the Dependabot cap · Operator runbook |
| [`push-protection`](https://github.com/petry-projects/.github/blob/main/standards/push-protection.md) | Secret push protection configuration | Layer 1 — GitHub Push Protection · Layer 2 — Local Pre-Commit Prevention · Layer 3 — CI Secret Scanning · Incident Response |
| [`ruleset-remediation-runbook`](https://github.com/petry-projects/.github/blob/main/standards/ruleset-remediation-runbook.md) | Steps to remediate ruleset violations | Bypass actors · Legacy rulesets — migrate checks first, then delete · Rollback |

## Custom Agents

Copilot custom agent profiles live in
[`.github-private/agents/`](https://github.com/petry-projects/.github-private/tree/main/agents)
and are available org-wide from GitHub.com, VS Code, and JetBrains.

| Agent | Role |
|---|---|
| [`agentic-workflows`](https://github.com/petry-projects/.github-private/blob/main/agents/agentic-workflows.md) | Orchestrates multi-step agentic workflows |
| [`compliance-auditor`](https://github.com/petry-projects/.github-private/blob/main/agents/compliance-auditor.md) | Audits repos for compliance with org standards |
| [`feature-ideator`](https://github.com/petry-projects/.github-private/blob/main/agents/feature-ideator.md) | Generates and evaluates feature ideas |
| [`pr-reviewer`](https://github.com/petry-projects/.github-private/blob/main/agents/pr-reviewer.md) | Reviews pull requests against org standards |

## Agentic Workflows

Autonomous CI agents run as GitHub Actions in
[`.github-private/.github/workflows/`](https://github.com/petry-projects/.github-private/tree/main/.github/workflows).
These are distinct from the `@mention` Copilot agents above.

| Workflow | Purpose |
|---|---|
| [`ci-failure-analyst-reusable.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/ci-failure-analyst-reusable.yml) | CI failure analyst — diagnoses failed CI/Lint/Test runs and comments root-cause analysis |
| [`dev-lead.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/dev-lead.yml) | Dev-Lead agent — autonomously implements an assigned issue (branch, code, tests, PR) |
| [`feature-ideation.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/feature-ideation.yml) | Feature research & ideation agent (BMAD Analyst) — turns sources into scoped feature ideas |
| [`idea-triage.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/idea-triage.yml) | Idea triage agent — scores queued ideas and promotes them into the backlog |
| [`initiative-driver.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/initiative-driver.yml) | Initiative driver — auto-releases an epic's ready sub-issues to Dev-Lead |
| [`initiative-planner.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/initiative-planner.yml) | Initiative planner (BMAD Scrum Master) — breaks an approved initiative into an epic + sub-issues |
| [`issue-triage-runner.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/issue-triage-runner.yml) | Issue triage agent — labels and routes newly opened issues |
| [`pr-review-trigger.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/pr-review-trigger.yml) | PR review agent — cascading triage → deep → security review on pull requests |
| [`release-notes.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/release-notes.yml) | Release-notes agent — drafts Keep-a-Changelog entries from merged PRs and opens a CHANGELOG PR |
| [`stale-manager.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/stale-manager.yml) | Stale manager agent — warns and closes stale issues/PRs across the org |

## Agentic Frameworks

Frameworks are installed as git subtrees in
[`.github-private/frameworks/`](https://github.com/petry-projects/.github-private/tree/main/frameworks).

| Framework | Version | Source |
|---|---|---|
| `bmad-method` | v6.8.0 | [bmad-code-org/BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) |
| `bmad-test-architecture` | v1.19.0 | [bmad-code-org/bmad-method-test-architecture-enterprise](https://github.com/bmad-code-org/bmad-method-test-architecture-enterprise) |

## Reporting & Dashboards

Scheduled reports and dashboards post as issues or workflow-run summaries for maintainers.

### `.github-private` reports

| Workflow | Purpose |
|---|---|
| [`actions-fleet-monitor.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/actions-fleet-monitor.yml) | Actions fleet monitor — org-wide workflow token usage and run anomalies |
| [`auto-rebase-health.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/auto-rebase-health.yml) | Daily auto-rebase health report (issue) — rebase success/failure trends |
| [`content-twin-audit.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/content-twin-audit.yml) | ContentTwin content audit — audits the ContentTwin repo's published content |
| [`daily-pr-review-health.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/daily-pr-review-health.yml) | Daily PR-review health check — flags PR-review agent failures as an issue |
| [`docs-health-check.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/docs-health-check.yml) | Docs health check — flags stale/broken docs as an issue |
| [`premature-closure-audit.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/premature-closure-audit.yml) | Premature-closure audit — flags issues closed as completed with no merged closing PR |
| [`reviewer-report.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/reviewer-report.yml) | Reviewer scorecard (per workflow-run summary) — per-reviewer PR-review activity |
| [`skill-eval-report.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/skill-eval-report.yml) | Skill-eval results report — agent skill pass/fail trends (self-improving-skills pipeline) |
| [`token-report.yml`](https://github.com/petry-projects/.github-private/blob/main/.github/workflows/token-report.yml) | LLM token-cost report (per workflow-run summary) for maintainers |

### `.github` reports

| Workflow | Purpose |
|---|---|
| [`compliance-audit-and-improvement.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/compliance-audit-and-improvement.yml) | Weekly org standards compliance audit + runtime health survey, with per-finding remediation issues |
| [`daily-org-status.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/daily-org-status.yml) | Daily "Org Status" digest posted as an issue for maintainers |
| [`org-scorecard.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/org-scorecard.yml) | Weekly OpenSSF Scorecard security-posture review across public repos; findings tracked as issues |
