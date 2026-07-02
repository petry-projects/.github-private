#!/usr/bin/env bats
# Unit tests for the deterministic PR safety checks (issue #305): the pure
# functions in scripts/lib/safety-checks.sh. These re-implement the mechanical
# half of PR #131's 7 safety checks against the current cascade architecture.
#
# Everything here is deterministic and side-effect-free — no `gh`, no network —
# so each check is reproducible and unit-testable in isolation (mirrors the
# jq/awk-program style of scripts/lib/downstream-impact.sh).
#
# Run with: bats tests/test_safety_checks.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/safety-checks.sh"
}

# ---------------------------------------------------------------------------
# Check 1 — CI weakening (deterministic, hard-stop)
# ---------------------------------------------------------------------------

@test "ci-weakening: flags an added test-skip marker" {
  local diff='diff --git a/tests/foo.test.js b/tests/foo.test.js
--- a/tests/foo.test.js
+++ b/tests/foo.test.js
@@ -1,3 +1,4 @@
 describe("x", () => {
-  it("works", () => {});
+  it.skip("works", () => {});
 });'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "skip"
  echo "$output" | grep -q "tests/foo.test.js"
}

@test "ci-weakening: flags continue-on-error: true added to a workflow" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -10,3 +10,4 @@ jobs:
     steps:
       - run: npm test
+        continue-on-error: true'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "continue-on-error"
}

@test "ci-weakening: flags if: false disabling a step" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -10,3 +10,4 @@ jobs:
     steps:
+      - if: false
       - run: npm test'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "if: false"
}

@test "ci-weakening: flags a lowered numeric coverage threshold" {
  local diff='diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,3 +1,3 @@
 [tool.coverage]
-fail_under = 90
+fail_under = 50'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "threshold"
}

@test "ci-weakening: does NOT flag a raised coverage threshold" {
  local diff='diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,3 +1,3 @@
 [tool.coverage]
-fail_under = 50
+fail_under = 90'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci-weakening: clean diff yields no findings" {
  local diff='diff --git a/src/app.js b/src/app.js
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,3 @@
 const x = 1;
+const y = 2;'
  run sc_ci_weakening "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Check 2 — Prompt injection in workflows (deterministic, hard-stop)
# ---------------------------------------------------------------------------

@test "prompt-injection: flags github.event.*.body interpolated in a run step" {
  local diff='diff --git a/.github/workflows/triage.yml b/.github/workflows/triage.yml
--- a/.github/workflows/triage.yml
+++ b/.github/workflows/triage.yml
@@ -5,3 +5,4 @@ jobs:
     steps:
       - run: |
+          echo "${{ github.event.issue.body }}" | process'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -qi "github.event"
}

@test "prompt-injection: flags pull_request_target usage" {
  local diff='diff --git a/.github/workflows/label.yml b/.github/workflows/label.yml
--- a/.github/workflows/label.yml
+++ b/.github/workflows/label.yml
@@ -1,2 +1,3 @@
 name: label
+on: pull_request_target'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "pull_request_target"
}

@test "prompt-injection: flags write-all token permissions" {
  local diff='diff --git a/.github/workflows/deploy.yml b/.github/workflows/deploy.yml
--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -1,2 +1,3 @@
 name: deploy
+permissions: write-all'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "write-all"
}

@test "prompt-injection: ignores github.event interpolation OUTSIDE workflow files" {
  local diff='diff --git a/docs/README.md b/docs/README.md
--- a/docs/README.md
+++ b/docs/README.md
@@ -1,2 +1,3 @@
 example:
+  echo "${{ github.event.issue.body }}"'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prompt-injection: clean workflow change yields no findings" {
  local diff='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -1,2 +1,3 @@
 name: ci
+  timeout-minutes: 10'
  run sc_prompt_injection "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Check 3 — Large-PR gate (deterministic, from metadata)
# ---------------------------------------------------------------------------

@test "large-pr: over the file threshold with no plan section is gated" {
  local meta='{"changedFiles":120,"additions":50,"deletions":10,"body":"just a quick change"}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == true* ]]
}

@test "large-pr: over threshold WITH an implementation-plan section is not gated" {
  local meta='{"changedFiles":120,"additions":50,"deletions":10,"body":"## Implementation plan\n- step one\n- step two"}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == false* ]]
}

@test "large-pr: just under the file threshold is not gated" {
  local meta='{"changedFiles":49,"additions":10,"deletions":10,"body":""}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == false* ]]
}

@test "large-pr: high line count with no plan section is gated" {
  local meta='{"changedFiles":5,"additions":900,"deletions":600,"body":"small file count big churn"}'
  run sc_large_pr "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == true* ]]
}

# ---------------------------------------------------------------------------
# Check 4 — Description quality (deterministic, from metadata)
# ---------------------------------------------------------------------------

@test "description-quality: all 5 sections present -> 0 missing" {
  local meta='{"body":"## Problem\nx\n## Risk category\nlow\n## Test plan\nran tests\n## Rollback\nrevert\n## Monitoring\nmetrics dashboard"}'
  run sc_description_missing "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == 0\|* ]]
}

@test "description-quality: empty body -> 5 missing" {
  local meta='{"body":""}'
  run sc_description_missing "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == 5\|* ]]
}

@test "description-quality: only 2 of 5 present -> 3 missing (escalation boundary)" {
  local meta='{"body":"## Problem statement\nthe bug\n## Test plan\ncovered by unit tests"}'
  run sc_description_missing "$meta"
  [ "$status" -eq 0 ]
  [[ "$output" == 3\|* ]]
}

# ---------------------------------------------------------------------------
# Check 7 — Dependency risk (deterministic parse; LLM narrative lives in Tier 2)
# ---------------------------------------------------------------------------

@test "dependency-risk: flags an unpinned caret range added to package.json" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -3,4 +3,5 @@
   "dependencies": {
     "lodash": "4.17.21",
+    "left-pad": "^1.3.0"
   }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q "left-pad"
}

@test "dependency-risk: flags a 'latest' range" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -3,4 +3,5 @@
   "dependencies": {
+    "chalk": "latest"
   }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "latest"
}

