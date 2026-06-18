# Skill self-improvement — strict-improvement gate + manual runbook

Part of epic **#581** (self-improving skills, Discussion #572). This is **Phase 2**:
a strict-improvement comparator plus the documented manual procedure for proposing
a skill change, validating it locally against the held-out set, and shipping it
through the **existing** human-gated PR pipeline. No automation is built here — the
gate logic and its regression-rejection proof are, the operator dry-run is human
work.

It depends on the held-out structure from [`evals/README.md`](../../evals/README.md)
and the scorer from [`scripts/evals/run-eval.sh`](../../scripts/evals/run-eval.sh).

## The reward-hacking invariant (read this first)

> **The proposer may edit only the skill markdown under `prompts/`. It must never
> edit the held-out `evals/<skill>/holdout/cases.jsonl` or the judge prompt
> `evals/judge.md`.**

This is the whole point of a held-out set: if you could change the test, "passing"
it would prove nothing. The gate only measures whether a skill edit moved the
held-out score; it cannot tell a genuine improvement from a doctored test set. Two
independent controls keep the cases honest, both already in place from Phase 1:

- **Tamper protection** — `evals/**/holdout/`, `evals/judge.md`, and
  `evals/**/scorer.json` are CODEOWNER-gated in [`.github/CODEOWNERS`](../../.github/CODEOWNERS),
  and [`holdout-guard.yml`](../../.github/workflows/holdout-guard.yml) (#692) hard-fails
  any proposer-authored PR that touches an `evals/` path. The proposer runs as
  `GITHUB_TOKEN` and therefore cannot merge a change to the cases.
- **Context isolation** — a proposer's context is built from the `dev/` split only;
  the gate scores `holdout/` only (`run-eval.sh` reads `holdout/` exclusively).

If your change requires editing the cases, that is a **separate**, CODEOWNER-reviewed
PR — never bundle it with a skill edit you are trying to get past the gate.

## The strict-improvement gate

[`scripts/evals/gate.sh`](../../scripts/evals/gate.sh) scores an **incumbent** skill
file and a **candidate** skill file against the **same** held-out set and accepts
the candidate **only when it strictly beats the incumbent**:

```
candidate_score > incumbent_score      # strict '>', never '>='
```

Ties and regressions are both **rejected**. Promoting a tie buys churn and risk for
no proven gain, so a skill edit must demonstrably move the held-out score *up*.

```bash
# scripts/evals/gate.sh <skill> <incumbent_file> <candidate_file>
bash scripts/evals/gate.sh triage prompts/triage.md /tmp/triage-candidate.md
```

It prints a JSON verdict and sets its exit code accordingly:

```json
{"skill":"triage","incumbent_score":0.5,"candidate_score":1,"accepted":true,"verdict":"accept"}
```

| Outcome | `candidate_score` vs `incumbent_score` | Exit |
|---------|----------------------------------------|------|
| accept  | strictly greater                       | 0    |
| reject  | equal (tie) or lower (regression)      | 1    |
| error   | bad usage / missing file / scorer hard-failed | 2 |

Under the hood the gate is deterministic plumbing: it runs `run-eval.sh` twice via
its `SKILL_PROMPT_FILE` override (once per file) over the same `holdout/cases.jsonl`
and compares the two aggregate `.score` values. It adds no scoring logic of its own
and never writes the held-out cases. The regression-rejection behaviour is proven
offline in [`tests/test_skill_evals.bats`](../../tests/test_skill_evals.bats) (a
deliberately-worse candidate is rejected; a strictly-better one is accepted; a tie
is rejected).

## Manual propose → validate → PR runbook

This reuses the existing idea→initiative pipeline and its human gates **unchanged**
(see [`idea-to-initiative-pipeline.md`](./idea-to-initiative-pipeline.md)). It adds
**no** release-tag changes and is strictly more conservative than today's un-gated
hand edits to a skill prompt.

1. **Edit one skill markdown.** Change a single `prompts/<skill>.md` (e.g.
   `prompts/triage.md`). Do **not** touch anything under `evals/` — see the
   invariant above. Keep the candidate where you can point the gate at it; the
   simplest is to edit `prompts/<skill>.md` in your working tree and compare it
   against the committed version:

   ```bash
   git show HEAD:prompts/triage.md > /tmp/triage-incumbent.md
   bash scripts/evals/gate.sh triage /tmp/triage-incumbent.md prompts/triage.md
   ```

2. **Run the gate locally.** It must exit `0` (accept). If it rejects, the edit did
   not strictly improve the held-out score — iterate or abandon it. Do not weaken
   the cases to make it pass (that violates the invariant and `holdout-guard.yml`
   would block the PR anyway).

3. **Open a PR** with only the skill-markdown change. It flows through the **same**
   human gates as any other change — no new mechanism:
   - **`pr-review`** reviews the diff.
   - **CODEOWNERS** (`.github/CODEOWNERS`) routes review; the proposer cannot merge
     a change to held-out paths, and `holdout-guard.yml` is a required check that
     hard-fails a proposer-authored PR touching `evals/`.
   - Promotion through the idea→initiative pipeline's two opt-in label gates
     (`idea:approved`, then `initiative:auto`) is unchanged; this story adds nothing
     to that flow.

The local gate is an **advisory pre-flight** for the operator: it proves the edit is
a strict improvement before a human spends a review on it. The merge decision still
rests with `pr-review` + CODEOWNER, exactly as before.

## References

- [`evals/README.md`](../../evals/README.md) — held-out dev/holdout split and hygiene
- [`scripts/evals/run-eval.sh`](../../scripts/evals/run-eval.sh) — the held-out scorer
- [`scripts/evals/gate.sh`](../../scripts/evals/gate.sh) — the strict-improvement comparator
- [`tests/test_skill_evals.bats`](../../tests/test_skill_evals.bats) — scorer + gate proofs
- [`idea-to-initiative-pipeline.md`](./idea-to-initiative-pipeline.md) — the human-gated PR pipeline reused here
- [`.github/workflows/holdout-guard.yml`](../../.github/workflows/holdout-guard.yml) — CI immutability gate over `evals/` (#692)
