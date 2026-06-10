#!/usr/bin/env bats
# Unit tests for tests/dev-lead/integration/test_concurrency_config.sh
#
# Regression guard for the silent-exit bug: when a workflow file has no
# concurrency block, grep -v '^\s*#' on empty input exits 1. With
# set -euo pipefail active, bash triggers set -e on the block=$(...|grep)
# assignment in non-interactive (script) mode, causing test_concurrency_config.sh
# to exit silently (no FAIL messages, no diagnostic output) — making failures
# look like infra noise rather than real test failures.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
readonly SCRIPT_DIR
CONCURRENCY_TEST="$SCRIPT_DIR/tests/dev-lead/integration/test_concurrency_config.sh"
readonly CONCURRENCY_TEST

setup() {
  WORK_DIR="$(mktemp -d)" || {
    echo "ERROR: Failed to create temporary directory" >&2
    exit 1
  }
  mkdir -p "$WORK_DIR/.github/workflows"
  # Run the script from WORK_DIR so its relative .github/workflows/ paths resolve
  pushd "$WORK_DIR" > /dev/null || {
    echo "ERROR: Failed to change to test directory" >&2
    exit 1
  }
}

teardown() {
  popd > /dev/null 2>&1 || true
  if [ -n "${WORK_DIR:-}" ]; then
    rm -rf "$WORK_DIR"
  fi
}

_write_proper_reusable() {
  cat > "$WORK_DIR/.github/workflows/dev-lead-reusable.yml" << 'YAML'
name: Dev-Lead Agent (Reusable)
on:
  workflow_call: {}
permissions: {}
concurrency:
  group: >-
    ${{
      (github.event_name == 'check_run' && format('dev-lead-ci-relay-{0}', github.event.check_run.head_sha))
      || (github.event.pull_request.number && format('dev-lead-pr-{0}', github.event.pull_request.number))
      || (github.event.issue.pull_request && format('dev-lead-pr-{0}', github.event.issue.number))
      || (github.event.issue.number && format('dev-lead-issue-{0}', github.event.issue.number))
      || (github.event.client_payload.pr_number && format('dev-lead-pr-{0}', github.event.client_payload.pr_number))
      || format('dev-lead-run-{0}', github.run_id)
    }}
  cancel-in-progress: false
jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
}

_write_proper_inline() {
  # Proper thin-caller stub: no top-level concurrency block (reusable owns it).
  cat > "$WORK_DIR/.github/workflows/dev-lead.yml" << 'YAML'
name: Dev-Lead Agent
on:
  issues:
    types: [labeled]
permissions: {}
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@main
    secrets: inherit
YAML
}

# ── silent-exit regression tests ─────────────────────────────────────────────

@test "concurrency-config: exit 1 with FAIL output when dev-lead.yml has a top-level concurrency block" {
  # Inline caller — carries its own concurrency block, violating the stub-only rule;
  # the reusable is the single source of truth for concurrency config.
  cat > "$WORK_DIR/.github/workflows/dev-lead.yml" << 'YAML'
name: Dev-Lead Agent
on:
  issues:
    types: [labeled]
permissions:
  contents: write
concurrency:
  group: dev-lead-pr-123
  cancel-in-progress: false
jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
  _write_proper_reusable

  run bash "$CONCURRENCY_TEST"

  [ "$status" -eq 1 ]
  # Must produce FAIL output — not a silent exit
  [[ "$output" =~ "FAIL" ]]
}

@test "concurrency-config: exit 1 with FAIL output when dev-lead.yml concurrency block is comments-only" {
  # Concurrency section exists but all content lines are comments — effectively empty
  cat > "$WORK_DIR/.github/workflows/dev-lead.yml" << 'YAML'
name: Dev-Lead Agent
on:
  issues:
    types: [labeled]
concurrency:
  # This comment-only block should not satisfy any assertion
  # group: intentionally omitted
  # cancel-in-progress: intentionally omitted
jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
  _write_proper_reusable

  run bash "$CONCURRENCY_TEST"

  [ "$status" -eq 1 ]
  [[ "$output" =~ "FAIL" ]]
}

@test "concurrency-config: exit 1 with FAIL output when dev-lead-reusable.yml has no concurrency block" {
  _write_proper_inline
  cat > "$WORK_DIR/.github/workflows/dev-lead-reusable.yml" << 'YAML'
name: Dev-Lead Agent (Reusable)
on:
  workflow_call: {}
permissions: {}
jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML

  run bash "$CONCURRENCY_TEST"

  [ "$status" -eq 1 ]
  [[ "$output" =~ "FAIL" ]]
}

# ── passing baseline ──────────────────────────────────────────────────────────

@test "concurrency-config: passes when both files have correct concurrency config" {
  _write_proper_inline
  _write_proper_reusable

  run bash "$CONCURRENCY_TEST"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "All concurrency config checks passed." ]]
}
