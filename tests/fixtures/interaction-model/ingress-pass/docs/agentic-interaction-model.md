# Fixture — agentic interaction model (§4 classification table)

Minimal stand-in for docs/agentic-interaction-model.md exercising the ADR-0007
multi-role ingress shape: `agent-ingress.yml` contributes ONE row per role-job,
alongside a legacy single-role stub that keeps its one row. Only the §4 table
shape matters here.

| Workflow (path) | Class | timer_role | Justification |
| --- | --- | --- | --- |
| `.github/workflows/agent-ingress.yml` (dev-lead) | 1 | — | Collapsed Class-1 role; shared `on:` union has no schedule. |
| `.github/workflows/agent-ingress.yml` (pr-review-mention) | 1 | — | Collapsed Class-1 mention router; classified against the same shared `on:` union. |
| `.github/workflows/legacy-stub.yml` | 1 | — | Legacy single-role stub — exactly one row (no role qualifier). |
