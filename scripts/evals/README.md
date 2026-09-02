# scripts/evals — shared held-out eval infrastructure

This directory holds the **role-generic** eval harness that scores a persona or
prompt-skill against its own held-out cases. Nothing here is specific to one
role: every script is parameterized on `<role>` and reads that role's tree under
`evals/<role>/`, so the same harness scores any of the drafted advisory personas
(and the base triage skill) without change. Adding a new role is a data change
(a new `evals/<role>/` tree), not a code change here.

## The `evals/<role>/` contract

Each role supplies a fixed layout the harness reads:

```
evals/<role>/
  scorer.json          # how to score this role (mode + thresholds)
  judge.md             # llm-judge rubric (only when mode == "llm-judge")
  dev/cases.jsonl      # proposer-visible cases (iteration; may be edited)
  holdout/cases.jsonl  # owner-locked held-out cases (the graded goalpost)
```

`scorer.json` selects one of two scoring modes:

- **`deterministic`** — the role emits a machine-readable verdict (JSON) and the
  scorer checks equality against the case's fixed expected fields (`escalate`,
  `risk`). No model is invoked to grade. Used by the base triage skill.
- **`llm-judge`** — the role emits **prose** (e.g. an advisory), so a versioned
  judge prompt (`judge_prompt`) grades the candidate output against the case's
  expected reference and returns a numeric score in `[0, 1]`. A case passes when
  its judge score `>= pass_threshold`. Used by the advisory personas, whose
  advice is not reducible to an equality check — e.g. `solution-architect`, which
  emits a Governing-ADR / Alignment / Escalate advisory graded on ADR citation,
  escalate direction, and risk tier.

`scorer.json` keys:

| key             | meaning                                                        |
| --------------- | -------------------------------------------------------------- |
| `mode`          | `deterministic` \| `llm-judge`                                 |
| `judge_prompt`  | path (under `evals/`) to the rubric, for `llm-judge`           |
| `pass_threshold`| per-case bar a judge score must clear to count as a pass       |
| `gate_threshold`| aggregate bar the promotion gate holds the role's score to     |

## Scripts

- **`run-eval.sh <role>`** — the scorer. Resolves the role's prompt
  (`prompts/<role>.md`, falling back to `prompts/<role>/advisory.md` for
  advisory personas; override with `SKILL_PROMPT_FILE`), feeds each held-out
  input through it, grades each candidate per `scorer.json`, and emits an
  aggregate report `{score, passed, failed, total, ...}` where `.score` is the
  fraction of held-out cases that passed. This is the one place that reads the
  held-out cases; it never writes them.
- **`score-gate.sh <role> [--threshold N] [--report FILE]`** — the SCORED
  promotion gate (#1630). Resolves a threshold (CLI `--threshold` >
  `scorer.json` `.gate_threshold` > documented default `0.7`), obtains the
  aggregate score (by running `run-eval.sh`, or from a pre-computed `--report`
  artifact so CI can score once and gate offline), and emits a machine-readable
  verdict `{role, score, threshold, verdict, passed, failed, total}`. Exit `0`
  when `score >= threshold` (promotion allowed), `1` when below the bar, `2` on a
  hard error. This replaces the old count-only holdout gate (#1318), where only a
  placeholder `min_cases` was enforced and nothing measured whether the advice
  was any good: promotion past draft is now earned on measured score, not a case
  count.
- **`gate.sh <skill> <incumbent> <candidate>`** — the strict-improvement
  comparator (#586) for skill self-editing: scores two prompt files against the
  SAME held-out set and accepts the candidate only when it *strictly* beats the
  incumbent. Distinct from `score-gate.sh`, which holds one role to an *absolute*
  documented threshold rather than comparing two candidates.

## Reward-hacking invariants

The proposer/candidate side must never be able to move its own goalpost:

- `evals/**/holdout/`, `evals/**/scorer.json`, and every `evals/**/judge.md` are
  owner-locked in `.github/CODEOWNERS` and guarded in CI by `holdout-guard.yml`
  (#692). The candidate may edit only the prompt being scored — never the
  held-out cases, the threshold, or the rubric it must satisfy.
- `dev/` and `holdout/` are kept disjoint (enforced by `evals/validate-cases.py`):
  case ids and inputs must not leak from the held-out set into the visible dev
  set, or the "held-out" score would be trained-against.

## Pure-logic + bats discipline (ADR-0004)

Following ADR-0004, the gate's decision logic is pure and unit-tested before it
is relied on for promotion: `score-gate.sh`'s `sg_resolve_threshold`,
`sg_extract_score`, and `sg_verdict` are sourced and exercised OFFLINE by
`tests/test_score_gate.bats` (no model, no network), while `main()` confines all
I/O. The `--report FILE` path exists precisely so the gate is testable and CI can
gate on a committed artifact.
