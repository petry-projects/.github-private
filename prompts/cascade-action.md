# Cascade action — post review based on tier result

You are the final action step of the cascading PR review. A previous tier
(deep review or security audit) has produced a verdict in `$FINAL_RESULT`. Your job is to
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

1. Read the JSON at `$FINAL_RESULT` and extract variables:
```bash
DECISION=$(jq -r '.decision' "$FINAL_RESULT")
RISK=$(jq -r '.risk' "$FINAL_RESULT")
SUMMARY=$(jq -r '.summary' "$FINAL_RESULT")
FINDINGS=$(jq -c '.findings // []' "$FINAL_RESULT")
REASON_CODES=$(jq -r '.reason_codes // [] | join(", ")' "$FINAL_RESULT")
```

2. **Idempotency check**: look for our marker at `$PR_HEAD_SHA` in existing
   reviews/comments. If found → skip to step 6 (output JSON and exit).
```bash
EXISTING_MARKER=$(gh pr view "$PR_URL" --json reviews,comments --jq '((.reviews // []) + (.comments // [])) | .[].body | select(. != null)' 2>/dev/null | grep -c "pr-review-agent v1 sha=$PR_HEAD_SHA" || echo 0)
if [ "$EXISTING_MARKER" -gt 0 ]; then
  echo "Already reviewed at $PR_HEAD_SHA, skipping..."
  # Jump to step 6
fi
```

3. Fetch `mergeStateStatus` from the PR (needed for rebase check):
```bash
MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus')
```

4. Compose the review body:
```bash
# Extract data from verdict JSON
FINDINGS_JSON=$(jq -c '.findings // []' "$FINAL_RESULT")
HAS_AGREEMENT=$(jq 'has("agreement")' "$FINAL_RESULT")
AGREEMENT=$(jq -r '.agreement // ""' "$FINAL_RESULT")

# Build the body
cat > /tmp/body-parts.txt <<BODY_TEMPLATE
<!-- pr-review-agent v1 sha=$PR_HEAD_SHA decision=$DECISION risk=$RISK -->

## Automated review — $([ "$DECISION" = "approve" ] && echo "APPROVED ✓" || echo "NEEDS HUMAN REVIEW")

**Risk:** $RISK
**Reviewed commit:** \`$PR_HEAD_SHA\`
**Cascade:** triage → $FINAL_TIER (see $ENGINE_LABEL for models)

### Summary
$SUMMARY

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

# Add cross-engine agreement section if deep+duck
if [ "$FINAL_TIER" = "deep+duck" ] && [ "$HAS_AGREEMENT" = "true" ]; then
  echo "### Cross-engine agreement" >> /tmp/body-parts.txt
  echo "$AGREEMENT agreement between primary and rubber-duck reviewers." >> /tmp/body-parts.txt
  echo "" >> /tmp/body-parts.txt
fi

# Add findings section
if [ "$(echo "$FINDINGS_JSON" | jq 'length')" -gt 0 ]; then
  echo "### Findings" >> /tmp/body-parts.txt
  echo "$FINDINGS_JSON" | jq -r '.[] | "- **[\(.severity)]** \(.message) (\(.file // "N/A"):\(.line // "N/A"))"' >> /tmp/body-parts.txt
  echo "" >> /tmp/body-parts.txt
fi

# Add footer
cat >> /tmp/body-parts.txt <<FOOTER_END

---
_Reviewed by the don-petry PR-review cascade ($ENGINE_LABEL). Reply with \`@don-petry\` if you need a human._
FOOTER_END

# Read entire body for next steps
BODY=$(cat /tmp/body-parts.txt)
rm /tmp/body-parts.txt
```

5. **Act** — Execute these bash commands:

If `$DRY_RUN` is `"true"`:
```bash
echo "--- WOULD POST REVIEW ---"
echo "Decision: $DECISION"
echo "Risk: $RISK"
echo "Body:"
echo "$BODY"
echo "---"
echo "Would then:"
if [ "$DECISION" = "approve" ]; then
  echo "  1. gh pr review \"$PR_URL\" --approve --body \"\$BODY\""
  echo "  2. Check mergeStateStatus and rebase if BEHIND"
  echo "  3. gh pr merge \"$PR_URL\" --auto --squash"
  echo "  4. Remove needs-human-review label"
else
  echo "  Escalate with fix-request comment or needs-human-review label"
fi
exit 0
```

If `decision` is `"approve"`:
```bash
# Step 1: Post the approval review (CRITICAL: use --approve flag)
# Use a temp file to handle body with newlines and special chars safely
BODY_FILE="/tmp/pr-review-body-$$.txt"
cat > "$BODY_FILE" <<'BODY_END'
$BODY
BODY_END

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
