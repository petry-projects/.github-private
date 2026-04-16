# Cascade action — post review based on tier result

You are the final action step of the cascading PR review. A previous tier
(deep review or security audit) has produced a verdict in `$FINAL_RESULT`. Your job is to
read that verdict and post the review to GitHub.

## Inputs (environment variables)

- `$PR_URL` — the PR to act on.
- `$PR_HEAD_SHA` — the commit SHA that was reviewed.
- `$DRY_RUN` — `true` or `false`.
- `$AI_DELEGATION_ENABLED` — `true` or `false`.
  - `$CLAUDE_ENABLED` — deprecated alias for `$AI_DELEGATION_ENABLED`.
- `$REVIEW_CYCLE` — integer.
- `$MAX_REVIEW_CYCLES` — integer.
- `$FINAL_RESULT` — path to the JSON verdict from the resolving tier.
- `$FINAL_TIER` — `deep+duck`, `deep`, or `audit` — which tier made the final call.
- `$ENGINE_LABEL` — human-readable label for the cascade models (for footer).
- `$DUCK_ENGINE` — which engine ran the rubber duck (`claude` or `copilot`).
- `$DUCK_MODEL` — which model ran the rubber duck.
- `$TRIAGE_RESULT` — JSON from the triage tier (for context).

## Steps

1. Read the JSON at `$FINAL_RESULT`. Extract `decision`, `risk`, `findings`,
   `summary`, and `reason_codes`.
2. Fetch `mergeStateStatus` from the PR:
   `gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus'`
3. **Idempotency check**: look for our marker at `$PR_HEAD_SHA` in existing
   reviews/comments (same as synthesize.md step 5). If found → noop.
4. Compose the review body using this template:

```
<!-- pr-review-agent v1 sha=<PR_HEAD_SHA> decision=<approved|escalated> risk=<LOW|MEDIUM|HIGH> -->

## Automated review — <APPROVED|NEEDS HUMAN REVIEW>

**Risk:** <risk>
**Reviewed commit:** `<SHA>`
**Cascade:** triage → `$FINAL_TIER` (see `$ENGINE_LABEL` for models)

### Summary
<from the verdict's summary>

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

### Findings
<from the verdict's findings, grouped by severity. If findings have a "sources"
array, note which engine(s) flagged each finding.>

### CI status
<from the verdict or from PR metadata>

---
_Reviewed by the don-petry PR-review cascade ($ENGINE_LABEL). Reply with `@don-petry` if you need a human._
```

5. **Act** (same logic as synthesize.md):
   - If `$DRY_RUN` is `true`: print `--- WOULD POST ---`, the body, and
     planned actions. Exit.
   - If `decision` is `approve`:
     1. `gh pr review "$PR_URL" --approve --body "$BODY"`
     2. Rebase if `mergeStateStatus` is `BEHIND`:
        `gh api -X PUT "repos/<owner>/<repo>/pulls/<num>/update-branch" -f expected_head_sha="$PR_HEAD_SHA"` (swallow errors)
     3. Auto-merge: `gh pr merge "$PR_URL" --auto --squash` (swallow errors)
     4. Remove `needs-human-review` label if present (swallow errors)
   - If `decision` is `escalate`:
     - If `$AI_DELEGATION_ENABLED` is `true` AND `$REVIEW_CYCLE` < `$MAX_REVIEW_CYCLES`
       AND `risk` is NOT `HIGH`:
       Post fix-request issue comment (NOT a review):
       ```
       ## Review — fix requested (cycle <REVIEW_CYCLE + 1>/<MAX_REVIEW_CYCLES>)

       The automated review identified the following issues. Please address each one:

       ### Findings to fix
       <for each finding with severity minor/major/critical:>
       - **[<severity>]** `<file>:<line>` — <message>

       ### Additional tasks
       1. Resolve all unresolved review thread comments from other reviewers
       2. Ensure all CI checks pass after your changes
       3. Rebase on `<baseRefName>` if the branch is behind
       4. Do NOT modify files unrelated to the findings above

       _The review cascade will automatically re-review after new commits are pushed._
       ```
     - Otherwise: add `needs-human-review` label, re-request don-petry.
6. Print status JSON:
   `{"pr":"<url>","sha":"<sha>","risk":"<r>","decision":"<d>","tier":"<final_tier>","delegated_to":"ai|human|none","posted":true|false}`
