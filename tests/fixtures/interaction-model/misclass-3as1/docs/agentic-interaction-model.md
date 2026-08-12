# Fixture — agentic interaction model (§4 classification table)

This is a minimal stand-in for docs/agentic-interaction-model.md used by the
schedule-model lint fixtures. Only the §4 table shape matters here.

| Workflow | Class | timer_role | Justification |
| --- | --- | --- | --- |
| `.github/workflows/alpha.yml` | 1 | — | Class-1 event reaction |
| `.github/workflows/beta.yml` | 2 | backstop | Class-2 reconciliation timer |
| `.github/workflows/report.yml` | 1 | — | mislabeled schedule-only report |

## Excluded (non-agentic plumbing)

> | Workflow | Reason |
> | --- | --- |
> | `.github/workflows/plumbing.yml` | CI plumbing, not an agentic role |
