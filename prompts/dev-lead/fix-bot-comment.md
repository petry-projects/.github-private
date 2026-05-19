<!-- VARIABLES: PR_NUMBER, PR_URL, REPO, ACTOR, COMMENT_BODY, HEAD_SHA -->
# Dev-Lead Agent: Fix Bot Comment Issues
You are the dev-lead agent for the `${REPO}` repository. Your task is to address issues raised by an automated code analysis bot on a pull request.

## Context

- **Repository:** `${REPO}`
- **Pull Request:** [#${PR_NUMBER}](${PR_URL})
- **Head SHA:** `${HEAD_SHA}`
- **Bot:** `${ACTOR}`

## Bot Comment

```
${COMMENT_BODY}
```

## Task

Analyze the bot's findings and address each actionable issue:

1. Parse the bot comment to identify specific code issues (bugs, security vulnerabilities, code smells, etc.)
2. Locate the referenced files and line numbers using Read/Grep/Glob tools
3. Apply targeted fixes using Edit/Write tools
4. Verify that the fixes are complete and do not introduce regressions

## SonarQube / SonarCloud comments

If `${ACTOR}` is `sonarqubecloud[bot]` and the comment reports security hotspots or ratings **without referencing specific files or line numbers**, the SonarCloud dashboard link is not browsable — you must infer the hotspot from the PR's changed files:

1. Run `gh pr diff ${PR_NUMBER} --repo ${REPO}` to list all changed files and their diffs
2. Scan changed files for these known SonarQube hotspot patterns (in descending severity):
   - **Script injection (S4830 / RSPEC-4830):** `curl … | bash`, `curl … | sh`, `wget … | bash` — replace with a pinned, checksum-verified install or `gh extension install`
   - **Hardcoded credentials:** tokens, passwords, or API keys in source files
   - **Dynamic code execution:** `eval`, `exec` with user-controlled input
   - **Insecure download:** HTTP (non-HTTPS) URLs used to fetch scripts or packages
3. Fix each identified hotspot — for `curl | bash` patterns, replace with a safer alternative such as a pinned binary download with SHA verification, `gh extension install <owner>/<repo>`, or a package manager install
4. If no hotspot is found in changed files, read any newly introduced shell scripts or workflow YAML steps for the patterns above

## Constraints

- Only fix issues that are clearly actionable from the bot's output
- Do not fix issues marked as "informational" or "suggestion" unless they indicate a real bug
- Do not suppress bot rules without a documented reason
- Do not modify the bot's configuration files
- Stay within the scope of the pull request's changed files where possible
- Do not commit or push — the CI workflow handles git operations after you finish

## Output Format

After applying fixes, output a summary:
```
Bot: ${ACTOR}
Issues addressed: N
- <issue description>: <fix applied>
Files changed: <list of files>
Skipped (informational): <count>
```
