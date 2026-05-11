# .github-private

Org-wide Copilot custom agents, Claude Code skills, and agentic workflow infrastructure for `petry-projects`.

## What This Repo Does

This is the [`.github-private` convention](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/create-custom-agents) repo for the petry-projects org. Agent profiles in `/agents/` are available org-wide — invocable from GitHub.com, VS Code, JetBrains, and Copilot CLI.

## Structure

```
agents/                  # Copilot custom agent profiles (org-wide)
  feature-ideator.md     # Feature idea generation
  compliance-auditor.md  # Org standards compliance checking
frameworks/              # Installed agentic frameworks (git subtree)
  bmad-method/           # BMAD-METHOD: multi-agent development lifecycle
  spec-kit/              # spec → plan → tasks pipeline
  gsd/                   # get-shit-done: context engineering & milestones
.github/workflows/       # Org automation workflows
```

## Agents

| Agent | Purpose | Invoke with |
|-------|---------|-------------|
| `feature-ideator` | Generate and prioritize feature ideas | `@feature-ideator` in any org repo |
| `compliance-auditor` | Audit repo against org standards | `@compliance-auditor` in any org repo |