@test "dependency-risk: does NOT flag an exactly-pinned dependency" {
  local diff='diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -3,4 +3,5 @@
   "dependencies": {
+    "lodash": "4.17.21"
   }'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dependency-risk: ignores non-manifest files" {
  local diff='diff --git a/src/app.js b/src/app.js
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,3 @@
+const dep = "^1.0.0";'
  run sc_dependency_risk "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Aggregate — compute_safety_checks emits a structured block + hard-stop flags
# ---------------------------------------------------------------------------

@test "compute: emits both hard-stop flags as false for a clean PR" {
  local meta='{"changedFiles":2,"additions":5,"deletions":1,"body":"## Problem\n## Risk\n## Test plan\n## Rollback\n## Monitoring"}'
  local diff='diff --git a/src/app.js b/src/app.js
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,3 @@
+const y = 2;'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED: false"
  echo "$output" | grep -q "PROMPT_INJECTION_DETECTED: false"
}

@test "compute: sets CI_WEAKENING_DETECTED true when a skip is added" {
  local meta='{"changedFiles":1,"additions":1,"deletions":1,"body":""}'
  local diff='diff --git a/a.test.js b/a.test.js
--- a/a.test.js
+++ b/a.test.js
@@ -1,1 +1,1 @@
+it.skip("x", () => {});'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED: true"
}

@test "compute: sets PROMPT_INJECTION_DETECTED true for a dangerous workflow edit" {
  local meta='{"changedFiles":1,"additions":1,"deletions":0,"body":""}'
  local diff='diff --git a/.github/workflows/x.yml b/.github/workflows/x.yml
--- a/.github/workflows/x.yml
+++ b/.github/workflows/x.yml
@@ -1,1 +1,2 @@
 name: x
+        run: echo "${{ github.event.comment.body }}"'
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PROMPT_INJECTION_DETECTED: true"
}

@test "compute: reports description-missing count and large-pr verdict" {
  local meta='{"changedFiles":200,"additions":10,"deletions":5,"body":"nothing useful"}'
  local diff=''
  run compute_safety_checks "$meta" "$diff"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DESCRIPTION_MISSING: 5"
  echo "$output" | grep -q "LARGE_PR: true"
}

@test "compute: degrades to a well-formed block on malformed metadata" {
  run compute_safety_checks "not json" ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CI_WEAKENING_DETECTED:"
  echo "$output" | grep -q "PROMPT_INJECTION_DETECTED:"
}
