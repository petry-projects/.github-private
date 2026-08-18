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
# Prints "True"/"False" (or a value) so bats can assert on stdout.
_lint_yaml() {
  LINT_YML="$LINT_YML" python3 - "$1" <<'PY'
import os, sys

try:
    import yaml
    def parse_yaml(text):
        return yaml.safe_load(text)
except ImportError:
    def parse_yaml(text):
        root = {}
        stack = [(-1, root, None)]
        for line in text.splitlines():
            trimmed = line.strip()
            if not trimmed or trimmed.startswith('#'):
                continue
            indent = len(line) - len(line.lstrip())
            while stack[-1][0] >= indent:
                stack.pop()
            _, parent, parent_key = stack[-1]
            if trimmed.startswith('-'):
                val = trimmed[1:].strip().strip("'\"")
                _, container, key = stack[-1]
                if isinstance(container, dict) and not container:
                    container = []
                    _, grandparent, _ = stack[-2]
                    grandparent[key] = container
                    stack[-1] = (stack[-1][0], container, key)
                if isinstance(container, list):
                    container.append(val)
            elif ':' in trimmed:
                key, val = trimmed.split(':', 1)
                key = key.strip().strip("'\"")
                val = val.strip().strip("'\"")
                if val:
                    if val.lower() == 'true': val = True
                    elif val.lower() == 'false': val = False
                    parent[key] = val
                else:
                    new_dict = {}
                    parent[key] = new_dict
                    stack.append((indent, new_dict, key))
        return root

with open(os.environ["LINT_YML"], encoding="utf-8") as fh:
    doc = parse_yaml(fh.read())

if not isinstance(doc, dict):
    raise TypeError(f"Expected YAML root to be a dictionary, got {type(doc).__name__}")

# PyYAML parses the bare `on:` key as the boolean True (YAML 1.1). Normalize so
# expressions can reference it as `on`.
on = doc.get("on", doc.get(True))
if on is None:
    raise KeyError("The 'on' trigger section is missing from the workflow file.")
if not isinstance(on, dict):
    raise TypeError(f"Expected 'on' section to be a dictionary, got {type(on).__name__}")

jobs = doc.get("jobs", {})
if not isinstance(jobs, dict):
    raise TypeError(f"Expected 'jobs' section to be a dictionary, got {type(jobs).__name__}")

print(eval(sys.argv[1]))
PY
}

@test "lint.yml declares a push trigger scoped to the main branch (AC1)" {
  run _lint_yaml "(on.get('push') or {}).get('branches', []) == ['main']"
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
  run _lint_yaml "set(['scripts/**','.github/workflows/**','tests/**','agents/**','personas/**','interaction-contracts/**','evals/**','release/**','.gitleaks.toml']).issubset(set((on.get('pull_request') or {}).get('paths', [])))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "template-drift is excluded from main-push runs until #1448 is resolved (AC4)" {
  run _lint_yaml "\"github.event_name != 'push'\" in str((jobs.get('template-drift') or {}).get('if', ''))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}
