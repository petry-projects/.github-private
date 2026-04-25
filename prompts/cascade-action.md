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

# Read body from file and pass to gh pr review
gh pr review "$PR_URL" --approve --body "$(cat "$BODY_FILE")" || true
rm -f "$BODY_FILE"

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
