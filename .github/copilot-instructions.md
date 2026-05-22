# Copilot Instructions — .github-private

> **Note:** This file applies to the `petry-projects/.github-private` repository only. Org-wide rules are in [`petry-projects/.github/copilot-instructions.md`](https://github.com/petry-projects/.github/blob/main/.github/copilot-instructions.md). This file covers only what is specific to .github-private.

## About

.github-private is the org's private CI infrastructure repository — it hosts Copilot custom agent profiles (org-wide), sophisticated agentic GitHub Actions workflows (PR review, content-twin audit, standards-sync, CI failure analysis, stale management, etc.), and agentic framework subtrees (bmad-method, spec-kit, gsd).

## Tech Stack

- **Runtime:** Bash (scripts) · GitHub-hosted runners (Actions)
- **Framework:** GitHub Actions (YAML) · BMad Method (via `frameworks/` git subtrees)
- **Testing:** ShellCheck (scripts) · `gh aw compile` (agentic workflow YAML linting — CI-gated in `lint.yml`)
- **Linting:** ShellCheck (zero warnings) · markdownlint (agent profiles + docs) · `gh aw compile` (`.github/workflows/*.md` / `*.lock.yml`)
- **Key tools:** `gh` CLI · `gh aw` (agentic workflow compiler)

## Project Structure

```text
agents/                 # Copilot custom agent profiles (org-wide effect)
  agentic-workflows.md
  compliance-auditor.md
  feature-ideator.md
  pr-reviewer.md
.github/
  workflows/
    dev-lead.yml            # Primary AI automation for this repo (inline steps)
    dev-lead-reusable.yml   # Cross-org reusable workflow (edit to affect all repos)
    pr-review.yml           # Automated PR review
    lint.yml                # ShellCheck + markdownlint + gh-aw-compile (repo-specific gate)
    content-twin-audit.yml  # Scheduled content-twin compliance check
    standards-sync.yml      # Standards propagation across org repos
    ci-failure-analyst.*    # CI failure triage automation
    stale-manager.*         # Stale PR/issue management
    ...
  aw/                   # Agentic workflow definitions (compiled by gh-aw)
  rulesets/             # Branch protection ruleset JSON
scripts/                # Shell orchestration for GitHub Actions
docs/                   # Workflow documentation
prompts/                # Agent prompt library
```

## Local Dev Commands

- Lint scripts:         `shellcheck --severity=warning -x scripts/**/*.sh`
- Lint agentic flows:   `gh aw compile --no-emit`
- Run tests:            `bats tests/fleet_report.bats`

## Required Environment Variables

- `GH_TOKEN`: Set from `GH_PAT_WORKFLOWS` secret (falls back to `GITHUB_TOKEN`); used by all `gh` CLI calls
- `CLAUDE_CODE_OAUTH_TOKEN`: Used by dev-lead and pr-review workflows (stored as Actions secret)

## Testing Framework

- Runner: `gh aw compile` (agentic workflow YAML compilation — required CI gate in `lint.yml`)
- Shell: ShellCheck (required CI gate)
- Coverage: N/A
- Mutation testing: N/A

## Repo-Specific Overrides

**`agent-shield.yml` is a thin caller stub** — only `with:` inputs (`min-severity`, `agentshield-version`, `required-files`, `org-standards-ref`) may change if the repo needs a different policy. Never change trigger events, the `uses:` line, or the job name (it is a required status check).

**`dev-lead.yml` vs `dev-lead-reusable.yml`:** To change AI automation behavior for this repo only, edit `dev-lead.yml`. To change behavior across all org repos, edit `dev-lead-reusable.yml` (the cross-org reusable).

**`lint.yml` `gh-aw-compile` job** is a documented repo-specific addition — do not remove it when syncing org CI templates; if the org template gains an equivalent, remove this note and defer to the template.

**Agent profiles** in `agents/*.md` must have YAML frontmatter with `name`, `description`, and `tools`. Agent names must be kebab-case matching the filename. Changes are org-wide.

## Org Standards

See [petry-projects/.github — AGENTS.md](https://github.com/petry-projects/.github/blob/main/AGENTS.md) for org-wide development standards.

**Language-specific instructions** (applied automatically by Copilot when you open matching file types):

- [Shell](.github/instructions/shell.instructions.md) — safety flags, ShellCheck, quoting, error handling, Makefile standards
