# Idea → Initiative pipeline

How a raw idea becomes auto-implementable work, and where the human gates are.

```
feature-ideation.yml        (weekly, automated)   ──>  Ideas DISCUSSIONS
  BMAD Analyst "Mary"                                   (proposals)
        │
        ▼
idea-triage.yml             (weekly, automated)    ──>  "🧭 Idea Promotion Queue"
  ranks ripeness; never approves                        tracking issue (shortlist)
        │
   ★ HUMAN — add `idea:approved` to a Discussion
        │
        ▼
initiative-planner.yml      (on approval / dispatch, automated)
  BMAD Scrum Master "Bob"   sprint-planning + create-story
        │                   creates an EPIC + sub-issue DAG (blocked_by),
        │                   labelled `initiative` — INERT (no `initiative:auto`)
        │                   posts the plan back to the Discussion
        ▼
   ★ HUMAN — review the epic/DAG, then add `initiative:auto` to the epic
        │
        ▼
initiative-driver.yml       (on issues:closed + cron, automated)
  releases each ready story (blockers closed) by labelling it `dev-lead`
        ▼
dev-lead.yml  ──>  PR  ──>  pr-review  ──>  merge  ──>  "Closes #N"
        └──────────── closing a story unblocks its successors ───────────┘
```

Two automated stages were added to close the gap between "idea" and
"in-flight": **idea-triage** (shortlist) and **initiative-planner** (the BMAD
Scrum Master). Each is bounded by a human gate, so judgement stays with a
maintainer:

| Gate | Signal | Who |
|------|--------|-----|
| Idea is worth planning | add `idea:approved` to the Discussion | human |
| Initiative is ready to build | add `initiative:auto` to the epic | human |

## The two new workflows

Both are **org-private automation** (like `initiative-driver.yml`), not thin
caller stubs. Tooling and the vendored BMAD personas live in this repo and are
unit-tested.

### `idea-enhancer.yml` — enrich human-authored ideas
- Trigger: a Discussion is **created** (enhance that one immediately), a weekly
  **schedule** (safety-net sweep of the backlog), or manual `workflow_dispatch`
  (`dry_run` logs intended comments to an artifact).
- Closes the gap where `feature-ideation` only ever generates *new* idea
  Discussions and never enriches the ones a human adds. For each open,
  human-authored, not-yet-enhanced **Ideas** Discussion it posts **one** comment
  (sharpened problem/goal, repo + market context, impact/effort, suggested
  acceptance criteria). Bot-authored ideas are skipped — they are already
  AI-generated.
- Idempotent: each enhancement comment carries a hidden marker
  (`<!-- idea-enhancer:enhanced -->`); a discussion that already has one is never
  re-enhanced. It never approves, labels, or promotes — that stays with triage
  and the human gates.
- Tooling: `scripts/idea-enhancer/{gather-candidates,post-enhancement}.sh`.

### `idea-triage.yml` — weekly ripeness shortlist
- Scans every open **Ideas** Discussion, scores each **Ripe / Soon / Not yet**
  on evidence, prerequisites, alignment, coverage, and freshness.
- Rewrites a single **Idea Promotion Queue** tracking issue (label
  `idea-triage`) with the ranked list and a pre-drafted promotion note per ripe
  idea. It **never** applies `idea:approved` — that's the human's pick.
- Tooling: `scripts/idea-triage/{gather-ideas,upsert-queue}.sh`.

### `initiative-planner.yml` — BMAD Scrum Master "Bob"
- Trigger: a Discussion gets labelled `idea:approved`, or manual
  `workflow_dispatch` with a discussion number (`dry_run` defaults to **true**).
- **Follows the real BMAD Method skills, vendored agent-agnostically under
  `frameworks/`** (BMM v6.8.0 at `frameworks/bmad-method/` + **Test Architect**
  v1.19.0 at `frameworks/bmad-test-architecture/`; `src/` skill trees only, see
  `prompts/bmad/README.md`). The planner reads the skills **by path** (not via any
  vendor-specific `.<tool>/skills` dir), following `bmad-sprint-planning` +
  `bmad-create-story` (and the Test Architect "Murat"/`testarch` where useful) —
  not a paraphrase. Stories are emitted in the canonical BMAD **create-story
  template** (Story / Acceptance Criteria / Tasks-Subtasks / Dev Notes / Project
  Structure Notes / References) and self-checked against the create-story
  **checklist**.
- Reads the approved idea + repo context, runs sprint-planning + create-story,
  and emits a schema-validated **initiative plan** (`plan.schema.json`, which
  mirrors the BMAD template field-for-field): an epic + 3–8 PR-sized stories
  with testable acceptance criteria, AC-referencing tasks, grounded Dev Notes,
  sizes, and a `blocked_by` DAG. Prerequisites already tracked as issues become
  `blocked_by_existing_issues` edges, not new stories.
- Materializes the epic + native sub-issue DAG via `apply-plan.sh`, labelled
  `initiative` only. **It never applies `initiative:auto`** — the epic is created
  inert and a human activates it after review. `hands_off` stories also get
  `dev-lead:hands-off` + `initiative:hold` so the driver never auto-releases them.
- Tooling: `scripts/initiative-planner/` (persona: `prompts/bmad/scrum-master.md`).

## Labels the pipeline relies on

| Label | On | Meaning |
|-------|----|---------|
| `idea:approved` | Discussion | Human blessed this idea for planning → fires the planner |
| `idea-triage` | Issue | Marks the Idea Promotion Queue tracking issue |
| `initiative` | Epic + stories | Part of a tracked initiative |
| `initiative:auto` | Epic | Human activated auto-implementation (driver may release) |
| `initiative:hold` / `dev-lead:hands-off` | Story | Never auto-released; needs a human |

## Safety properties

- **Two human gates**, both opt-in labels. Nothing reaches `dev-lead` without a
  maintainer adding `idea:approved` then `initiative:auto`.
- **Dry-run first.** The planner defaults `dry_run: true` on manual dispatch and
  logs every intended mutation to an artifact; triage supports the same.
- **Auto is never self-applied.** `apply-plan.sh` cannot emit `initiative:auto`
  (enforced by `tests/test_initiative_planner.bats`).
- **DAG is validated** (acyclic, has an entry point, no dangling edges) before
  any issue is created.
