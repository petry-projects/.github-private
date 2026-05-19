# Agentic Workflow Tests

This directory contains scenario specs and smoke tests for `gh-aw` agentic workflows.

## Test methodology

Tests follow a three-level approach:

1. **Compile validation (CI gate)** — `gh aw compile` runs on every PR that touches `.github/workflows/*.md`. A compile failure blocks merge. No runtime required.

2. **Staged smoke tests (pre-merge)** — Run a workflow against a fixture payload without posting real GitHub API side-effects. Use `--dry-run` to validate without executing side-effects:
   ```
   gh aw run <workflow-name> --dry-run -F payload=@tests/aw/<workflow-name>/fixtures/<fixture>.json
   ```
   Smoke tests assert that the workflow reaches the expected terminal state and produces the expected output structure.

3. **Integration tests (manual / scheduled)** — Execute against a real GitHub event in a sandbox repo. Reserved for release-gate validation; not required on every PR.

## Scenario spec format

Write scenario specs **before** the workflow markdown. Each spec lives in `tests/aw/<workflow-name>/` as a plain markdown file:

```
tests/aw/<workflow-name>/
  README.md          ← scenario specs (this pattern)
  fixtures/          ← JSON payloads matching GitHub webhook schemas
  smoke.sh           ← staged smoke test runner (optional)
```

A scenario spec block:

```markdown
### Scenario: <name>

**Given** <precondition>
**When** <event / trigger>
**Then** <expected outcome>

**Fixture:** `fixtures/<name>.json`
```

## Running compile validation locally

```bash
gh extension install github/gh-aw
gh aw compile
```

The compile step validates all `*.md` files in `.github/workflows/` against the gh-aw schema. It does not invoke Claude or make API calls.

## Running staged smoke tests

```bash
# Run a single workflow against a fixture payload
gh aw run issue-triage --dry-run -F payload=@tests/aw/issue-triage/fixtures/new-bug.json

# Run all smoke tests for a workflow
bash tests/aw/issue-triage/smoke.sh
```

## Definition of Done checklist

A workflow is ready to merge when:

- [ ] Scenario specs written in `tests/aw/<name>/README.md` before implementation starts
- [ ] `gh aw compile` passes with no errors
- [ ] At least one fixture payload exists under `tests/aw/<name>/fixtures/`
- [ ] Staged smoke test passes: `gh aw run <name> --dry-run` exits 0
- [ ] CI lint job (`gh-aw-compile`) is green on the PR
- [ ] Workflow markdown reviewed by a second author or the pr-reviewer agent
