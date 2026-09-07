# Dependency Advisory

**Workflow:** `dependency-advisory.yml`
**Priority:** P2
**Trigger:** `pull_request` — touching dependency manifest files
**Scenario spec:** [`tests/aw/dependency-advisory/scenarios.md`](../../tests/aw/dependency-advisory/scenarios.md)

---

## Purpose

Provide AI-powered risk assessment for dependency changes in pull requests, going beyond
what Dependabot supplies. It flags major version bumps, packages with known CVEs,
newly added packages with poor maintenance signals, and unusual transitive dependency
introductions.

---

## Trigger

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened]
    paths:
      - 'package.json'
      - 'package-lock.json'
      - 'yarn.lock'
      - 'go.mod'
      - 'go.sum'
      - 'requirements.txt'
      - 'Pipfile'
      - 'Pipfile.lock'
      - 'Gemfile'
      - 'Gemfile.lock'
      - 'Cargo.toml'
      - 'Cargo.lock'
      - 'pyproject.toml'
      - 'pom.xml'
      - 'build.gradle'
      - 'build.gradle.kts'
```

---

## Architecture

```
pull_request (dep file touched)
  └── advisory job
        ├── checkout PR branch
        ├── get PR diff for dep files only (gh pr diff)
        ├── extract: added/removed packages and version changes
        ├── claude --print: risk assessment of each change
        └── post PR comment with findings
```

---

## Configuration

| Variable | Source | Default | Description |
|----------|--------|---------|-------------|
| `GH_TOKEN` | `secrets.GH_PAT_DON_PETRY` or `secrets.GH_PAT_WORKFLOWS` or `GITHUB_TOKEN` | — | Token for PR comment |
| `CLAUDE_CODE_OAUTH_TOKEN` | `secrets.CLAUDE_CODE_OAUTH_TOKEN` | — | Claude auth token |
| `SKIP_BOT_PRS` | `vars.DEP_ADVISORY_SKIP_BOT_PRS` | `true` | Skip Dependabot/Renovate PRs |
| `DEP_ADVISORY_MAX_ATTEMPTS` | env | `3` | Total Claude attempts before a transient failure degrades gracefully |
| `DEP_ADVISORY_RETRY_BASE_SEC` | env | `5` | Base backoff (exponential) between transient retries |

---

## Outputs

A PR comment is posted by the bot with the following structure:

```markdown
## Dependency Advisory

| Package | Change | Risk | Notes |
|---------|--------|------|-------|
| lodash  | 4.17.19 → 4.17.21 | LOW | Patch; no breaking changes |
| express | 4.18.0 → 5.0.0   | HIGH | Major version; review migration guide |

### Details
...
```

### Risk levels

| Level | Criteria |
|-------|----------|
| `LOW` | Patch or minor bump from a well-maintained package; lockfile-only change |
| `MEDIUM` | Minor bump introducing new APIs or deprecation; new transitive deps |
| `HIGH` | Major version bump; package with recent CVE disclosure |
| `CRITICAL` | Package with active CVE; known supply-chain risk; abandoned package |

---

## Bot PR handling

When the PR author is `dependabot[bot]` or `renovate[bot]`, the workflow runs with
reduced scope: it skips the comment for `LOW` risk changes and only posts for `MEDIUM`
and above. This reduces noise on routine Dependabot maintenance PRs.

Set `DEP_ADVISORY_SKIP_BOT_PRS=true` to skip entirely for bot PRs.

---

## Script

See [`scripts/aw-dependency-advisory.sh`](../../scripts/aw-dependency-advisory.sh).

---

## Permissions

```yaml
permissions:
  contents: read
  pull-requests: write
```

---

## Runbook

**Comment posted but assessment is wrong:**
The Claude model may lack up-to-date CVE data. Use it as a signal, not a gate. File
a correction as a reply to the advisory comment.

**Workflow not triggering on a dep change:**
Verify the changed file matches the `paths:` filter. Lockfile-only changes in
subdirectories may not match — extend the `paths:` list if needed.

**Duplicate comments on re-push:**
The script checks for an existing advisory comment before posting. If a duplicate
appears, the dedup logic may have failed — check `scripts/aw-dependency-advisory.sh`.

**Workflow failed on `API Error: 529 Overloaded` (or another transient error):**
A transient/server-side Claude error (`529`, `429`, `5xx`, timeout) is retried with
exponential backoff up to `DEP_ADVISORY_MAX_ATTEMPTS`. If it persists across all
attempts the advisory degrades gracefully — it emits a `::warning::` and exits `0`
rather than failing this non-gating check. A genuinely non-transient error still
fails the run. Tune retries via `DEP_ADVISORY_MAX_ATTEMPTS` /
`DEP_ADVISORY_RETRY_BASE_SEC`.
