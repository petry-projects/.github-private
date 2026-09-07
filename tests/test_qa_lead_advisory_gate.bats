#!/usr/bin/env bats
# Unit tests for the qa-lead PR advisory gate decision
# (scripts/qa-lead-advisory-gate.sh, issue #1646 — [qa-lead S3]).
#
# The gate composes the pure test-surface heuristic (AC #3) with the opt-out
# label (AC #4), per-PR idempotency (AC #5), and the budget / human-gate markers
# (AC #6). The workflow gathers the PR's signals (changed files, labels, comment
# markers, budget events) and calls qa_lead_gate_decision, which is pure and
# unit-tested here so every suppressor has a regression test.
#
# It reuses pr_has_escalation_label from scripts/lib/pr-automation-budget.sh as
# the canonical needs-human-review check (AC #6) rather than re-deriving it.
#
# Run with: bats tests/test_qa_lead_advisory_gate.bats

setup() {
  # Sourcing the gate script pulls in the heuristic + budget libs and defines the
  # pure decision function without running main (guarded by BASH_SOURCE == $0).
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/qa-lead-advisory-gate.sh"
}

# args: <changed_paths> <labels_json> <existing_advisory 0|1> <budget_exhausted 0|1>
FIRES_PATHS="$(printf 'scripts/lib/foo.sh\ntests/test_foo.bats\n')"

# ---------------------------------------------------------------------------
# The happy path — real test surface, no suppressor
# ---------------------------------------------------------------------------

@test "runs when there is test surface and no suppressor" {
  run qa_lead_gate_decision "$FIRES_PATHS" '[]' 0 0
  [ "$status" -eq 0 ]
  [ "$output" = "run" ]
}

# ---------------------------------------------------------------------------
# AC #3 — no test surface never runs, regardless of everything else
# ---------------------------------------------------------------------------

@test "AC#3: a docs-only PR skips (no test surface)" {
  run qa_lead_gate_decision "$(printf 'README.md\n')" '[]' 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == skip:no-test-surface* ]]
}

# ---------------------------------------------------------------------------
# AC #4 — the opt-out label suppresses
# ---------------------------------------------------------------------------

@test "AC#4: qa-lead:hands-off suppresses the advisory" {
  run qa_lead_gate_decision "$FIRES_PATHS" '["qa-lead:hands-off"]' 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == skip:opt-out* ]]
}

# ---------------------------------------------------------------------------
# AC #5 — one advisory per PR (open-as-draft then ready_for_review must not stack)
# ---------------------------------------------------------------------------

@test "AC#5: an existing qa-lead advisory suppresses a second run" {
  run qa_lead_gate_decision "$FIRES_PATHS" '[]' 1 0
  [ "$status" -ne 0 ]
  [[ "$output" == skip:already-advised* ]]
}

# ---------------------------------------------------------------------------
# AC #6 — budget / human gates suppress; pr_has_escalation_label is canonical
# ---------------------------------------------------------------------------

@test "AC#6: needs-human-review suppresses (canonical pr_has_escalation_label)" {
  run qa_lead_gate_decision "$FIRES_PATHS" '["needs-human-review"]' 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == skip:human-gated* ]]
}

@test "AC#6: dev-lead:needs-human suppresses" {
  run qa_lead_gate_decision "$FIRES_PATHS" '["dev-lead:needs-human"]' 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == skip:human-gated* ]]
}

@test "AC#6: an exhausted automation budget suppresses" {
  run qa_lead_gate_decision "$FIRES_PATHS" '[]' 0 1
  [ "$status" -ne 0 ]
  [[ "$output" == skip:budget-exhausted* ]]
}

# ---------------------------------------------------------------------------
# The helper reused by the gate — pr_has_escalation_label must be in scope
# ---------------------------------------------------------------------------

@test "pr_has_escalation_label is sourced and usable by the gate" {
  run pr_has_escalation_label '["needs-human-review"]'
  [ "$status" -eq 0 ]
  run pr_has_escalation_label '["something-else"]'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# qa_lead_labels_contain — the generic label predicate used for the two
# non-canonical labels (opt-out and dev-lead:needs-human)
# ---------------------------------------------------------------------------

@test "qa_lead_labels_contain matches an exact label and rejects a near-miss" {
  run qa_lead_labels_contain '["qa-lead:hands-off","x"]' "qa-lead:hands-off"
  [ "$status" -eq 0 ]
  run qa_lead_labels_contain '["qa-lead:hands"]' "qa-lead:hands-off"
  [ "$status" -ne 0 ]
}
