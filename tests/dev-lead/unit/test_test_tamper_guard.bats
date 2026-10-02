#!/usr/bin/env bats
# Unit tests for scripts/lib/test-tamper-guard.sh (#2013).
#
# On petry-projects/.github#1220 a cubic finding said, literally, "update the
# older test to assert failure precedence so the Bats suite can pass", and
# dev-lead rewrote an existing test (#1023 "success precedence …") to match its
# own change — inverting deliberate behavior. "Don't edit tests to make them pass"
# lived only in the prompt. This guard makes it a harness check: a fix pass that
# changes or deletes an EXISTING test line, or adds a skip, without a cited
# `Test-Change-Justification:` trailer is tampered; adding a new test is clean.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/test-tamper-guard.sh"

setup() {
  # shellcheck source=scripts/lib/test-tamper-guard.sh
  source "$LIB"
}

@test "test-tamper-guard.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# ttg_is_test_path
# ---------------------------------------------------------------------------

@test "ttg_is_test_path: recognises common test file shapes" {
  local p
  for p in tests/canary_rollout.bats test/x.sh tests/dev-lead/unit/a.bats pkg/foo_test.go \
           src/__tests__/a.js src/a.test.ts src/a.spec.js tests/test_x.py app/test_y.py \
           spec/models/user_spec.rb; do
    ttg_is_test_path "$p" || { echo "not a test path: $p"; return 1; }
  done
}

@test "ttg_is_test_path: ignores non-test source files" {
  local p
  for p in scripts/canary-rollout.sh src/app.ts README.md scripts/lib/testing-helpers.md \
           docs/test-plan.md contest/a.go; do
    if ttg_is_test_path "$p"; then echo "wrongly a test path: $p"; return 1; fi
  done
}

# ---------------------------------------------------------------------------
# ttg_touched_existing_tests — test files with REMOVED lines (changed/deleted)
# ---------------------------------------------------------------------------

@test "ttg_touched_existing_tests: a pure addition to a test file is not a touch" {
  run ttg_touched_existing_tests $'12\t0\ttests/canary_rollout.bats\n3\t1\tscripts/canary-rollout.sh'
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "ttg_touched_existing_tests: inverting an existing test (removed lines) is a touch" {
  run ttg_touched_existing_tests $'4\t4\ttests/canary_rollout.bats\n3\t1\tscripts/canary-rollout.sh'
  [[ "$output" == "tests/canary_rollout.bats" ]]
}

@test "ttg_touched_existing_tests: deleting a test file is a touch" {
  run ttg_touched_existing_tests $'0\t40\ttests/old_test.py'
  [[ "$output" == "tests/old_test.py" ]]
}

@test "ttg_touched_existing_tests: a binary numstat row on a test path fails closed (touch)" {
  run ttg_touched_existing_tests $'-\t-\ttests/fixtures/blob.bats'
  [[ "$output" == "tests/fixtures/blob.bats" ]]
}

# ---------------------------------------------------------------------------
# ttg_count_added_skips — a skip added to a test file silences it
# ---------------------------------------------------------------------------

@test "ttg_count_added_skips: counts skips added in test files only" {
  local diff
  diff=$'diff --git a/tests/a.bats b/tests/a.bats\n--- a/tests/a.bats\n+++ b/tests/a.bats\n@@ -1,2 +1,3 @@\n @test "x" {\n+  skip "flaky"\n   run true\ndiff --git a/src/a.test.ts b/src/a.test.ts\n--- a/src/a.test.ts\n+++ b/src/a.test.ts\n@@ -1 +1 @@\n+it.skip("y", () => {})\ndiff --git a/scripts/run.sh b/scripts/run.sh\n--- a/scripts/run.sh\n+++ b/scripts/run.sh\n@@ -1 +1 @@\n+  skip "not a test file"'
  run ttg_count_added_skips "$diff"
  [[ "$output" == "2" ]]
}

@test "ttg_count_added_skips: no skips -> 0" {
  run ttg_count_added_skips $'+++ b/tests/a.bats\n+@test "new" {\n+  run true\n+}'
  [[ "$output" == "0" ]]
}

# ---------------------------------------------------------------------------
# ttg_has_justification — the explicit, cited justification trailer
# ---------------------------------------------------------------------------

@test "ttg_has_justification: a non-trivial trailer is a justification" {
  run ttg_has_justification $'fix: x\n\nTest-Change-Justification: test asserted the old exit code; #1023 renamed it per maintainer review r123'
  [[ "$status" -eq 0 ]]
}

@test "ttg_has_justification: missing or empty trailer is not" {
  run ttg_has_justification $'fix(reviews): address review comments [skip ci-relay]'
  [[ "$status" -eq 1 ]]
  run ttg_has_justification $'fix: x\n\nTest-Change-Justification:   '
  [[ "$status" -eq 1 ]]
  run ttg_has_justification $'fix: x\n\nTest-Change-Justification: so it passes'
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# ttg_classify — the pure verdict
# ---------------------------------------------------------------------------

@test "ttg_classify: nothing touched, no skips -> clean rc0" {
  run ttg_classify "" 0 false
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ttg_classify: existing test changed without justification -> tampered rc1" {
  run ttg_classify "tests/canary_rollout.bats" 0 false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "tampered" ]]
}

