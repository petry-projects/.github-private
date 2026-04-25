# Cascade action — finalize verdict and prepare for posting

You are the final step of the cascading PR review. A previous tier (deep review or
security audit) has produced a verdict in `$FINAL_RESULT`. Your job is to:

1. Read the verdict
2. Compose the full review body
3. Output a final JSON with all necessary fields

The review will be posted by the bash script, not by this prompt.

## Inputs (environment variables)

- `$FINAL_RESULT` — path to verdict JSON from the resolving tier
- `$PR_HEAD_SHA` — commit SHA that was reviewed
- `$FINAL_TIER` — which tier made the final call (deep+duck, deep, or audit)
- `$ENGINE_LABEL` — human-readable label for cascade models
- `$DUCK_ENGINE` — rubber duck engine (claude or copilot)
- `$DUCK_MODEL` — rubber duck model
- `$TRIAGE_RESULT` — triage verdict for context

## Steps

1. Read the verdict JSON:
```bash
jq . "$FINAL_RESULT"
```

2. Extract the decision, risk, summary, and findings:
```bash
DECISION=$(jq -r '.decision' "$FINAL_RESULT")
RISK=$(jq -r '.risk' "$FINAL_RESULT")
SUMMARY=$(jq -r '.summary' "$FINAL_RESULT")
FINDINGS=$(jq -c '.findings // []' "$FINAL_RESULT")
AGREEMENT=$(jq -r '.agreement // ""' "$FINAL_RESULT")
```

3. Compose the review body using this template:

```
<!-- pr-review-agent v1 sha=<PR_HEAD_SHA> decision=<approved|escalated> risk=<LOW|MEDIUM|HIGH> -->

## Automated review — <APPROVED ✓|NEEDS HUMAN REVIEW>

**Risk:** <risk>
**Reviewed commit:** `<SHA>`
**Cascade:** triage → <FINAL_TIER> (see <ENGINE_LABEL> for models)

### Summary
<from verdict's summary>

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

### Findings
<findings from verdict, formatted as list>

---
_Reviewed by the don-petry PR-review cascade (<ENGINE_LABEL>). Reply with `@don-petry` if you need a human._
```

4. Output the final verdict JSON with the composed body:

```json
{
  "decision": "<decision from verdict>",
  "risk": "<risk>",
  "summary": "<summary>",
  "findings": <findings>,
  "body": "<full markdown review body composed above>",
  "escalate_to_ai": <true if decision is escalate and risk is not HIGH>
}
```

Write this to stdout as valid JSON. The bash script will parse it and post the review.

**IMPORTANT:** Include the complete review body in the "body" field. This is what will be
posted to GitHub as the review. Make it clear, well-formatted, and professional.
