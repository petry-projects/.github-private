# CI Failure Analyst

Agentic workflow that diagnoses CI failures and posts a root-cause comment on the associated pull request within 2 minutes.

## What it does

When a check run completes with `conclusion: failure`, the workflow:

1. Fetches the failed run logs from the GitHub API
2. Identifies the specific step that failed and its error message
3. Classifies the root cause into one of six categories
4. Posts a structured diagnostic comment on the PR (or updates an existing analyst comment for the same SHA — no duplicates)

If the check run is not associated with a PR, or if the conclusion is anything other than `failure`, the workflow is a no-op.

## Trigger

```yaml
on:
  workflow_run:
    workflows: [CI, Lint, Tests]
    types: [completed]
```

The workflow handles `conclusion != failure` as a no-op in its instructions. The `workflow_run` trigger fires for GitHub Actions workflow completions, including this repo's own CI workflows (`ci.yml`, `lint.yml`, `test.yml`). The analyst itself guards on conclusion.

## Root cause categories

| Category | Indicators |
|---|---|
| **Test failure** | Assertion failed, `FAIL`, `AssertionError`, `Expected … got …` |
| **Env issue** | Missing secret/env var, `command not found`, `permission denied`, auth error |
| **Flaky test** | Timeout, `ECONNREFUSED`, connection reset, intermittent HTTP error |
| **Config error** | Malformed YAML, missing required field, wrong runner, `invalid syntax` |
| **Lint/style** | `eslint`, `shellcheck`, `markdownlint`, `yamllint`, `ruff` errors |
| **Build error** | Compilation error, `npm ERR!`, dependency resolution failure |

## Comment format

The analyst posts (or updates) a comment on the PR with this structure:

```markdown
<!-- ci-analyst sha=<HEAD_SHA> -->
## CI Failure: <check name>

**Step:** <failing step name>
**Root cause:** <category>

<2–3 sentence explanation>

**Suggested fix:** <one concrete action>

[View run logs](<details_url>)
```

The `<!-- ci-analyst sha=... -->` marker enables idempotency: if the workflow triggers again for the same SHA, it updates the existing comment instead of creating a duplicate.

## Permissions

| Permission | Reason |
|---|---|
| `actions: read` | Fetch workflow run logs via the actions toolset |
| `checks: read` | Read check run details and annotations |
| `contents: read` | Check out the repository for agent context |
| `pull-requests: read` | List PR comments for idempotency check |

Write access (posting the comment) is handled by the `safe-outputs` job using the `GH_AW_GITHUB_TOKEN` secret (or `GITHUB_TOKEN` as a fallback). The `safe-outputs` job runs with `permissions: {}` and relies on an external token for the write operation, so `GITHUB_TOKEN` alone is not sufficient without `GH_AW_GITHUB_TOKEN` set.

## Engine and model

- **Engine:** Claude (via `engine: claude`)
- **Model:** Configured via the `GH_AW_MODEL_AGENT_CLAUDE` repository variable. Set it to `claude-sonnet-4-6` to use the recommended model. If unset, the engine defaults to `auto`.

## Staged mode

The `add-comment` safe-output is configured with `staged: true`. During the initial rollout, posted comments are queued for human review before being published. Remove `staged: true` from the `add-comment` block in the workflow frontmatter once the output has been verified against the scenario spec.

## Setup

1. Ensure the `ANTHROPIC_API_KEY` secret is set in the repository (or org-level secrets).
2. Set `GH_AW_GITHUB_TOKEN` to a PAT with `pull-requests: write` permission. This token is used by the `safe-outputs` job to post the diagnostic comment. Without it, `GITHUB_TOKEN` will be used as a fallback but will lack write permission (the `safe-outputs` job runs with `permissions: {}`).
3. Optionally set `GH_AW_GITHUB_MCP_SERVER_TOKEN` to a PAT for MCP GitHub API access. Falls back to `GH_AW_GITHUB_TOKEN`, then `GITHUB_TOKEN`.
4. Set the `GH_AW_MODEL_AGENT_CLAUDE` repository variable to `claude-sonnet-4-6`.
5. Compile the workflow: `gh aw compile ci-failure-analyst --approve`.
6. Commit both `ci-failure-analyst.md` and `ci-failure-analyst.lock.yml`.

## Scenario spec

See [`tests/aw/ci-failure-analyst/scenarios.md`](../../tests/aw/ci-failure-analyst/scenarios.md) for the full scenario spec used to verify correct behavior, including edge cases for non-failure conclusions, PRs without associated check runs, and duplicate-comment suppression.

## Relationship to dev-lead

The CI Failure Analyst is a **read-only diagnostic** agent. It posts comments but does not push commits or open PRs. The `dev-lead` agent retains exclusive write authority for applying actual fixes to failing CI.
