# 0003. Review artifact contract and rubric registry

## Status

accepted

## Context

The review automation reviews several kinds of thing (PR diffs, spec drift,
and more). Hard-coding "what is reviewed → how it is reviewed" into the
reviewer would mean forking the reviewer for every new review target, and the
forks would diverge.

Lifted from `AGENTS.md` §"Review artifact contract & rubric registry" and
`scripts/lib/README.md`: the automation binds "what is being reviewed" to "how
it is reviewed" via an artifact contract and a versioned rubric-registry
manifest that sits *above* `engine.sh`.

## Decision

We will bind review target to review method through a data contract, not code
forks:

- Every review is described by an artifact contract
  `{artifact_type, content_ref, rubric, output_channel}`.
- The mapping from `artifact_type` to its rubric and output channel lives in a
  versioned manifest, `scripts/lib/review-registry.tsv`, read through the
  sourced helper `scripts/lib/review-registry.sh`.

The boundary a check can later assert: **register a new `artifact_type` by
adding a manifest row — do not fork the reviewer.** The registry is an
input-adapter layer *above* `engine.sh`; it selects the rubric and output
channel and **must not change engine/model routing.**

## Consequences

- Adding a review target is a one-row data change, reviewable in a diff, with
  no new reviewer code path to test.
- The registry's power is deliberately capped at selection: it cannot alter how
  the engine runs a model. That keeps engine routing in one place, at the cost
  that a review target needing genuinely different *engine* behavior cannot be
  expressed as a registry row alone — it requires an engine-level change, which
  is the correct place for it.
- The manifest is a shared contract: a malformed or duplicate row affects every
  consumer of the registry, so rows are governed by the manifest format in
  `scripts/lib/README.md` rather than edited ad hoc.
