# Held-out eval cases

This directory holds the **held-out eval-case sets** used to measure prompt-skill
quality against fixed, reward-hack-resistant expected outputs. It is the trust
anchor of the skill-quality initiative (Discussion #572): cases live here, on
their own, and are validated structurally — there is **no scorer and no model
invocation** in this directory.

## Layout

```
skills/evals/
├── case.schema.json        # JSON-Schema (draft 2020-12) for one eval case
├── validate-cases.py       # validate a .jsonl set against the schema
└── <skill>/cases.jsonl     # one case per line for that skill (e.g. triage/)
```

Each `<skill>/cases.jsonl` is [JSON Lines](https://jsonlines.org/): one JSON
object per line, each conforming to `case.schema.json`.

## Case format

A case pairs a single triage **input** with the **expected** decision the skill
must emit. Required fields (see `case.schema.json` for the authoritative
contract — it is `additionalProperties: false`, so unknown keys are rejected):

| Field               | Type                      | Notes                                                                                  |
| ------------------- | ------------------------- | -------------------------------------------------------------------------------------- |
| `id`                | string (kebab-case)       | Stable, unique identifier for the case.                                                 |
| `input`             | string                    | The pre-fetched PR context exactly as `prompts/triage.md` consumes under `## Pre-fetched PR context`. Self-contained; triage has no tools. |
| `expected.escalate` | boolean                   | Whether triage must escalate (`true`) or may approve (`false`).                          |
| `expected.risk`     | `LOW` \| `MEDIUM` \| `HIGH` | Expected risk classification. Any `HIGH` signal must pair with `escalate: true`.        |
| `description`        | string (optional)        | What the case exercises and which `triage.md` criterion grounds the expected decision.  |
| `tags`               | string[] (optional)      | Coverage labels, e.g. the high-risk trigger a case exercises (`auth-secrets`, `db-migration`, `security-anti-pattern`). |

Expected decisions are **grounded strictly in the numbered decision criteria of
`prompts/triage.md`** — not invented behavior. `triage.md` emits a deterministic
JSON object with no tools, so the expected `escalate`/`risk` can be fixed values.

## Validation

Validation uses the same `python jsonschema` pattern that
`scripts/initiative-planner/plan.schema.json` uses:

```sh
pip install 'jsonschema>=4'
python3 skills/evals/validate-cases.py skills/evals/triage/cases.jsonl
```

The validator checks every line against `case.schema.json` and enforces the one
cross-line invariant the set depends on: **case ids must be unique**. It runs in
CI via `tests/test_evals_cases.bats`.

## Separately owned — reward-hacking guard

This directory is **separately owned** via `.github/CODEOWNERS`. That is a
deliberate guard: a future automated skill *proposer* may only ever edit the
skill markdown (e.g. `prompts/triage.md`), **never** this held-out set. If the
proposer could edit the cases, it could optimize the skill against a moving
target — reward hacking. Keeping the cases CODEOWNER-gated, apart from any
scorer or proposer, is what makes a measurement against them trustworthy.

Any change to `skills/evals/**` therefore requires review from the designated
code owners.
