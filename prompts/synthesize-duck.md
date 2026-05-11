# Synthesize deep review + rubber duck verdicts

Two reviewers analyzed the same PR in parallel using **different model
families** — one as the primary deep reviewer, the other as the adversarial
"rubber duck." Your job: read both verdicts, reconcile them, and produce
a single combined verdict.

## Inputs (environment variables)

- `$PR_URL` — the PR under review.
- `$PR_HEAD_SHA` — the head commit SHA.
- `$DRY_RUN` — `true` or `false`.
- `$REVIEW_CYCLE` — integer.
- `$MAX_REVIEW_CYCLES` — integer.
- `$TRIAGE_RESULT` — JSON from the triage tier.
- `$DEEP_RESULT` — path to the primary deep review JSON.
- `$DUCK_RESULT` — path to the rubber duck review JSON.
- `$OUTPUT_FILE` — path where you MUST write your combined verdict.
- `$DUCK_ENGINE` — which engine ran the rubber duck (`claude` or `copilot`).
- `$DUCK_MODEL` — which model ran the rubber duck.

## Steps

1. Read both JSON files:
   ```
   jq . "$DEEP_RESULT"
   jq . "$DUCK_RESULT"
   ```
2. Compare the two verdicts across all dimensions.
3. Synthesize a combined verdict following the rules below.
4. Write the combined JSON to `$OUTPUT_FILE`.

## Synthesis rules

### Risk
- `risk` = the **higher** of the two. If either says HIGH, the combined
  risk is HIGH. HIGH > MEDIUM > LOW.

### Decision
- If **either** reviewer says `escalate` → combined decision is `escalate`.
- Both must say `approve` for the combined decision to be `approve`.

### Escalation
- `escalate_to_opus` = `true` if combined risk is HIGH, OR if either reviewer
  flagged a finding with severity `critical`.

### Findings
- **Union** all findings from both reviewers.
- **Deduplicate**: if both flagged the same file+line+category, keep one entry
  and add a `"sources": ["deep", "rubber-duck"]` field noting both agreed.
  Cross-engine agreement on a finding is a strong signal — apply this exact
  severity mapping to the deduplicated finding: `info` → `minor`, `minor` →
  `major`, and leave `major` / `critical` unchanged.
- For findings from only one reviewer, add `"sources": ["deep"]` or
  `"sources": ["rubber-duck"]`.
- Otherwise preserve the original severity.

### Summary
Write a 2-4 sentence combined summary that:
- Notes the overall risk assessment and whether the reviewers agreed or disagreed.
- Highlights any findings where both engines converged (strongest signal).
- Calls out findings unique to the rubber duck (cross-model diversity value).

## Output

Write a JSON object to `$OUTPUT_FILE`:

```json
{
  "tier": "combined",
  "primary_engine": "<REVIEW_ENGINE>",
  "duck_engine": "<DUCK_ENGINE>",
  "risk": "LOW|MEDIUM|HIGH",
  "decision": "approve|escalate",
  "escalate_to_opus": true|false,
  "reason_codes": ["..."],
  "agreement": "full|partial|divergent",
  "summary": "2-4 sentences",
  "findings": [
    {
      "severity": "info|minor|major|critical",
      "category": "...",
      "message": "...",
      "file": "path or null",
      "line": "number or null",
      "sources": ["deep", "rubber-duck"]
    }
  ]
}
```

`agreement` values:
- `full` — same risk AND same decision
- `partial` — same decision but different risk, OR same risk but different decision
- `divergent` — different risk AND different decision

Write with `cat > "$OUTPUT_FILE" <<'JSON' ... JSON`. Ensure it parses with `jq`.
After writing, exit. Do not do anything else.
