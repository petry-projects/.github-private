# 0004. Pure-logic classifiers with bats tests; LLM only where it must be

## Status

accepted

## Context

Much of this repo's automation makes decisions (is this stub drifted? did this
PR drift from its spec? is the engine token live?). If those decisions were
entangled with network I/O and LLM calls, they would be untestable and
non-deterministic, and every behavior change would need a live run to verify.

Lifted from `AGENTS.md` §"Scripts" (POSIX bash, `set -euo pipefail`) and the
established `scripts/*.sh` + `tests/*.bats` convention. Concrete exemplars:
`scripts/spec-drift.sh` and `scripts/fleet_stub_drift.sh` each factor their
decision logic into pure functions and confine I/O to `main()`. `spec-drift.sh`
states it directly: the pure classifiers "are PURE (no network, no LLM) and
unit-tested"; `main()` "does all I/O".

## Decision

We will structure decision-making shell scripts so the logic is pure and
tested, and use an LLM only where deterministic code cannot do the job:

- **Pure classifiers** (no network, no LLM, no global state) hold the decision
  logic and are unit-tested in a matching `tests/*.bats` file.
- **`main()` does all I/O** — argument/env resolution, `gh`/API calls, engine
  invocation, output — and orchestrates the pure functions.
- **An LLM is invoked only where the task genuinely requires it** (e.g. a
  judgement `main()` delegates to a review tier), never for a decision a pure
  classifier could make deterministically.

The boundary a check can later assert: **a new decision script ships a pure
classifier plus a `tests/<name>.bats` that exercises it without network or
LLM.** Where the source cannot be resolved, the pure path stays inert (e.g.
`spec-drift.sh` emits `INDETERMINATE` rather than fabricating a verdict) —
"Fail Loud, Never Fake."

## Consequences

- Decision logic is deterministic and unit-testable offline, so behavior
  changes are caught in CI rather than only in a live run.
- Keeping classifiers pure imposes a discipline cost: no reaching for `gh` or
  env inside a classifier, even when it would be convenient — the I/O must be
  threaded through `main()` and passed in.
- The "LLM only where it must be" rule keeps token cost and non-determinism
  contained, but it puts the burden on the author to prove a deterministic
  classifier cannot do the job before adding a model call.
