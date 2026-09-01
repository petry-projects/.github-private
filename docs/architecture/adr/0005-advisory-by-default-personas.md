# 0005. Personas are advisory by default; write access is an opt-in gate

## Status

accepted

## Context

Personas (security-lead, qa-lead, scrum-master, …) are invoked on issues,
discussions, and mentions across the fleet. A persona that could write (commit,
push, label, close) by default would be an unbounded blast radius the moment it
is triggered — a mistaken or manipulated invocation could take real action.

Lifted from the established persona pattern, exemplified by
`personas/security-lead/persona.yml`: it sets `triggers.default_mode: advisory`
and marks every surface (`mention`, `issues`, `discussion`) `mode: advisory`,
with the manifest comment "advisory on every surface, write nowhere. (A future
`write` opt-in would add its own gate_label.)"

## Decision

We will make personas advisory by default and treat any write capability as an
explicit, separately-gated opt-in:

- A persona manifest declares `triggers.default_mode: advisory`, and each
  surface it subscribes to is `mode: advisory` unless a write mode is
  deliberately opted in.
- A write mode, when it exists, carries **its own gate label** — advisory is
  never silently upgraded to write.

The boundary a check can later assert: **for a persona whose
`default_mode: advisory`, every `triggers.surfaces[].mode` is `advisory` unless
that surface names an explicit write opt-in with a gate label.** "Write runtime
identity" here means code/branch write capability (commit, push, label, close),
*not* the account a persona posts advisory comments as: an advisory-only persona
may still run under a real account — `security-lead`, for instance, posts as the
owner account `don-petry` — yet a persona with no write opt-in acquires none of
that commit/push/label/close capability.

## Consequences

- The default posture is safe: a persona triggered unexpectedly can only
  comment/advise, so the cost of a spurious invocation is bounded to noise, not
  action.
- Giving a persona real write power is intentionally more work — it requires an
  explicit mode plus a gate label — which is friction by design, paid in
  exchange for the safety default.
- Some workflows want a persona to *act*, not just advise; those must cross the
  opt-in gate explicitly rather than getting write access implicitly, so the
  advisory default can feel restrictive for genuinely write-oriented roles.
