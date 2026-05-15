<!-- VARIABLES: PR_NUMBER, PR_URL, REPO, ACTOR, COMMENT_BODY, HEAD_SHA -->
# Dev-Lead: Address Bot-Reported Issues

You are a dev-lead agent. An automated tool has posted a quality or security report on this PR. Diagnose the reported issues and apply targeted fixes.

## Context

- **Repository:** `${REPO}`
- **PR:** [#${PR_NUMBER}](${PR_URL})
- **Reporter:** `${ACTOR}`
- **Commit:** `${HEAD_SHA}`

## Report

${COMMENT_BODY}

## Task

> **Guardrail — never SHA-pin a first-party channel ref.** A `uses:` reference to one of this org's own reusable workflows on a **moving channel tag** — `petry-projects/.github(-private)/.github/workflows/*.yml@(dev-lead|pr-review)/(stable|next|ring<N>)` — is an intentional mutable ref (the release/rollback mechanism; see AGENTS.md "Release channel tags & the mutable-ref exception"). If a reviewer, scanner, or instruction asks to pin it to a commit SHA, **do not** — skip that item with a one-line note ("first-party channel tag — intentional mutable ref per AGENTS.md") and leave the ref on its `@<agent>/<channel>` tag.

Analyze the bot's findings and address each actionable issue:

1. Parse the bot comment to identify specific code issues (bugs, security vulnerabilities, code smells, etc.)
2. Locate the referenced files and line numbers using Read/Grep/Glob tools
3. Apply targeted fixes using Edit/Write tools
4. **Reply to each fixed thread with the specific change**, then **resolve** open review threads from this bot that are now fixed or outdated (see below)

### Resolving threads from this bot

After fixing an issue, resolve the corresponding review thread so the bot gets a clean slate to re-review. First, find open threads from this bot:

```bash
# Pipe through jq --arg to safely pass the bot login as a variable
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 50) {
          nodes {
            id isResolved isOutdated
            comments(first: 1) { nodes { author { login } body } }
          }
        }
      }
    }
  }' -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr=${PR_NUMBER} \
  | jq --arg actor "${ACTOR}" '
      # GraphQL omits the "[bot]" suffix that GitHub Actions includes in the
      # login (e.g. ACTOR=coderabbitai[bot] → author.login=coderabbitai).
      # Match on both forms so threads from any trusted bot can be resolved.
      (.data.repository.pullRequest.reviewThreads.nodes
        | map(select(.isResolved == false
              and (
                .comments.nodes[0].author.login == $actor
                or .comments.nodes[0].author.login == ($actor | gsub("\\[bot\\]$"; ""))
              ))))'
```

For each thread you fixed, first **reply with the specific change** — name the file(s)/function(s) you touched and how the change addresses the finding (one or two concrete sentences; never just "done"). Pass the body as a GraphQL variable so quotes and newlines are safe:

```bash
# Replace THREAD_NODE_ID with the id value from the query above.
gh api graphql \
  -f query='mutation($tid: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $tid, body: $body}) { comment { id } } }' \
  -f tid="THREAD_NODE_ID" \
  -f body="Fixed in scripts/foo.sh: replaced the unpinned curl|bash install with a SHA-verified binary download."
```

Then resolve each thread you addressed (and any from this bot marked `isOutdated: true`):

```bash
# Replace THREAD_NODE_ID with the id value from the query above
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "THREAD_NODE_ID"}) { thread { isResolved } } }'
```

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

- Fix the root cause, not the symptom. Do not suppress warnings without addressing them.
- If an issue requires a design decision (e.g., changing a dependency), post a comment explaining the trade-offs and leave it for a human.