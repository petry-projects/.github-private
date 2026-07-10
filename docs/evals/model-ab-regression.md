# Model non-regression A/B (held-out gate)

Phase-1 evidence procedure for epic #1095 (canary rollout). Before a new engine
model — e.g. a `claude-sonnet-5-*` id — is wired into any default chain, it must
demonstrably **match or beat** the model it would replace (`claude-sonnet-4-6`)
on the **frozen, held-out** eval sets. The cost win never quietly ships a quality
regression.

This is a **model** A/B, not a skill A/B. The skill markdown under test is held
at its incumbent file; only the generator **model** varies between the two arms.

## What runs

[`scripts/evals/model-ab.sh`](../../scripts/evals/model-ab.sh) drives the existing
held-out scorer [`scripts/evals/run-eval.sh`](../../scripts/evals/run-eval.sh)
once per `(model, set)` arm, reads the two aggregate scores, and applies a `>=`
non-regression bar per set. It reuses the existing `evals/{triage,deep-review}/holdout`
sets — no new eval infrastructure and no change to the scorer.

```
scripts/evals/model-ab.sh <candidate_model> <incumbent_model> [skill ...]
```

Defaults: skills `triage deep-review`; fixed judge model `claude-sonnet-4-6`.

## The repeatable procedure

```bash
# Score the Sonnet 5 candidate against the Sonnet 4.6 incumbent on BOTH holdout
# sets. The generator model is pinned per arm via CLAUDE_TRIAGE_MODEL_CHAIN; the
# deep-review llm-judge model is held FIXED across both arms (AB_JUDGE_MODEL) so
# only the generator varies.
scripts/evals/model-ab.sh claude-sonnet-5-YYYYMMDD claude-sonnet-4-6 \
  | tee /tmp/model-ab-evidence.json

# Confirm the held-out artifacts are byte-unchanged (reward-hacking /
# held-out-immutability invariant). Expect NO output.
git status --porcelain -- evals/
```

The comparator itself also checksums the read-only artifacts (each set's
`holdout/cases.jsonl`, its `scorer.json`, and `evals/judge.md`) before and after
the run and hard-fails on any mutation — the `git status` check is the outer,
whole-tree confirmation.

## How the two arms stay clean

- **Generator pinned per arm.** `CLAUDE_TRIAGE_MODEL_CHAIN=<arm_model>` (a
  single-id chain) is exported into the `run-eval.sh` subprocess, so `run_triage`
  routes to exactly that model. deep-review's generator also runs through
  `run_triage`, so pinning the triage chain pins the deep-review generator too.
- **Judge held fixed.** deep-review is `llm-judge` mode (`pass_threshold 0.7`), so
  its score depends on both the generator **and** the judge. The comparator wraps
  `EVAL_JUDGE_CMD` in a shim that re-pins the chain to `AB_JUDGE_MODEL` before
  delegating — so a generator swap never moves the judge and confounds the
  comparison. (triage is deterministic and never invokes the judge.)
- **Don't compare across sets.** Scores are only comparable **within** a set,
  candidate-vs-incumbent. triage is deterministic (case passes on exact match);
  deep-review passes on judge score `>= 0.7`.

## Reading the verdict

The comparator emits one JSON evidence object and exits:

| Exit | `verdict` | Meaning |
|------|-----------|---------|
| 0 | `accept` | candidate `>=` incumbent on **every** set — no regression |
| 1 | `regression` | candidate scored **below** incumbent on a fully-scored set — **BLOCKING**, routes to the go/no-go |
| 2 | `infra` | at least one arm was **un-scored** (throttle / hard error) — **re-run**, never a regression |

Infra-vs-quality mirrors `run-eval.sh` (#920): a per-arm exit of `2` means the
model never answered (every model in the fallback chain throttled, or a hard
error), so that set is `infra` — re-run the throttled cycle rather than counting
it. Only exits `0`/`1` are scored results.

Each `sets[]` entry carries `candidate_score`, `incumbent_score`, both arms'
`*_rc` / `*_scored`, the `non_regression` flag, and the per-set `outcome`
(`pass` / `regression` / `infra`).

## Evidence for the go/no-go

Capture the per-set scores for **both** models and the `>=` verdict, alongside the
clean `git status -- evals/`, into the story/PR. That is the evidence input for
the Phase-3 human go/no-go — a regression on **either** set is a blocking result,
never silently accepted. The comparator reads the two aggregate scores directly
rather than using `gate.sh`'s strict `>` verdict, because the bar here is
model-replacement non-regression (`>=`), not strict skill improvement.
