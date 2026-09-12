#!/usr/bin/env bats
# Tests for scripts/validate-ingress-if.sh — the if:-as-event-filter-only guard
# for ADR-0007 agent-ingress jobs (#1725 AC #3, epic #1723).
#
# An ingress job's `if:` is the ONE place ADR-0007 loosens ADR-0001: it may
# reference ONLY the delivered event (github.event_name / github.event.action /
# plain payload predicates) and MUST NOT reach for repo state (vars, secrets,
# another job's computed outputs, the repo tree via hashFiles, repo identity, the
# payload's standing default_branch, or the standing labels array).
#
# The frozen ALLOW/FORBID rulings live as a machine-readable table at
# tests/fixtures/agent-ingress/if-filter-rulings.tsv. This guard and this test
# BOTH consume that table directly (QA test-risk #8: one parameterised table, not
# two suites), so they cannot drift apart on an ambiguous construct.
#
# Run: bats tests/test_validate_ingress_if.bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/validate-ingress-if.sh"
  RULINGS="${REPO_ROOT}/tests/fixtures/agent-ingress/if-filter-rulings.tsv"
  SAMPLES="${REPO_ROOT}/tests/fixtures/agent-ingress/ingress-samples"
  # shellcheck source=scripts/validate-ingress-if.sh
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# viif_forbidden — the pure event-filter boundary detector. Given an if:
# expression, print the FORBID construct name(s) it reaches for; empty + 0 if it
# is a pure event filter.
# ---------------------------------------------------------------------------

@test "viif_forbidden: a pure event-name predicate is allowed (no forbidden token)" {
  run viif_forbidden "github.event_name == 'issue_comment'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "viif_forbidden: an org/repo config variable is forbidden" {
  run viif_forbidden "github.event_name == 'pull_request' && vars.DEV_LEAD_ENGINE == 'claude'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vars"* ]]
}

@test "viif_forbidden: the singular label delta is allowed but the standing labels array is forbidden" {
  run viif_forbidden "github.event.label.name == 'agent-ready'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run viif_forbidden "contains(github.event.pull_request.labels.*.name, 'agent-ready')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"labels-array-contains"* ]]
}

@test "viif_forbidden: base.ref is allowed but repository.default_branch is forbidden" {
  run viif_forbidden "github.event.pull_request.base.ref == 'main'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run viif_forbidden "github.event.repository.default_branch == 'main'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"default-branch"* ]]
}

@test "viif_forbidden: repo identity reached via the event payload is forbidden too" {
  # github.repository is not the only path to repo identity — the same identity
  # rides in the delivered payload as github.event.repository.{name,full_name,
  # owner.login,...}. Gating a role on WHICH repo it is is enrollment/config
  # regardless of the spelling, so repo-identity must catch these too.
  run viif_forbidden "github.event.repository.name == 'some-repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-identity"* ]]

  run viif_forbidden "github.event.repository.full_name == 'petry-projects/some-repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-identity"* ]]

  run viif_forbidden "github.event.repository.owner.login == 'petry-projects'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-identity"* ]]
}

# ---------------------------------------------------------------------------
# Parameterised over the FROZEN rulings table: every ALLOW row's representative
# expression must be permitted; every FORBID row's must be rejected AND name the
# construct. A newly added row is thereby answered for free, and the guard cannot
# silently under-enforce a declared FORBID construct.
# ---------------------------------------------------------------------------

@test "rulings table: every ALLOW row is permitted by the guard" {
  local name verdict expr rationale
  while IFS=$'\t' read -r name verdict expr rationale; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$verdict" = "ALLOW" ] || continue
    run viif_forbidden "$expr"
    if [ "$status" -ne 0 ]; then
      echo "ALLOW row '$name' was wrongly rejected: expr=[$expr] output=[$output]"
      return 1
    fi
  done < "$RULINGS"
}

@test "rulings table: every FORBID row is rejected and names its construct" {
  local name verdict expr rationale
  while IFS=$'\t' read -r name verdict expr rationale; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$verdict" = "FORBID" ] || continue
    run viif_forbidden "$expr"
    if [ "$status" -eq 0 ]; then
      echo "FORBID row '$name' was wrongly permitted: expr=[$expr]"
      return 1
    fi
    if [[ "$output" != *"$name"* ]]; then
      echo "FORBID row '$name' rejected but the construct name was not reported: output=[$output]"
      return 1
    fi
  done < "$RULINGS"
}

# ---------------------------------------------------------------------------
# File-level validation over fixture ingress files.
# ---------------------------------------------------------------------------

@test "file: a pure event-filter ingress passes" {
  run viif_validate_ingress "${SAMPLES}/good.yml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "file: an ingress whose job if: reaches for repo state FAILS with a named message" {
  run viif_validate_ingress "${SAMPLES}/repo-state.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"vars"* ]]
}

@test "file: a malformed/schema-invalid ingress FAILS (job with no reusable uses:)" {
  run viif_validate_ingress "${SAMPLES}/malformed.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"dev-lead"* ]]
}

# ---------------------------------------------------------------------------
# Repo scan: no live agent-ingress.yml yet (it is a docs reference until the
# collapse story), so a scan of a tree without one is a clean pass — never a
# silent skip that hides an absent guard.
# ---------------------------------------------------------------------------

@test "scan: a tree with no agent-ingress.yml passes cleanly" {
  empty="$(mktemp -d "${BATS_TEST_TMPDIR}/root.XXXXXX")"
  mkdir -p "$empty/.github/workflows"
  run env VIIF_ROOT="$empty" bash "$SCRIPT"
  rm -rf "$empty"
  [ "$status" -eq 0 ]
}

@test "scan: a tree WITH a repo-state ingress fails" {
  root="$(mktemp -d "${BATS_TEST_TMPDIR}/root.XXXXXX")"
  mkdir -p "$root/.github/workflows"
  cp "${SAMPLES}/repo-state.yml" "$root/.github/workflows/agent-ingress.yml"
  run env VIIF_ROOT="$root" bash "$SCRIPT"
  rm -rf "$root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vars"* ]]
}
