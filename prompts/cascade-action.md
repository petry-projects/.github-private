# Cascade action — finalize verdict and prepare for posting

You are the final step of the cascading PR review. A previous tier (deep review or
security audit) has produced a verdict in `$FINAL_RESULT`. Your job is to:

1. Read the verdict
2. Compose the full review body
3. Write a final JSON to `$OUTPUT_FILE` using the steps below

The review will be posted by the bash script, not by this prompt.

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

1. Read the verdict JSON and extract fields:
```bash
DECISION=$(jq -r '.decision' "$FINAL_RESULT")
RISK=$(jq -r '.risk' "$FINAL_RESULT")
SUMMARY=$(jq -r '.summary' "$FINAL_RESULT")
FINDINGS=$(jq -c '.findings // []' "$FINAL_RESULT")
AGREEMENT=$(jq -r '.agreement // ""' "$FINAL_RESULT")
ESCALATE_TO_AI=$(jq -r 'if .decision == "escalate" and .risk != "HIGH" then "true" else "false" end' "$FINAL_RESULT")
```

2. Compose the review body. Write it to a temp file to avoid shell quoting issues:
```bash
cat > /tmp/cascade/review-body.txt << 'BODYEOF'
<!-- pr-review-agent v1 sha=PLACEHOLDER_SHA decision=PLACEHOLDER_DECISION risk=PLACEHOLDER_RISK -->

## Automated review — PLACEHOLDER_HEADING

**Risk:** PLACEHOLDER_RISK
**Reviewed commit:** `PLACEHOLDER_SHA`
**Cascade:** triage → PLACEHOLDER_TIER (PLACEHOLDER_ENGINE_LABEL)

### Summary
PLACEHOLDER_SUMMARY

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

### Findings
PLACEHOLDER_FINDINGS_LIST

---
_Reviewed by the don-petry PR-review cascade (PLACEHOLDER_ENGINE_LABEL). Reply with `@don-petry` if you need a human._
BODYEOF
```

Replace each PLACEHOLDER with the actual values using sed. Then substitute the real values:
```bash
HEADING=$([ "$DECISION" = "approve" ] && echo "APPROVED ✓" || echo "NEEDS HUMAN REVIEW")
sed -i \
  -e "s|PLACEHOLDER_SHA|$PR_HEAD_SHA|g" \
  -e "s|PLACEHOLDER_DECISION|$DECISION|g" \
  -e "s|PLACEHOLDER_RISK|$RISK|g" \
  -e "s|PLACEHOLDER_HEADING|$HEADING|g" \
  -e "s|PLACEHOLDER_TIER|$FINAL_TIER|g" \
  -e "s|PLACEHOLDER_ENGINE_LABEL|$ENGINE_LABEL|g" \
  -e "s|PLACEHOLDER_SUMMARY|$SUMMARY|g" \
  /tmp/cascade/review-body.txt
```

For findings, format each finding as a bullet and append:
```bash
# Remove the PLACEHOLDER_FINDINGS_LIST line and replace with formatted findings
FINDINGS_TEXT=$(echo "$FINDINGS" | jq -r '.[] | "- **\(.severity // "INFO")**: \(.description // .)"' 2>/dev/null || echo "- No specific findings")
sed -i "s|PLACEHOLDER_FINDINGS_LIST|$FINDINGS_TEXT|g" /tmp/cascade/review-body.txt
```

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

# Step 2: Check if behind and rebase if needed
MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus')
if [ "$MERGE_STATE" = "BEHIND" ]; then
  OWNER_REPO=$(echo "$PR_URL" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  PR_NUM=$(echo "$PR_URL" | sed -E 's|.*/([0-9]+)$|\1|')
  gh api -X PUT "repos/$OWNER_REPO/pulls/$PR_NUM/update-branch" -f expected_head_sha="$PR_HEAD_SHA" 2>/dev/null || true
  
  # Poll for rebase completion (up to 30s)
  for i in 1 2 3 4 5 6; do
    MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus')
    [ "$MERGE_STATE" != "BEHIND" ] && break
    sleep 5
  done
  
  # If still BEHIND, skip auto-merge (will retry next cycle)
  if [ "$MERGE_STATE" = "BEHIND" ]; then
    echo "PR still BEHIND after rebase wait, skipping auto-merge"
    exit 0
  fi
fi

# Step 3: Enable auto-merge (CRITICAL: this triggers the merge once all checks pass)
gh pr merge "$PR_URL" --auto --squash 2>/dev/null || true

# Step 4: Clean up label
gh pr edit "$PR_URL" --remove-label needs-human-review 2>/dev/null || true
```

If `decision` is `"escalate"`:
```bash
# Check if AI delegation is enabled and we haven't exceeded cycle limit
if [ "$AI_DELEGATION_ENABLED" = "true" ] && [ "$REVIEW_CYCLE" -lt "$MAX_REVIEW_CYCLES" ] && [ "$RISK" != "HIGH" ]; then
  # Post fix-request comment (NOT a review) — write to file to handle variable expansion
  COMMENT_FILE="/tmp/pr-comment-$$.txt"
  cat > "$COMMENT_FILE" <<COMMENT_END
## Review — fix requested (cycle $((REVIEW_CYCLE + 1))/$MAX_REVIEW_CYCLES)

The automated review identified the following issues. Please address each one:

### Findings to fix
<for each finding with severity minor/major/critical:>
- **[<severity>]** \`<file>:<line>\` — <message>

### Additional tasks
1. Resolve all unresolved review thread comments from other reviewers
2. Ensure all CI checks pass after your changes
3. Rebase on the target branch if behind
4. Do NOT modify files unrelated to the findings above

_The review cascade will automatically re-review after new commits are pushed._
COMMENT_END

  gh pr comment "$PR_URL" --body "$(cat "$COMMENT_FILE")" || true
  rm -f "$COMMENT_FILE"
else
  # Escalate to human: add label and request review
  gh pr edit "$PR_URL" --add-label needs-human-review 2>/dev/null || true
  gh pr request-review "$PR_URL" --user don-petry 2>/dev/null || true
fi
```
6. Print status JSON (always, even in dry-run):
```bash
echo "{\"pr\":\"$PR_URL\",\"sha\":\"$PR_HEAD_SHA\",\"risk\":\"$RISK\",\"decision\":\"$DECISION\",\"tier\":\"$FINAL_TIER\",\"delegated_to\":\"$([ \"$AI_DELEGATION_ENABLED\" = \"true\" ] && echo 'ai' || echo 'human')\",\"posted\":true}"
```

Then exit with code 0.
