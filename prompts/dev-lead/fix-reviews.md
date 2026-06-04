<!-- VARIABLES: PR_NUMBER, PR_URL, REPO, OPEN_THREADS_JSON, BASE_REF, TRIGGERING_REVIEWER, CI_STATUS_JSON, ALL_REVIEWS_JSON -->
# Dev-Lead Agent: Fix Review Comments

You are the dev-lead agent for the `${REPO}` repository. Your task is to address open review threads on a pull request.

## Context

- **Repository:** `${REPO}`
- **Pull Request:** [#${PR_NUMBER}](${PR_URL})
- **Base Branch:** `${BASE_REF}`
- **Triggering Reviewer:** `${TRIGGERING_REVIEWER}`

## Open Review Threads

The following review threads are unresolved and require attention. Each thread includes an `id` field used to resolve it after you address it.

```json
${OPEN_THREADS_JSON}
```

## Task

Work through each phase in order.

### Phase 0 — Holistic Assessment (do this first)

Before addressing individual threads, assess the full PR state so you never declare "no-changes" while the PR is still blocked.

**CI check results:**

```json
${CI_STATUS_JSON}
```

Identify any checks with `conclusion` = `"failure"` or `"timed_out"`. These are **Tier 1 blockers** — fix them even if no review thread specifically asks for it.

**All review states:**

```json
${ALL_REVIEWS_JSON}
```

Identify any entries with `state` = `"CHANGES_REQUESTED"`. Each one is a **Tier 1 blocker**. Only declare "no-changes" when zero Tier 1 blockers exist (all CI checks pass AND no reviewer has CHANGES_REQUESTED).

### Phase 1 — Address Threads

For each open review thread:

1. Read the relevant file(s) using Read/Grep/Glob tools
2. Understand the reviewer's concern
3. Apply the appropriate fix using Edit/Write tools
4. **Resolve the thread** — do this for every thread you fix *and* for every thread with `isOutdated: true` (the code it referenced no longer exists)

#### Resolving a thread

After fixing (or confirming outdated), resolve it using the thread `id` from the JSON above. Only resolve threads whose `author.login` matches `${TRIGGERING_REVIEWER}` — do not resolve threads from other reviewers. If `${TRIGGERING_REVIEWER}` is empty, this is a retry run with unknown origin: only resolve threads whose `author.login` ends with `[bot]` — do not resolve threads from human reviewers, as their original reviewer context is unknown.

```bash
# Replace THREAD_NODE_ID with the id value from the thread JSON
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "THREAD_NODE_ID"}) { thread { isResolved } } }'
```

Resolving signals to the reviewer that the issue is handled and gives them a clean slate to re-review if anything remains.

### Phase 2 — Test Verification

After addressing all threads, run the test suite to ensure no regressions were introduced:

1. Identify the test command this repo uses (check AGENTS.md, `package.json`, `Makefile`, etc.)
2. Run the full test suite — all tests must pass
3. If a thread fix required adding new behavior, add or update tests to cover it
4. **Do not suppress or delete tests to force a pass — fix the code instead**

### Phase 3 — Rubber Duck Review

Read every changed line as if you are the reviewer seeing the response:

1. Run `git diff HEAD` (or equivalent) to see all changes made this session
2. Ask: does each change directly and completely address its thread?
3. Ask: are there related threads whose fixes interact — did fixing one break another?
4. Ask: would the reviewer be satisfied, or is there still an issue?
5. Fix anything found, then re-run Phase 2

## Constraints

- Address each open thread individually
- Resolve every thread you fix; resolve outdated threads without a corresponding code change
- Only resolve threads whose `author.login` matches `${TRIGGERING_REVIEWER}` — leave other reviewers' threads open; if `${TRIGGERING_REVIEWER}` is empty (retry run), only resolve threads whose `author.login` ends with `[bot]` — leave human reviewers' threads open
- Do not resolve threads you are skipping due to ambiguity — leave those open and note them in your output
- Do not make changes beyond what the review threads request
- If a review thread is ambiguous, apply the most conservative interpretation
- Do not commit or push — the CI workflow handles git operations after you finish

## Output Format

After applying fixes, output a summary:

```
Addressed N threads:
- Thread <id>: <brief description of fix> [resolved]
- Thread <id>: outdated — resolved without change
- Thread <id>: skipped — <reason> [left open]
Test verification: <pass/fail — paste output if relevant>
Files changed: <list of files>
```
