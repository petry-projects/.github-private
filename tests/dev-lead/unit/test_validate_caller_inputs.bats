#!/usr/bin/env bats
# Tests for scripts/validate-caller-inputs.sh — the Part A guard (#1052) that
# asserts a caller stub's forwarded `with:` keys are a subset of the reusable's
# `workflow_call.inputs` DECLARED AT THE PINNED REF, and that every required
# input is forwarded. This is the prevention for the #1034 incident: an input
# forwarded on a channel-pinned stub that the pinned channel does not declare,
# which is green in PR CI (validated only against HEAD/same-repo) yet ends the
# first real run in `startup_failure`.
#
# All assertions here are PURE (no network): they exercise the YAML-extraction
# and set-difference helpers over local fixtures. The network driver (resolving
# a reusable at a channel tag via `git fetch` / `gh api`) runs in CI. Run:
#   bats tests/dev-lead/unit/test_validate_caller_inputs.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME"/../../.. && pwd)"
  FIX="$REPO_ROOT/tests/dev-lead/fixtures/caller-inputs"
  # shellcheck source=scripts/validate-caller-inputs.sh
  source "$REPO_ROOT/scripts/validate-caller-inputs.sh"
}

# ---------------------------------------------------------------------------
# YAML extraction: declared workflow_call inputs
# ---------------------------------------------------------------------------

@test "extract_declared_inputs: lists every declared input at the pinned ref" {
  run extract_declared_inputs "$FIX/reusable_pinned.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"pr_url"* ]]
  [[ "$output" == *"dry_run"* ]]
  [[ "$output" == *"force_review"* ]]
}

@test "extract_declared_inputs: does NOT invent an input the pinned ref lacks" {
  run extract_declared_inputs "$FIX/reusable_pinned.yml"
  [ "$status" -eq 0 ]
  [[ "$output" != *"lsp_pilot_variant"* ]]
}

@test "extract_declared_inputs: ignores keys outside on.workflow_call.inputs" {
  # The job name 'review' and the secret 'CLAUDE_CODE_OAUTH_TOKEN' live outside
  # inputs and must not be picked up (whole-line match — 'force_review' is a real
  # input that legitimately contains the substring 'review').
  local declared
  declared="$(extract_declared_inputs "$FIX/reusable_pinned.yml")"
  run grep -qxF "review" <<< "$declared"
  [ "$status" -ne 0 ]
  run grep -qxF "CLAUDE_CODE_OAUTH_TOKEN" <<< "$declared"
  [ "$status" -ne 0 ]
}

@test "extract_required_inputs: returns only required:true inputs" {
  run extract_required_inputs "$FIX/reusable_required.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"must_have"* ]]
  [[ "$output" != *"opt"* ]]
}

# ---------------------------------------------------------------------------
# YAML extraction: caller `with:` keys and the reusable `uses:` ref
# ---------------------------------------------------------------------------

@test "extract_with_keys: returns every forwarded key of the reusable call" {
  run extract_with_keys "$FIX/caller_1034.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"pr_url"* ]]
  [[ "$output" == *"lsp_pilot_variant"* ]]
  # 'secrets' is a sibling of `with:`, not a forwarded input.
  [[ "$output" != *"secrets"* ]]
}

@test "extract_reusable_uses: returns the reusable uses ref, not third-party actions" {
  run extract_reusable_uses "$FIX/caller_1034.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next" ]
}

@test "parse_caller_uses: splits owner/repo, workflow file, and slash-bearing ref" {
  run parse_caller_uses "petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'petry-projects/.github-private\tpr-review.yml\tpr-review/next')" ]
}

# ---------------------------------------------------------------------------
# Pure set-difference validators
# ---------------------------------------------------------------------------

@test "inputs_not_declared: passes when every forwarded key is declared" {
  run inputs_not_declared "$(printf 'a\nb\nc\n')" "$(printf 'a\nb\n')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inputs_not_declared: fails and names the undeclared key" {
  run inputs_not_declared "$(printf 'a\nb\n')" "$(printf 'a\nb\nz\n')"
  [ "$status" -ne 0 ]
  [ "$output" = "z" ]
}

@test "required_not_forwarded: fails when a required input is not forwarded" {
  run required_not_forwarded "$(printf 'must_have\n')" "$(printf 'opt\n')"
  [ "$status" -ne 0 ]
  [ "$output" = "must_have" ]
}

@test "required_not_forwarded: passes when the required input is forwarded" {
  run required_not_forwarded "$(printf 'must_have\n')" "$(printf 'must_have\nopt\n')"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# End-to-end over fixtures: the #1034 regression + the safe (current-main) shape
# ---------------------------------------------------------------------------

@test "REGRESSION #1034: a key forwarded but absent at the pinned ref FAILS" {
  declared="$(extract_declared_inputs "$FIX/reusable_pinned.yml")"
  forwarded="$(extract_with_keys "$FIX/caller_1034.yml")"
  run inputs_not_declared "$declared" "$forwarded"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lsp_pilot_variant"* ]]
}

@test "current main shape: every forwarded key is declared → PASSES" {
  declared="$(extract_declared_inputs "$FIX/reusable_pinned.yml")"
  forwarded="$(extract_with_keys "$FIX/caller_ok.yml")"
  run inputs_not_declared "$declared" "$forwarded"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "required check over fixtures: caller forwarding no required input FAILS" {
  required="$(extract_required_inputs "$FIX/reusable_required.yml")"
  # caller_ok forwards agent_ref/pr_url/... but not must_have
  forwarded="$(extract_with_keys "$FIX/caller_ok.yml")"
  run required_not_forwarded "$required" "$forwarded"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must_have"* ]]
}
