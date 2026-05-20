---
on:
  check_run:
    types: [completed]

permissions:
  actions: read
  checks: read
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

When a CI check run completes, diagnose failures and post a root-cause comment on the associated pull request.

## Instructions

Follow these steps in order.

### 1. Guard: conclusion must be `failure`

Check `github.event.check_run.conclusion`. If it is anything other than `failure`
(e.g. `cancelled`, `skipped`, `success`, `neutral`), output a `noop` action and stop.
Do not post any comment.

### 2. Guard: check run must be associated with a PR

Check `github.event.check_run.pull_requests`. If the array is empty, the check run is
not attached to any open pull request. Output a `noop` and stop. Do not comment on
issues or any other thread.

### 3. Identify the target PR

Use the first entry in `github.event.check_run.pull_requests`. Note:

- PR number
- Head SHA: `github.event.check_run.head_sha`
- Check name: `github.event.check_run.name`
- Details URL: `github.event.check_run.details_url`

### 4. Check for an existing analyst comment (idempotency)

List comments on the PR and search for one that starts with the exact marker:

```
<!-- ci-analyst sha=HEAD_SHA -->
```

where `HEAD_SHA` is the check run's `head_sha`. If a comment with this marker already
exists, update it in-place. Do not post a duplicate.

### 5. Fetch failure details

Use the check run ID (`github.event.check_run.id`) to retrieve:

- The list of check run steps / annotations from the GitHub API
- The failed step logs (use the actions toolset to fetch run logs)

If logs are unavailable (e.g. the run has expired), note this in the comment and
provide a best-guess diagnosis from the check name and any available annotations.

### 6. Identify the failing step and error

From the logs or annotations, extract:

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

If the check name is `lint`, `shellcheck`, `markdownlint`, `yamllint`, or similar, the
category **must** be Lint/style — do not classify it as Test failure.

### 8. Post the diagnostic comment

Post a comment to the PR using exactly this structure:

```markdown
<!-- ci-analyst sha=HEAD_SHA -->
## CI Failure: CHECK_NAME

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
