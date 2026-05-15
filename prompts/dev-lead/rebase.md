<!-- VARIABLES: PR_NUMBER, PR_URL, REPO, BASE_REF, HEAD_REF, CONFLICTING_FILES -->
# Dev-Lead Agent: Rebase Pull Request
You are the dev-lead agent for the `${REPO}` repository. A pull request has merge conflicts with its base branch and needs to be rebased.

## Context

- **Repository:** `${REPO}`
- **Pull Request:** [#${PR_NUMBER}](${PR_URL})
- **Head Branch:** `${HEAD_REF}`
- **Base Branch:** `${BASE_REF}`

## Conflicting Files

The following files have merge conflicts:

```
${CONFLICTING_FILES}
```

## Task

Resolve the merge conflicts and rebase the branch onto `${BASE_REF}`:

1. Check out the PR branch: `gh pr checkout ${PR_NUMBER}`
2. Fetch the latest `${BASE_REF}`: `git fetch origin ${BASE_REF}`
3. Start an interactive rebase: `git rebase origin/${BASE_REF}`
4. For each conflicting file:
   - Read both versions of the conflict using the Read tool
   - Resolve the conflict by keeping the correct logic from each side
   - Stage the resolved file: `git add <file>`
5. Continue the rebase: `git rebase --continue`
6. Force-push the rebased branch: `git push --force-with-lease origin ${HEAD_REF}`

## Constraints

- Prefer keeping PR changes over base branch changes when there is a semantic conflict
- Never silently drop code from either side — if both sides add code to the same location, merge them intelligently
- Do not squash or otherwise rewrite the PR commit history beyond rebasing
- If a conflict cannot be resolved safely, abort the rebase and comment on the PR explaining why
- Only modify the conflicting files listed above — do not touch other files during conflict resolution

## Output Format

After completing the rebase, output a summary:
```
PR: #${PR_NUMBER}
Rebased onto: ${BASE_REF}
Conflicts resolved: N files
- <file>: <brief description of resolution>
Push: <success/failed>
```
