# initiative-planner tooling

Backs `.github/workflows/initiative-planner.yml` — the BMAD Scrum Master ("Bob")
that turns one approved idea (an Ideas Discussion) into a GitHub epic + sub-issue
DAG, ready for `initiative-driver` → `dev-lead`. See the full pipeline in
[`docs/initiatives/idea-to-initiative-pipeline.md`](../../docs/initiatives/idea-to-initiative-pipeline.md).

Bob follows the **real BMAD Method skills, vendored agent-agnostically under
`frameworks/`** (v6.8.0 + Test Architect v1.19.0; see
[`prompts/bmad/`](../../prompts/bmad/README.md)) — `bmad-sprint-planning` +
`bmad-create-story`, read by path. Stories are emitted in the canonical BMAD
create-story template, which `plan.schema.json` mirrors field-for-field.

| File | Role |
|------|------|
| `redispatch.sh` | Bridge the `discussion [labeled]` trigger to `workflow_dispatch` (claude-code-action rejects `discussion` event contexts). Fired with a PAT so the dispatch actually starts a run. |
| `gather-context.sh` | Fetch the approved Discussion + repo context → `$CONTEXT_PATH`; export `DISCUSSION_NODE_ID`. |
| `plan.schema.json` | The plan contract Bob must emit (epic + stories + `blocked_by`). |
| `validate-plan.py` | Schema + semantic checks: unique ids, acyclic DAG, an entry point, no dangling edges. |
| `lib/mutations.sh` | DRY_RUN-aware GitHub helpers (create issue, link sub-issue, add `blocked_by`, comment on Discussion). |
| `apply-plan.sh` | Materialize a validated plan. Creates issues labelled `initiative` only — **never** `initiative:auto`. |

Tests: `tests/test_initiative_planner.bats`, `tests/test_initiative_planner_redispatch.bats` (run via `lint.yml`).

## Local dry run

```bash
# 1. Author or fetch a plan.json (see the schema), then:
python3 scripts/initiative-planner/validate-plan.py plan.json

# 2. Dry-run apply — logs intended mutations, touches nothing:
DRY_RUN=1 DRY_RUN_LOG=/tmp/plan.jsonl \
REPO=petry-projects/.github-private \
DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID=D_xxx \
PLAN_PATH=plan.json \
bash scripts/initiative-planner/apply-plan.sh
cat /tmp/plan.jsonl | jq .
```

## Invariants (enforced by tests)

- `apply-plan.sh` can never apply `initiative:auto` — activation is a human step.
- `hands_off` stories also get `dev-lead:hands-off` + `initiative:hold`.
- A dependency cycle, a missing entry point, or a dangling `blocked_by` fails
  validation before any issue is created.
- **Blocking open-questions gate (#682).** If the plan's `open_questions`
  contains any item flagged `blocking:true`, `apply-plan.sh` creates **zero**
  issues. Instead it posts the questions back to the source discussion with
  "not yet planned — answer these to proceed" framing and exits cleanly
  (DRY_RUN honored). This stops Bob from shipping an inert epic + sub-issue DAG
  that a human would have to close and re-plan once scope is settled (incidents
  #650→#659, #666→#667). Re-running after the questions are answered then
  materializes the real plan. Plain-string `open_questions` stay advisory and do
  **not** gate — only objects shaped `{"question": "...", "blocking": true}` do.
