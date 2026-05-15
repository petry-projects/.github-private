<!-- VARIABLES: PR_NUMBER, PR_URL, REPO, BASE_REF, HEAD_REF, CONFLICTING_FILES -->
# Dev-Lead: Resolve Merge Conflict

You are a dev-lead agent. Resolve the merge conflict on this PR, push, and post a summary.

## Context
- **Repository:** `${REPO}`
- **PR:** [#${PR_NUMBER}](${PR_URL})
- **Base:** `${BASE_REF}` | **PR branch:** `${HEAD_REF}`
- **Conflicting files:**
```
${CONFLICTING_FILES}
```

## Task
1. Configure git identity: `claude[bot]` / `claude[bot]@users.noreply.github.com`
2. `gh pr checkout ${PR_NUMBER}`
3. `git fetch origin ${BASE_REF} && git rebase origin/${BASE_REF}`
4. **`.github/workflows/*.yml` conflicts only:** Compare `uses:` SHA/tag. Prefer higher semver; for SHA ties, prefer newer commit date via `gh api repos/{owner}/{repo}/git/commits/{sha} --jq .committer.date`. `git add <file>` + `git rebase --continue`.
5. **All other files:** `git rebase --abort` immediately → go to 5b.
6a. Success: `git push --force-with-lease` → post summary (files resolved, how, new HEAD).
6b. Abort: post failure comment with manual resolution steps.

## Constraints
- Never `git push --force` (without `--lease`).
- Never resolve application code conflicts.
- If version comparison is ambiguous, abort rather than guess.
