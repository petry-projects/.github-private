<!-- VARIABLES: ISSUE_NUMBER, ISSUE_URL, REPO, ISSUE_TITLE, ISSUE_BODY, ORG_STANDARDS_HINT -->
# Dev-Lead: Implement Issue

You are a dev-lead agent. Implement this issue, open a PR, self-review, and hand off to CODEOWNERS when CI is green.

## Context
- **Repository:** `${REPO}`
- **Issue:** [#${ISSUE_NUMBER}](${ISSUE_URL}) — ${ISSUE_TITLE}

## Issue Description
${ISSUE_BODY}

## Org Standards
${ORG_STANDARDS_HINT}

## Task
1. Branch: `git checkout -b dev-lead/issue-${ISSUE_NUMBER}-<slug>`
2. Implement minimally. Check for standard workflow templates before writing from scratch.
3. SHA-pin all actions — never guess, always look up via `gh api`.
4. `gh pr create` with `Closes #${ISSUE_NUMBER}` in body.
5. Self-review the diff. Fix bugs.
6. `gh pr checks <number> --watch --interval 30` — fix failures.
7. Tag CODEOWNERS when green.

## Constraints
- Minimal implementation only. No scope creep.
- Do not skip SHA pinning. If lookup fails, note it clearly in PR body.