@test "ttg_classify: skip added without justification -> tampered rc1" {
  run ttg_classify "" 1 false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "tampered" ]]
}

@test "ttg_classify: existing test changed WITH justification -> justified rc0" {
  run ttg_classify "tests/canary_rollout.bats" 0 true
  [[ "$status" -eq 0 ]]
  [[ "$output" == "justified" ]]
}

@test "ttg_classify: unrecognised skip count fails closed -> tampered" {
  run ttg_classify "" "" false
  [[ "$status" -eq 1 ]]
  [[ "$output" == "tampered" ]]
}

# ---------------------------------------------------------------------------
# ttg_scan_pass — the impure gatherer over <base>..<head>
# ---------------------------------------------------------------------------

_mk_repo() {
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO_DIR"
  cd "$REPO_DIR"
  git config user.email t@t; git config user.name T
  mkdir -p tests scripts
  printf '@test "success precedence" {\n  run f\n  [ "$output" = success ]\n}\n' > tests/canary.bats
  echo 'f() { echo success; }' > scripts/canary.sh
  git add -A; git commit -q -m base
  BASE="$(git rev-parse HEAD)"
}

@test "ttg_scan_pass: code change + NEW test -> clean" {
  _mk_repo
  echo 'g() { :; }' >> scripts/canary.sh
  printf '@test "new" {\n  run g\n}\n' >> tests/canary.bats
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD
  [[ "$status" -eq 0 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "clean" ]]
}

@test "ttg_scan_pass: the #1220 shape — existing test inverted to match the code -> tampered, file named" {
  _mk_repo
  sed -i 's/success precedence/failure precedence/; s/= success/= failure/' tests/canary.bats
  echo 'f() { echo failure; }' > scripts/canary.sh
  git commit -q -am "fix(reviews): address review comments"
  run ttg_scan_pass "$BASE" HEAD
  [[ "$status" -eq 1 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "tampered" ]]
  [[ "$output" == *"tests/canary.bats"* ]]
}

@test "ttg_scan_pass: same edit with a Test-Change-Justification trailer -> justified" {
  _mk_repo
  sed -i 's/= success/= SUCCESS/' tests/canary.bats
  git commit -q -am $'fix: rename\n\nTest-Change-Justification: maintainer asked to upper-case the status token in review r4159678193'
  run ttg_scan_pass "$BASE" HEAD
  [[ "$status" -eq 0 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "justified" ]]
}

@test "ttg_scan_pass: uncommitted working-tree edits to an existing test are scanned too" {
  _mk_repo
  sed -i 's/= success/= failure/' tests/canary.bats
  run ttg_scan_pass "$BASE" HEAD
  [[ "$status" -eq 1 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "tampered" ]]
}

@test "ttg_scan_pass: unknown base fails closed -> unknown rc2" {
  _mk_repo
  run ttg_scan_pass "" HEAD
  [[ "$status" -eq 2 ]]
  [[ "$(printf '%s' "$output" | head -1)" == "unknown" ]]
}
