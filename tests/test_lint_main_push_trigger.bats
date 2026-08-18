#!/usr/bin/env bats
# Guard for #1486 (epic #1402): the `bats` job in lint.yml must re-run against
# actual trunk state after every merge, so shell-script behavioral regressions
# surface post-merge with the same parity `unit` (test-dev-lead.yml) already has.
#
# These tests pin the lint.yml trigger wiring so a future template sync cannot
# silently drop the main-push trigger (AC1), change PR-triggered behavior (AC2),
# or wire the known-red `template-drift` job (#1448) into the main-push path
# before that issue is resolved (AC4).
#
# Run with: bats tests/test_lint_main_push_trigger.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LINT_YML="$REPO_ROOT/.github/workflows/lint.yml"
}

# Helper: evaluate a python expression against the parsed lint.yml document.
# Prints "true"/"false" (or a value) so bats can assert on stdout.
_lint_yaml() {
  LINT_YML="$LINT_YML" python3 - "$1" <<'PY'
import os, sys, yaml
with open(os.environ["LINT_YML"], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
# PyYAML parses the bare `on:` key as the boolean True (YAML 1.1). Normalize so
# expressions can reference it as `on`.
on = doc.get("on", doc.get(True))
jobs = doc.get("jobs", {})
print(eval(sys.argv[1]))
PY
}

@test "lint.yml declares a push trigger scoped to the main branch (AC1)" {
  run _lint_yaml "'main' in (on.get('push') or {}).get('branches', [])"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "lint.yml main-push trigger is paths-filtered to the bats-relevant paths (AC1)" {
  run _lint_yaml "set(['scripts/**','tests/**','.github/workflows/**']).issubset(set((on.get('push') or {}).get('paths', [])))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "lint.yml still triggers on pull_request — PR behavior unchanged (AC2)" {
  run _lint_yaml "'pull_request' in on"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "lint.yml pull_request paths are unchanged by the push wiring (AC2)" {
  run _lint_yaml "set(['scripts/**','.github/workflows/**','tests/**','agents/**','personas/**','interaction-contracts/**','evals/**','release/**','.gitleaks.toml']).issubset(set(on['pull_request'].get('paths', [])))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "template-drift is excluded from main-push runs until #1448 is resolved (AC4)" {
  run _lint_yaml "\"github.event_name != 'push'\" in str(jobs.get('template-drift', {}).get('if', ''))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}
