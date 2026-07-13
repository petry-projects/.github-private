# Validator — Market research (headless)

`intent: validate` for `ideas/<slug>/market-research.md`. Critiques the existing
artifact without changing it and emits a machine-readable status the incubation
gate's content-quality tier consumes. Read [`shared.md`](shared.md) first
(the `validate` JSON schema). Modeled on bmad-prd's `references/validate.md`.

## Procedure

1. **Load.** Read `ideas/<slug>/market-research.md` and
   [`checklists/market-research-checklist.md`](checklists/market-research-checklist.md).
   Read `prior_artifacts` (brainstorm) for consistency checks if available
   (gracefully skip if brainstorm is missing).
2. **Judge each rubric dimension** — *strong / adequate / thin / broken*. Write a
   finding only where it adds information; cite the section and quote a phrase.
   Severity = impact on the artifact's usefulness, not fix difficulty.
3. **Write the report** to `ideas/<slug>/.validation/market-research.md`: overall
   verdict, per-dimension verdicts, findings grouped by severity (critical / high /
   medium / low), each with location + suggested fix. Always write it, even with
   zero findings.
4. **Compute blockers.** `blockers[]` = every *critical* or *high* finding, plus
   any required section (`How it's solved today`, `The gap`, `Market signal`) that
   is present-but-empty. Overall `status` is `complete` if the report was written
   (the *findings* gate the artifact, not this run).

## Rules

- Headless: never ask; don't open a browser; write the report and return.
- Do not edit the artifact — always offer to roll findings into an `update`.

## End with the JSON status (`validate` schema)

```json
{ "status": "complete", "intent": "validate", "artifact": "market-research",
  "report_path": "ideas/<slug>/.validation/market-research.md",
  "blockers": [], "findings_summary": {"critical":0,"high":0,"medium":0,"low":0},
  "offer_to_update": true }
```
