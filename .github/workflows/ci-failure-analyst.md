---
on:
  check_run:
    types: [completed]

permissions:
  actions: read
  checks: read
  contents: read

engine: claude

models:
  claude: [claude-sonnet-4-6]

tools:
  github:
    toolsets: [context, pull_requests, actions]

network: defaults

safe-outputs:
  add-comment:
    max: 1
---

# CI Failure Analyst

When a CI check run completes with `conclusion: failure` on a non-fork PR, diagnose the failure
and post a single root-cause comment on the associated pull request.

> **Deployed runtime.** The live CI Failure Analyst in this repo is **not** a compiled
> gh-aw workflow — it is the byte-frozen ring-0 thin caller
> `.github/workflows/ci-failure-analyst.lock.yml`, which triggers on `check_run:[completed]`,
> posts **live** (declaring `issues: write` + `pull-requests: write`), and delegates all logic to
> `ci-failure-analyst-reusable.yml@ci-failure-analyst/v1-stable`. This `.md` is the gh-aw source
> retained alongside that stub (the `gh-aw-compile` orphaned-lock detector requires a sibling
> `.md` for every `*.lock.yml`). The spec's `on:` trigger and comment posture are kept in sync
> with the deployed stub — `check_run:[completed]`, one comment per failing head SHA — but
> permission models differ: the deployed stub carries live `issues: write` + `pull-requests: write`,
> while this spec uses `safe-outputs.add-comment` (gh-aw strict mode disallows raw write
> permissions). Do **not** edit the frozen `.lock.yml` block (caller-stub-freeze,
> AGENTS.md). For the full deployed architecture and permission table see
> [`docs/aw/ci-failure-analyst.md`](../../docs/aw/ci-failure-analyst.md); for the machine-readable
> interaction contract see
> [`interaction-contracts/ci-failure-analyst.yml`](../../interaction-contracts/ci-failure-analyst.yml).

## Instructions

Follow these steps in order.

### 1. Guard: conclusion must be `failure` and this must not be the analyst's own check

Check `github.event.check_run.conclusion`. If it is anything other than `failure`
(e.g. `cancelled`, `skipped`, `success`, `neutral`), output a `noop` action and stop.
Do not post any comment.

Also skip the analyst's own check run to prevent loops: if
`github.event.check_run.name` starts with `CI Failure Analyst`, output a `noop` and stop.

### 2. Guard: the check run must be associated with a non-fork PR

Check `github.event.check_run.pull_requests`. If the array is empty, resolve the PR from the
commits-to-pulls API (`repos/{owner}/{repo}/commits/{head_sha}/pulls`) as a fallback. If no open
PR is found, output a `noop` and stop. Do not comment on issues or any other thread.

Filter to **non-fork** PRs only (the PR's head repo must equal the base repo). A fork PR is a
`noop`.

### 3. Identify the target PR

Use the first non-fork PR. Note:

- PR number
- Head SHA: `github.event.check_run.head_sha`
- Check run name: `github.event.check_run.name`
- Details URL: `github.event.check_run.details_url` (fall back to `github.event.check_run.html_url`)
- Check run ID: `github.event.check_run.id`

### 4. Check for an existing analyst comment (idempotency)

List comments on the PR and search for one that starts with the exact marker:

```
<!-- ci-analyst sha=HEAD_SHA -->
```

where `HEAD_SHA` is the check run's `head_sha`. If a comment with this marker already
exists, output a `noop` and stop. Do not post a duplicate comment.

### 5. Fetch failure details

Use the failed check run / its workflow run with the actions toolset to retrieve the run logs.
Parse the logs to find the failing job and step.

If logs are unavailable (e.g. the run has expired), note this in the comment and
provide a best-guess diagnosis from the check run name and any available context.

### 6. Identify the failing step and error

From the logs, extract:

- The name of the specific step that failed
- The key error message or assertion that caused the failure

### 7. Classify the root cause

Choose the single best-fit category:

| Category | Indicators |
|---|---|
| **Test failure** | Assertion failed, test output shows `FAIL`, `AssertionError`, `Expected … got …` |
| **Env issue** | Missing secret, missing env var, `command not found`, `permission denied`, authentication error |
| **Flaky test** | Timeout, connection reset, port conflict, `ECONNREFUSED`, intermittent HTTP error |
| **Config error** | Malformed workflow YAML, missing required field, `invalid syntax`, wrong runner |
| **Lint/style** | `eslint`, `shellcheck`, `markdownlint`, `yamllint`, `ruff`, `golangci-lint` errors |
| **Build error** | Compilation error, `npm ERR!`, `cargo build` failed, dependency resolution failure |

If the check run name is `lint`, `shellcheck`, `markdownlint`, `yamllint`, or similar, the
category **must** be Lint/style — do not classify it as Test failure.

### 8. Post the diagnostic comment

Post a comment to the PR (identified in Step 3 by PR number) using exactly this structure:

```markdown
<!-- ci-analyst sha=HEAD_SHA -->
## CI Failure: CHECK_RUN_NAME

**Step:** FAILING_STEP_NAME
**Root cause:** ROOT_CAUSE_CATEGORY

BRIEF_EXPLANATION (2–3 sentences: what failed, why it likely failed, what the error means)

**Suggested fix:** ONE_CONCRETE_ACTION

[View run logs](DETAILS_URL)
```

Rules:
- The `<!-- ci-analyst sha=... -->` marker **must** be the very first line of the comment.
- Root cause category must be one of the six categories defined above.
- Suggested fix must be one specific, actionable step (e.g. "Run `npm test` locally and fix the failing assertion in `src/auth.test.js`", not "Fix the tests").
- Keep the entire comment under 300 words.
- Do not include any information beyond this structure.
- Pass the PR number explicitly when invoking the `add-comment` safe output.
