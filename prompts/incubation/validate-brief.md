# Validator — Decision brief (headless)

`intent: validate` for `ideas/<slug>/brief.md`. Same procedure as
[`validate-market-research.md`](validate-market-research.md); read
[`shared.md`](shared.md) for the `validate` JSON schema.

## Procedure

1. **Load** `ideas/<slug>/brief.md`, [`checklists/brief-checklist.md`](checklists/brief-checklist.md),
   and the prior artifacts (brainstorm, market-research) for consistency.
2. **Judge each dimension** *strong / adequate / thin / broken*; cite + quote.
   Consistency with the package and "recommendation is an actual decision" are the
   load-bearing dimensions.
3. **Write the report** to `ideas/<slug>/.validation/brief.md` (always).
4. **Blockers** = every *critical* / *high* finding, plus any present-but-empty
   required section (`Problem`, `Target user`, `Recommendation`).

## Rules

Headless: never ask; no browser; don't edit the artifact; offer an `update`.

## End with the JSON status

```json
{ "status": "complete", "intent": "validate", "artifact": "brief",
  "report_path": "ideas/<slug>/.validation/brief.md",
  "blockers": [], "findings_summary": {"critical":0,"high":0,"medium":0,"low":0},
  "offer_to_update": true }
```
