# Release Notes Generator — Workflow Spec

## Purpose

Auto-generate CHANGELOG entries on every push to `main`. Finds merged PRs in the
push range, filters for user-facing changes (`feat` or `fix` labels), generates
structured Keep-a-Changelog entries using Claude, and opens a PR updating
`CHANGELOG.md`.

## Trigger

```yaml
on:
  push:
    branches: [main]
```

## Engine

Claude (`claude-sonnet-4-6` for changelog content generation).

## Permissions

```yaml
permissions:
  contents: read
  pull-requests: read
```

> **Note:** Live mode requires `contents: write` and `pull-requests: write` to create
> the changelog branch and open the PR. The staged configuration runs read-only and
> logs generated content to the step summary.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `CHANGELOG_LABELS` | `feat,fix` | Comma-separated PR labels that trigger a changelog entry |
| `CHANGELOG_FILE` | `CHANGELOG.md` | Path to the changelog file |
| `DRY_RUN` | `true` | If `true`, print generated content to summary only (no PR) |

## Secrets

| Secret | Required | Purpose |
|---|---|---|
| `DON_PETRY_BOT_GH_PAT` | Yes | PAT with `repo` scope for creating branches and PRs |
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Claude Code OAuth token for changelog generation |

## Behavior

### Per-push logic

1. **Resolve push range:** compare `before` SHA to `after` SHA (`GITHUB_SHA`)
2. **Find merged PRs:** list commits in the range; cross-reference GitHub API to find
   associated merged PRs
3. **Filter:** keep only PRs labeled `feat` or `fix`; if none found, exit with notice
4. **Dedup check:** search for an open PR titled `chore: update CHANGELOG for <short-sha>`;
   if found, skip (idempotency)
5. **Generate:** call Claude with PR metadata (number, title, body, labels) to produce
   Keep-a-Changelog entries grouped by `### Added` / `### Fixed` / `### Changed`
6. **Apply:** if `CHANGELOG.md` does not exist, create it with the standard header;
   prepend the new entries under `## [Unreleased]`
7. **Open PR:** create a branch `chore/changelog-<short-sha>` and open a PR against `main`

### Idempotency

The workflow embeds `<!-- release-notes: sha=<GITHUB_SHA> -->` in the PR body of every
CHANGELOG PR it opens. On re-run, it searches for open PRs matching this marker before
opening a new one. If a matching PR exists, the run is a no-op.

### CHANGELOG format (Keep-a-Changelog)

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Brief description of the feature (#PR-number)

### Fixed
- Brief description of the fix (#PR-number)
```

### DRY_RUN (staged) output

Step summary includes:
- Push SHA range processed
- Merged PRs found (all labels)
- PRs included in CHANGELOG (filtered)
- Generated CHANGELOG block (what would be prepended)
- PR title and branch name that would be created

## Output

| Mode | Output |
|---|---|
| `DRY_RUN=true` | Step summary with generated content; no branch or PR created |
| `DRY_RUN=false` | Branch created, CHANGELOG updated, PR opened |

## Going live

1. Verify staged step summaries produce correctly formatted CHANGELOG entries
2. Set repo variable `DRY_RUN=false`
3. Update workflow permissions to `contents: write`, `pull-requests: write`
4. Remove this note after first successful live run
