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

If the agreement field is non-empty and FINAL_TIER is "deep+duck", insert a cross-engine agreement section before Findings:
```bash
if [ -n "$AGREEMENT" ] && [ "$FINAL_TIER" = "deep+duck" ]; then
  sed -i "s|### Findings|### Cross-engine agreement\n$AGREEMENT\n\n### Findings|" /tmp/cascade/review-body.txt
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

4. Verify the output is valid:
```bash
jq -r '.decision' "$OUTPUT_FILE"
echo "Verdict written to $OUTPUT_FILE"
```

**IMPORTANT:** Do NOT print the JSON to stdout. Write it to `$OUTPUT_FILE` only. The bash script reads it from there.
