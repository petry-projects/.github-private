# Cascade action — post review based on tier result

You are the final action step of the cascading PR review. A previous tier
(Sonnet or Opus) has produced a verdict in `$FINAL_RESULT`. Your job is to
read that verdict and post the review to GitHub.

## Inputs (environment variables)

- `$FINAL_RESULT` — path to verdict JSON from the resolving tier
- `$OUTPUT_FILE` — path where you MUST write the final verdict JSON
- `$PR_HEAD_SHA` — commit SHA that was reviewed
- `$FINAL_TIER` — which tier made the final call (deep+duck, deep, or audit)
- `$ENGINE_LABEL` — human-readable label for cascade models
- `$DUCK_ENGINE` — rubber duck engine (claude or copilot)
- `$DUCK_MODEL` — rubber duck model
- `$TRIAGE_RESULT` — triage verdict for context
- `$DOWNSTREAM_IMPACT_FILE` — (optional; set only when the downstream-impact pass
  is enabled) path to the `DOWNSTREAM_IMPACT` block listing the downstream consumer
  repos that pin a reusable workflow / shell lib / prompt this PR changes. May be
  the literal `(none)`. Used to surface an impacted-consumers note in the body.

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
**Cascade:** triage(haiku) → <sonnet|sonnet → opus>

### Summary
<from the verdict's summary>

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

### Findings
<from the verdict's findings, grouped by severity>

### CI status
<from the verdict or from PR metadata>

---
_Reviewed by the don-petry PR-review cascade (triage: haiku 4.5 → deep: sonnet 4.6 → audit: opus 4.6). Reply with `@don-petry` if you need a human._
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
     - If `$CLAUDE_ENABLED` is `true` AND `$REVIEW_CYCLE` < `$MAX_REVIEW_CYCLES`
       AND `risk` is NOT `HIGH`:
       Post fix-request issue comment (NOT a review):
       ```
       ## Review council — fix requested (cycle <REVIEW_CYCLE + 1>/<MAX_REVIEW_CYCLES>)

       The automated review identified the following issues. Please address each one:

       ### Findings to fix
       <for each finding with severity minor/major/critical:>
       - **[<severity>]** `<file>:<line>` — <message>

If `$DOWNSTREAM_IMPACT_FILE` is set, the file exists, and its contents are not the
literal `(none)`, insert a **Downstream impact** section before Findings so the
reviewer sees the blast radius right in the verdict (issue #752). When the block
is absent or `(none)`, add nothing — the body must carry no downstream note:
```bash
if [ -n "${DOWNSTREAM_IMPACT_FILE:-}" ] && [ -f "$DOWNSTREAM_IMPACT_FILE" ]; then
  DI_BLOCK=$(cat "$DOWNSTREAM_IMPACT_FILE")
  if [ -n "${DI_BLOCK//[[:space:]]/}" ] && [ "$DI_BLOCK" != "(none)" ]; then
    # Count impacted consumer repos (lines naming a "<owner>/<repo> (pins ...)").
    DI_COUNT=$(printf '%s\n' "$DI_BLOCK" | grep -cE '^[[:space:]]*- .+ \(pins ' || true)
    DI_NOTE="This change is consumed by ${DI_COUNT} downstream repo(s) that pin the affected reusable workflow / lib / prompt. Impacted consumers:"$'\n'"\`\`\`"$'\n'"${DI_BLOCK}"$'\n'"\`\`\`"
    # Write the note to a temp file and splice it in (avoids sed metachar issues
    # with the multi-line block).
    printf '### Downstream impact\n%s\n\n### Findings\n' "$DI_NOTE" > /tmp/cascade/di-section.txt
    awk 'BEGIN{while((getline l < "/tmp/cascade/di-section.txt")>0) s=s l "\n"} /^### Findings$/{if(s != "") printf "%s", s; else print; next} {print}' \
      /tmp/cascade/review-body.txt > /tmp/cascade/review-body.tmp && mv /tmp/cascade/review-body.tmp /tmp/cascade/review-body.txt
  fi
fi
```

3. Write the final verdict JSON to `$OUTPUT_FILE` using jq so all strings are properly escaped:
```bash
BODY=$(cat /tmp/cascade/review-body.txt)
jq -n \
  --arg decision "$DECISION" \
  --arg risk "$RISK" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  --arg body "$BODY" \
  --argjson escalate_to_ai "$ESCALATE_TO_AI" \
  '{decision: $decision, risk: $risk, summary: $summary, findings: $findings, body: $body, escalate_to_ai: $escalate_to_ai}' \
  > "$OUTPUT_FILE"
```

       _The review cascade will automatically re-review after new commits are pushed._
       ```
     - Otherwise: add `needs-human-review` label, re-request don-petry.
6. Print status JSON:
   `{"pr":"<url>","sha":"<sha>","risk":"<r>","decision":"<d>","tier":"<final_tier>","delegated_to":"claude|human|none","posted":true|false}`
