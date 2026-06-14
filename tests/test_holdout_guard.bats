#!/usr/bin/env bats
# Unit tests for scripts/lib/holdout-guard.sh
#
# The holdout guard is the hard CI enforcement that backs the advisory
# CODEOWNERS rule over evals/ (#692, epic #581). It fails any PR authored by the
# automated skill-proposer identity that changes a held-out path, keyed on
# PR author + changed paths. Human/CODEOWNER edits to evals/, and proposer edits
# to non-evals/ paths, must both pass.
#
# Run with: bats tests/test_holdout_guard.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/holdout-guard.sh"
  # Start from defaults; individual tests override via env where needed.
  unset HOLDOUT_PROPOSER_IDENTITIES
  unset HOLDOUT_GUARDED_PREFIXES
}

# ---------------------------------------------------------------------------
# hg_is_proposer — identity matching
# ---------------------------------------------------------------------------

@test "hg_is_proposer recognises the default proposer identity github-actions[bot]" {
  run hg_is_proposer "github-actions[bot]"
  [ "$status" -eq 0 ]
}

@test "hg_is_proposer is case-insensitive" {
  run hg_is_proposer "GitHub-Actions[bot]"
  [ "$status" -eq 0 ]
}

@test "hg_is_proposer rejects the dev-lead bot (donpetry-bot)" {
  # dev-lead authors eval-story PRs under donpetry-bot; it must NOT be gated,
  # otherwise this very story's PR would fail its own check.
  run hg_is_proposer "donpetry-bot"
  [ "$status" -ne 0 ]
}

@test "hg_is_proposer rejects a human login" {
  run hg_is_proposer "octocat"
  [ "$status" -ne 0 ]
}

@test "hg_is_proposer honours a configurable identity list" {
  export HOLDOUT_PROPOSER_IDENTITIES="skill-proposer[bot], another-bot"
  run hg_is_proposer "another-bot"
  [ "$status" -eq 0 ]
  run hg_is_proposer "skill-proposer[bot]"
  [ "$status" -eq 0 ]
  run hg_is_proposer "github-actions[bot]"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# hg_path_is_guarded — path prefix matching
# ---------------------------------------------------------------------------

@test "hg_path_is_guarded matches a path under evals/" {
  run hg_path_is_guarded "evals/triage/cases.jsonl"
  [ "$status" -eq 0 ]
}

@test "hg_path_is_guarded matches a holdout split path" {
  run hg_path_is_guarded "evals/example-skill/holdout/cases.jsonl"
  [ "$status" -eq 0 ]
}

@test "hg_path_is_guarded does not match a non-evals path" {
  run hg_path_is_guarded "prompts/triage.md"
  [ "$status" -ne 0 ]
}

@test "hg_path_is_guarded respects the prefix boundary (evalsomething/ is not evals/)" {
  run hg_path_is_guarded "evalsomething/foo.md"
  [ "$status" -ne 0 ]
}

@test "hg_path_is_guarded honours a configurable prefix list" {
  export HOLDOUT_GUARDED_PREFIXES="evals/ secret-set/"
  run hg_path_is_guarded "secret-set/holdout.jsonl"
  [ "$status" -eq 0 ]
  run hg_path_is_guarded "evals/triage/cases.jsonl"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# hg_evaluate — the full author + changed-paths decision (AC2 matrix)
# ---------------------------------------------------------------------------

@test "FAIL: proposer changing an evals/ path" {
  run hg_evaluate "github-actions[bot]" <<< "evals/triage/cases.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"evals/triage/cases.jsonl"* ]]
}

@test "FAIL: proposer changing a holdout split path" {
  run hg_evaluate "github-actions[bot]" <<< "evals/example-skill/holdout/cases.jsonl"
  [ "$status" -ne 0 ]
}

@test "PASS: proposer changing a non-evals path" {
  run hg_evaluate "github-actions[bot]" <<< "prompts/triage.md"
  [ "$status" -eq 0 ]
}

@test "PASS: human/CODEOWNER changing an evals/ path" {
  run hg_evaluate "donpetry-bot" <<< "evals/triage/cases.jsonl"
  [ "$status" -eq 0 ]
}

@test "FAIL: proposer with a mix of evals and non-evals paths" {
  run hg_evaluate "github-actions[bot]" <<< "$(printf 'prompts/triage.md\nevals/triage/cases.jsonl\n')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"evals/triage/cases.jsonl"* ]]
}

@test "PASS: non-proposer with a mix of evals and non-evals paths" {
  run hg_evaluate "octocat" <<< "$(printf 'prompts/triage.md\nevals/triage/cases.jsonl\n')"
  [ "$status" -eq 0 ]
}

@test "PASS: proposer with no changed paths" {
  run hg_evaluate "github-actions[bot]" <<< ""
  [ "$status" -eq 0 ]
}

@test "hg_evaluate ignores blank lines in the changed-paths stream" {
  run hg_evaluate "github-actions[bot]" <<< "$(printf '\n\nprompts/triage.md\n\n')"
  [ "$status" -eq 0 ]
}

@test "FAIL: hg_evaluate reports every offending guarded path" {
  run hg_evaluate "github-actions[bot]" <<< "$(printf 'evals/a.jsonl\nevals/b.jsonl\n')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"evals/a.jsonl"* ]]
  [[ "$output" == *"evals/b.jsonl"* ]]
}

@test "FAIL: hg_evaluate catches a guarded path with no trailing newline" {
  # A changed-paths source lacking a final newline must not drop its last line —
  # otherwise a proposer's evals/ change on the last line would falsely pass.
  run hg_evaluate "github-actions[bot]" < <(printf 'prompts/triage.md\nevals/triage/cases.jsonl')
  [ "$status" -ne 0 ]
  [[ "$output" == *"evals/triage/cases.jsonl"* ]]
}

@test "hg_evaluate errors when no author is given" {
  run hg_evaluate "" <<< "evals/triage/cases.jsonl"
  [ "$status" -eq 2 ]
}
