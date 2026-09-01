# 0002. Channel-tag releases, ring promotion, and the mutable-ref exception

## Status

accepted

## Context

The org standard requires SHA-pinning actions to avoid mutable-ref
supply-chain risk. But caller stubs (ADR-0001) must pin to a ref that can be
*advanced* on promotion without editing every consumer — a fixed SHA cannot do
that.

Lifted from `AGENTS.md` §"Release channel tags & the mutable-ref exception"
and `docs/release/versioning.md`: first-party reusables are versioned with two
kinds of tag, and callers pin to a moving channel tag advanced ring-by-ring.

## Decision

We will version every first-party reusable with two tag kinds and treat only
the second as a sanctioned exception to the SHA-pin rule:

- **Immutable releases** `<name>/vX.Y.Z` — never moved or deleted; the audit
  trail and rollback targets. `scripts/cut-release.sh` refuses to overwrite an
  existing release tag.
- **Moving channel tags** `<name>/v<MAJOR>-<tier>` (tiers `stable`, and where
  live `next` / `ring0` / `ring1`) — the canonical form callers pin to,
  advanced on promotion by moving the tag ring-by-ring.

Checkable boundaries a check can later assert:

- **The SHA-pin exception is scoped to first-party channel tags only.** A
  compliance audit must NOT flag a first-party `<name>/v<MAJOR>-<tier>` channel
  tag on a first-party caller as an "unpinned action"; third-party actions
  still require SHA pins. Bare-tier `<name>/<tier>` pins are DEPRECATED and now
  a failure, not a warning.
- **Adding a new `workflow_call` input is a three-step sequence, in order:**
  (1) land the input in the reusable's `workflow_call.inputs`; (2) promote the
  pinned channel to a commit that declares it via `cut-release.sh`; (3) only
  then add the stub's `with:` forward. Forwarding first is the #1034
  channel-skew defect (epic #1052) — the same defect ADR-0001 names.

## Consequences

- Callers pin once and receive promotions automatically as the channel tag
  advances — no fan-out edit per release.
- The mutability is bounded by a repository ruleset (`release-channel-tags`)
  that restricts `update`/`deletion` on the channel namespaces, so a reusable
  running as `GITHUB_TOKEN` cannot move its own release tags. Extending that
  ruleset to a newly-versioned reusable is a manual admin step that can lag the
  tooling — a real operational cost of the exception.
- Because the channel deliberately lags the reusable's `main`, stubs must be
  edited in the strict order above; the convenience of a moving pin is paid for
  with that sequencing discipline.
