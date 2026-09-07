#!/usr/bin/env bats
# Unit tests for the qa-lead PR test-surface heuristic
# (scripts/lib/qa-lead-test-surface.sh, issue #1646 — [qa-lead S3]).
#
# S3 wires a Class 1 pull_request:[opened, ready_for_review] trigger for qa-lead
# (the 2026-09-07 ruling; synchronize deliberately NOT wired). The heuristic is
# the ONLY thing standing between "qa-lead becomes useful" and "qa-lead becomes
# noise" (AC #3), so it is a pure, sourced helper pinned by this suite.
#
# The heuristic: qa-lead advises on a PR that carries REAL test surface —
#   * any changed path under tests/ (or a conventional test file), OR
#   * a source-code change with no accompanying test change.
# It stays silent on docs-only PRs and on verbatim stub-sync PRs (workflow /
# config yaml only). A PR that comments on nothing of test-relevance is a
# regression even if each comment is individually correct.
#
# The four AC #3 cases are the load-bearing tests: a test-touching PR fires, a
# docs-only PR does not, a verbatim stub-sync PR does not, a
# source-change-without-tests PR fires.
#
# Run with: bats tests/test_qa_lead_test_surface.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/qa-lead-test-surface.sh"
}

# ---------------------------------------------------------------------------
# qa_lead_classify_path — the per-path classifier
# ---------------------------------------------------------------------------

@test "classify: a path under tests/ is TEST" {
  run qa_lead_classify_path "tests/test_foo.bats"
  [ "$output" = "TEST" ]
}

@test "classify: a .bats file anywhere is TEST" {
  run qa_lead_classify_path "tests/dev-lead/unit/test_foo.bats"
  [ "$output" = "TEST" ]
}

@test "classify: a conventional test filename is TEST" {
  run qa_lead_classify_path "pkg/foo_test.go"
  [ "$output" = "TEST" ]
}

@test "classify: a markdown doc is DOCS" {
  run qa_lead_classify_path "README.md"
  [ "$output" = "DOCS" ]
}

@test "classify: a path under docs/ is DOCS" {
  run qa_lead_classify_path "docs/agentic-interaction-model.md"
  [ "$output" = "DOCS" ]
}

@test "classify: a shell script is SOURCE" {
  run qa_lead_classify_path "scripts/lib/foo.sh"
  [ "$output" = "SOURCE" ]
}

@test "classify: a python module is SOURCE" {
  run qa_lead_classify_path "personas/validate-personas.py"
  [ "$output" = "SOURCE" ]
}

@test "classify: a workflow yaml stub is OTHER (no test surface)" {
  run qa_lead_classify_path ".github/workflows/dev-lead.yml"
  [ "$output" = "OTHER" ]
}

@test "classify: a json manifest is OTHER" {
  run qa_lead_classify_path "scripts/lib/consumer-manifest.json"
  [ "$output" = "OTHER" ]
}

# ---------------------------------------------------------------------------
# qa_lead_test_surface — the fire/skip decision (AC #3, the four cases)
# ---------------------------------------------------------------------------

@test "AC#3: a test-touching PR fires" {
  run qa_lead_test_surface "$(printf 'scripts/lib/foo.sh\ntests/test_foo.bats\n')"
  [ "$status" -eq 0 ]
}

@test "AC#3: a docs-only PR does NOT fire" {
  run qa_lead_test_surface "$(printf 'README.md\ndocs/guide.md\n')"
  [ "$status" -ne 0 ]
}

@test "AC#3: a verbatim stub-sync PR does NOT fire" {
  run qa_lead_test_surface "$(printf '.github/workflows/dev-lead.yml\n.github/workflows/auto-rebase.yml\n')"
  [ "$status" -ne 0 ]
}

@test "AC#3: a source-change-without-tests PR fires" {
  run qa_lead_test_surface "$(printf 'scripts/lib/foo.sh\n')"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# qa_lead_test_surface — edge cases
# ---------------------------------------------------------------------------

@test "an empty changed-file set does NOT fire" {
  run qa_lead_test_surface ""
  [ "$status" -ne 0 ]
}

@test "blank lines are ignored and do not force a fire" {
  run qa_lead_test_surface "$(printf '\n\nREADME.md\n\n')"
  [ "$status" -ne 0 ]
}

@test "a mixed docs + config PR (no code, no tests) does NOT fire" {
  run qa_lead_test_surface "$(printf 'docs/x.md\npersonas/qa-lead/persona.yml\n.github/workflows/foo.yml\n')"
  [ "$status" -ne 0 ]
}

@test "a source change accompanied by a test change fires (test surface present)" {
  run qa_lead_test_surface "$(printf 'scripts/lib/foo.sh\ntests/test_foo.bats\ndocs/foo.md\n')"
  [ "$status" -eq 0 ]
}
