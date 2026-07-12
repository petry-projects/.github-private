# Validator — PRD (headless)

`intent: validate` for `ideas/<slug>/prd.md`. Unlike the other artifacts, the PRD
already has a mature validation rubric — this overlay **wires the vendored bmad-prd
checklist** to the incubation gate's JSON contract rather than defining a new one.
Read [`shared.md`](shared.md) for the `validate` JSON schema.

## Procedure

1. **Load** `ideas/<slug>/prd.md` and follow the vendored bmad-prd validate method
   by path — it is the gold standard:

   ```bash
   cat frameworks/bmad-method/src/bmm-skills/2-plan-workflows/bmad-prd/references/validate.md
   cat frameworks/bmad-method/src/bmm-skills/2-plan-workflows/bmad-prd/assets/prd-validation-checklist.md
   ```

   Run its rubric-walker against the PRD (headless mode — skip the browser-open
   step, per bmad-prd's own `references/headless.md`).
2. **Write the report** to `ideas/<slug>/.validation/prd.md` (bmad-prd's markdown
   twin format is fine — grouped by severity). Always write it.
3. **Map to the incubation contract.** Translate bmad-prd's `findings_summary`
   into this overlay's `validate` JSON. `blockers[]` = every *critical* / *high*
   finding, plus any present-but-empty required section (`Vision`, `Target User`,
   `Functional Requirements`, `Success`).

## Rules

Headless: never ask; no browser; don't edit the PRD; offer an `update` (bmad-prd
sets `offer_to_update: true` already).

## End with the JSON status

```json
{ "status": "complete", "intent": "validate", "artifact": "prd",
  "report_path": "ideas/<slug>/.validation/prd.md",
  "blockers": [], "findings_summary": {"critical":0,"high":0,"medium":0,"low":0},
  "offer_to_update": true }
```
