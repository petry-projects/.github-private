#!/usr/bin/env bats
# Tests for the canonical agent-ingress.yml reference (issue #1724, epic #1723,
# ADR-0007). The reference is authored as a NON-executing artifact under docs/ and
# is made emittable via scripts/seed-repo-template.sh so it is a machine-consumable
# byte-identity baseline (template_stub_drift / downstream stories hash the
# emission) rather than existing only as prose (AC #3). These tests assert the
# canonical structure: union on:, one job per collapsed Class-1 role, per-job
# permissions + channel pin + agent_ref, role-bearing job names, and an
# event-filter-only if: on each job (AC #1, #2).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SEED="$SCRIPT_DIR/scripts/seed-repo-template.sh"
REF="$SCRIPT_DIR/docs/architecture/reference/agent-ingress.yml"

@test "reference: the canonical agent-ingress.yml exists under docs/, NOT under .github/workflows" {
  [ -f "$REF" ]
  # A live workflow in .github/workflows/ would double-dispatch the per-role stubs
  # (behavior change forbidden by AC #5); the reference must not live there.
  [ ! -f "$SCRIPT_DIR/.github/workflows/agent-ingress.yml" ]
}

@test "emit-workflow: agent-ingress.yml emits the reference byte-for-byte" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$REF")" ]
}

@test "emit-workflow: unknown reference/stub name still fails loud" {
  run bash "$SEED" --emit-workflow no-such-ingress.yml
  # An unknown reference/stub name is a usage error → exit 2 specifically (the
  # `_emit_workflow` unknown-stub path), not just any non-zero, so a syntax or
  # command-not-found regression can't masquerade as the expected failure.
  [ "$status" -eq 2 ]
}

@test "reference: on: is the UNION of the collapsed roles' triggers (AC #1)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  # dev-lead ∪ pr-review-mention subscriptions.
  [[ "$output" == *"pull_request:"* ]]
  [[ "$output" == *"pull_request_review:"* ]]
  [[ "$output" == *"pull_request_review_comment:"* ]]
  [[ "$output" == *"issue_comment:"* ]]
  [[ "$output" == *"issues:"* ]]
  [[ "$output" == *"check_run:"* ]]
  [[ "$output" == *"repository_dispatch:"* ]]
}

@test "reference: exactly one job per collapsed role, each name carries the role token (AC #1)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  # Role-bearing job keys so runs stay attributable by role (ADR-0007 consequence).
  [[ "$output" == *"dev-lead:"* ]]
  [[ "$output" == *"pr-review-mention:"* ]]
}

@test "reference: each job carries its own permissions block (AC #1)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  # Top-level least privilege plus per-job scopes (a single dispatching job is
  # forbidden — it would need the union of every role's permissions).
  [[ "$output" == *"permissions: {}"* ]]
  perm_count="$(printf '%s\n' "$output" | grep -cE '^[[:space:]]+permissions:')"
  [ "$perm_count" -ge 2 ]
}

@test "reference: each job carries its own pinned first-party channel ref + matching agent_ref (AC #1)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  # Per-job pins reuse the EXISTING per-role channel tags (ADR-0002; no new tag
  # namespace). The pin moves from a per-file tag to a per-job pin.
  [[ "$output" == *"dev-lead-reusable.yml@dev-lead/v139-stable"* ]]
  [[ "$output" == *"agent_ref: dev-lead/v139-stable"* ]]
  [[ "$output" == *"pr-review-mention-reusable.yml@pr-review-mention/v2-next"* ]]
}

@test "reference: every job has an if: guard (AC #2)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  if_count="$(printf '%s\n' "$output" | grep -cE '^[[:space:]]+if:')"
  [ "$if_count" -ge 2 ]
}

@test "reference: the if: guards are PURE event filters — no repo-state reach (AC #2)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  # Extract only the if: guard region content and assert it references event
  # predicates and never repo state (the one place ADR-0007 loosens ADR-0001).
  [[ "$output" == *"github.event_name"* ]]
  # Forbidden repo-state reaches must NOT appear anywhere in the ingress.
  [[ "$output" != *"vars."* ]]
  [[ "$output" != *"hashFiles("* ]]
  [[ "$output" != *".outputs."* ]]
  [[ "$output" != *"default_branch"* ]]
  [[ "$output" != *"labels.*.name"* ]]
}

@test "reference: the ingress declares no steps/run — it stays a thin caller (ADR-0001)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  [[ "$output" != *"steps:"* ]]
  # A step's `run:` directive is a key at the start of a (indented) line; match it
  # anchored so the `check_run:` union trigger does not read as a run step.
  run_steps="$(printf '%s\n' "$output" | grep -cE '^[[:space:]]*run:' || true)"
  [ "$run_steps" -eq 0 ]
}

@test "list-workflows: the ingress is NOT seeded into repo-template — still exactly 10 stubs (AC #5)" {
  run bash "$SEED" --list-workflows
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent-ingress"* ]]
  n="$(printf '%s\n' "$output" | grep -c '\.yml$')"
  [ "$n" -eq 10 ]
}
