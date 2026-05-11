# CLAUDE.md — .github-private

This file provides project-specific instructions for Claude Code when working in this repository.

## Development Standards

Read [AGENTS.md](./AGENTS.md) before making any changes. It defines the org-wide standards for CI, workflows, labels, agent configuration, and more.

## Repository Purpose

This is the **`.github-private` org infrastructure repo** for `petry-projects`. It contains:

- **`agents/`** — Copilot custom agent profiles (org-wide, invocable from GitHub.com, VS Code, JetBrains)
- **`frameworks/`** — Agentic frameworks installed via `git subtree` (bmad-method, spec-kit, gsd)
- **`scripts/`** — Shell orchestration for GitHub Actions
- **`.github/workflows/`** — Scheduled automation (PR review, health checks)

## Key Guidelines

- Do **not** modify `.github/workflows/claude.yml` or `.github/workflows/agent-shield.yml` — these are org-standard thin-caller stubs
- Workflow templates in `petry-projects/.github/standards/workflows/` should be copied verbatim, not regenerated
- SHAs for action pinning must be looked up via the GitHub API — never guessed
- All changes to `.github/workflows/` files require reading `standards/ci-standards.md` in the org `.github` repo first
- Scripts in `scripts/` must be POSIX-compatible bash with `set -euo pipefail` and no hardcoded secrets
