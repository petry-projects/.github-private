# Fixture — agentic interaction model (§4 classification table)

Misclassified ingress row: both role-jobs are documented (completeness passes),
but the `pr-review-mention` row asserts Class 3 while the shared `on:` union has
no schedule. The §3 discriminator must FAIL[class] that row.

| Workflow (path) | Class | timer_role | Justification |
| --- | --- | --- | --- |
| `.github/workflows/agent-ingress.yml` (dev-lead) | 1 | — | Correctly Class 1 against the shared union. |
| `.github/workflows/agent-ingress.yml` (pr-review-mention) | 3 | — | WRONG: asserts Class 3 but the shared union carries no schedule. |
