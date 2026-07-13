# Validator — Brainstorm (headless)

`intent: validate` for `ideas/<slug>/brainstorm.md`. Same procedure as
[`validate-market-research.md`](validate-market-research.md); read
[`shared.md`](shared.md) for the `validate` JSON schema.

## Procedure

1. **Load** `ideas/<slug>/brainstorm.md` and
   [`checklists/brainstorm-checklist.md`](checklists/brainstorm-checklist.md).
2. **Judge each dimension** *strong / adequate / thin / broken*; findings only where
   they add information; cite + quote. The provenance dimension is gate-critical —
   a brainstorm that reads as invented rather than session-grounded is a **critical**.
3. **Write the report** to `ideas/<slug>/.validation/brainstorm.md` (always).
4. **Blockers** = every *critical* / *high* finding, plus any present-but-empty
   required section (`Problem space`, `Ideas explored`, `Selected direction`).

## Rules

Headless: never ask; no browser; don't edit the artifact; offer an `update`.

## End with the JSON status

```json
{ "status": "complete", "intent": "validate", "artifact": "brainstorm",
  "report_path": "ideas/<slug>/.validation/brainstorm.md",
  "blockers": [], "findings_summary": {"critical":0,"high":0,"medium":0,"low":0},
  "offer_to_update": true }
```
