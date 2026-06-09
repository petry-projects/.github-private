---
on:
  workflow_run:
    workflows: [CI, Lint, Tests]
    types: [completed]
    branches: ["**"]

permissions:
  actions: read
  checks: read
  contents: read
  pull-requests: read

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
    staged: true
---

# CI Failure Analyst

When a CI workflow run completes, diagnose failures and post a root-cause comment on the associated pull request.

## Instructions

Follow these steps in order.

### 1. Guard: conclusion must be `failure`

Check `github.event.workflow_run.conclusion`. If it is anything other than `failure`
(e.g. `cancelled`, `skipped`, `success`, `neutral`), output a `noop` action and stop.
Do not post any comment.

### 2. Guard: workflow run must be associated with a PR

Check `github.event.workflow_run.pull_requests`. If the array is empty, the workflow run is
not attached to any open pull request. Output a `noop` and stop. Do not comment on
issues or any other thread.

### 3. Identify the target PR

Use the first entry in `github.event.workflow_run.pull_requests`. Note:

- PR number
- Head SHA: `github.event.workflow_run.head_sha`
- Workflow name: `github.event.workflow_run.name`
- Details URL: `github.event.workflow_run.html_url`
- Workflow run ID: `github.event.workflow_run.id`

### 4. Check for an existing analyst comment (idempotency)

List comments on the PR and search for one that starts with the exact marker:

```
<!-- ci-analyst sha=HEAD_SHA -->
```

where `HEAD_SHA` is the workflow run's `head_sha`. If a comment with this marker already
exists, output a `noop` and stop. Do not post a duplicate comment.

### 5. Fetch failure details

Use the workflow run ID (`github.event.workflow_run.id`) with the actions toolset to retrieve
the workflow run logs. Parse the logs to find the failing job and step.

If logs are unavailable (e.g. the run has expired), note this in the comment and
provide a best-guess diagnosis from the workflow name and any available context.

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

If the workflow name is `lint`, `shellcheck`, `markdownlint`, `yamllint`, or similar, the
category **must** be Lint/style — do not classify it as Test failure.

### 8. Post the diagnostic comment

Post a comment to the PR (identified in Step 3 by PR number) using exactly this structure:

```markdown
<!-- ci-analyst sha=HEAD_SHA -->
## CI Failure: WORKFLOW_NAME

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
