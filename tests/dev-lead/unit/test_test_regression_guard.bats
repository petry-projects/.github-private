#!/usr/bin/env bats
# Unit tests for scripts/lib/test-regression-guard.sh (#2013).
#
# The `15a919e` shape from petry-projects/.github#1220: a fix pass added a NEW test
# and broke an EXISTING one without editing it. The test-tamper guard is silent, the
# claim names a real in-pass commit — only running the suite against the pre-pass
# baseline catches it.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/test-regression-guard.sh"

setup() {
  # shellcheck source=scripts/lib/test-regression-guard.sh
  source "$LIB"
  unset DEV_LEAD_TEST_CMD
}

@test "test-regression-guard.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "trg_extract_failures: reads TAP not-ok and pytest FAILED lines, ignores TODO/skip" {
  run trg_extract_failures <<'OUT'
1..4
ok 1 fine
not ok 2 existing behaviour
not ok 3 later # skip not yet
not ok 4 wip # TODO later
FAILED tests/test_a.py::test_b - assert 1 == 2
OUT
  [[ "$status" -eq 0 ]]
  [[ "$output" == $'existing behaviour\ntests/test_a.py::test_b' ]]
}

@test "trg_classify: a passing suite is green" {
  run trg_classify false "" "" 0 ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == "green" ]]
}

@test "trg_classify: the 15a919e shape — an existing test newly fails — is a regression" {
  run trg_classify true 0 "" 1 "existing behaviour"
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "regression" ]]
  [[ "${lines[1]}" == "existing behaviour" ]]
}

@test "trg_classify: a failure that already existed on the pre-pass head does not block" {
  run trg_classify true 1 "old failure" 1 "old failure"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "preexisting" ]]
}

@test "trg_classify: one old failure plus one new failure is a regression naming only the new one" {
  run trg_classify true 1 "old failure" 1 $'new failure\nold failure'
  [[ "$status" -eq 1 ]]
  [[ "${lines[1]}" == "new failure" ]]
  [[ "${#lines[@]}" -eq 2 ]]
}

@test "trg_classify: red with no readable names is a regression only if the baseline was green" {
  run trg_classify true 0 "" 2 ""
  [[ "$status" -eq 1 ]]
  run trg_classify true 1 "" 2 ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == "unattributed" ]]
}

@test "trg_classify: red with no baseline run is unbaselined, a timeout is timeout, never green" {
  run trg_classify false "" "" 1 "x"
  [[ "$output" == "unbaselined" ]]
  run trg_classify false "" "" 124 ""
  [[ "$output" == "timeout" ]]
}

@test "trg_classify: an unreadable head status fails closed" {
  run trg_classify true 0 "" "" ""
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "regression" ]]
}

@test "trg_summary_line: not-run never implies green" {
  run trg_summary_line not-run ""
  [[ "$output" == *"NOT RUN"* ]]
  [[ "$output" == *"NOT verified green"* ]]
  run trg_summary_line green "make test"
  [[ "$output" == *"PASSED"* ]]
}

@test "trg_discover_cmd: DEV_LEAD_TEST_CMD wins; an empty repo has no command" {
  local d="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$d"
  run trg_discover_cmd "$d"
  [[ "$status" -eq 1 ]]
  DEV_LEAD_TEST_CMD="./run-tests" run trg_discover_cmd "$d"
  [[ "$output" == "./run-tests" ]]
}

@test "trg_discover_cmd: finds make test and npm test" {
  local d="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$d"
  printf 'test:\n\ttrue\n' > "$d/Makefile"
  run trg_discover_cmd "$d"
  [[ "$output" == "make test" ]]
  printf '{"scripts":{"test":"jest"}}\n' > "$d/package.json"
  run trg_discover_cmd "$d"
  [[ "$output" == "npm test" ]]
}

# --- trg_scan_pass against a real repo: the 15a919e fixture -------------------

_mk_repo() {
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  printf 'ok\n' > "$R/state.txt"
  # A tiny TAP "suite": one test per line of checks.sh.
  cat > "$R/suite.sh" <<'SH'
#!/usr/bin/env bash
n=0; rc=0
t() { n=$((n+1)); if eval "$2"; then echo "ok $n $1"; else echo "not ok $n $1"; rc=1; fi; }
t "existing behaviour" '[ "$(cat state.txt)" = ok ]'
[ -f new_test_marker ] && t "new test" 'true'
exit $rc
SH
  chmod +x "$R/suite.sh"
  git -C "$R" add .
  git -C "$R" -c user.email=t@t -c user.name=T commit -q -m init
  BASE="$(git -C "$R" rev-parse HEAD)"
  export DEV_LEAD_TEST_CMD="./suite.sh"
}

@test "trg_scan_pass: 15a919e shape — new test added, existing test broken but untouched — is refused" {
  _mk_repo
  cd "$R"
  : > new_test_marker           # adds a new (passing) test
  printf 'broken\n' > state.txt # breaks the existing test without editing it
  git add -A
  git -c user.email=t@t -c user.name=T commit -q -m fix
  run trg_scan_pass "$BASE"
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == $'regression\t./suite.sh' ]]
  [[ "${lines[1]}" == "existing behaviour" ]]
  # the checkout is restored to the pass's result
  [[ "$(cat state.txt)" == "broken" ]]
}

@test "trg_scan_pass: a green result is green, and an already-red baseline does not block" {
  _mk_repo
  cd "$R"
  : > new_test_marker
  git add -A
  git -c user.email=t@t -c user.name=T commit -q -m fix
  run trg_scan_pass "$BASE"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == $'green\t./suite.sh' ]]

  # Base already red for the same test: break state.txt in the BASE commit.
  git checkout -q "$BASE"
  printf 'broken\n' > state.txt
  git -c user.email=t@t -c user.name=T commit -q -am redbase
  RED="$(git rev-parse HEAD)"
  : > new_test_marker
  git add -A
  git -c user.email=t@t -c user.name=T commit -q -m fix2
  run trg_scan_pass "$RED"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == $'preexisting\t./suite.sh' ]]
}

@test "trg_scan_pass: no test command means not-run, status 0" {
  local d="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$d"
  cd "$d"
  git init -q
  unset DEV_LEAD_TEST_CMD
  run trg_scan_pass ""
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == $'not-run\t' ]]
}

@test "trg_extract_failures: strips the bats timing suffix so the same test compares equal" {
  run trg_extract_failures <<'OUT'
not ok 1 existing behaviour in 123ms
OUT
  [[ "$output" == "existing behaviour" ]]
}

@test "trg_extract_failures: reads jest FAIL and go --- FAIL lines" {
  run trg_extract_failures <<'OUT'
FAIL src/a.test.js
--- FAIL: TestThing (0.00s)
OUT
  [[ "${lines[0]}" == "TestThing" ]]
  [[ "${lines[1]}" == "src/a.test.js" ]]
  [[ "${#lines[@]}" -eq 2 ]]
}

@test "trg_classify: a timed-out baseline is unbaselined, not preexisting" {
  run trg_classify true 124 "x" 1 "x"
  [[ "$output" == "unbaselined" ]]
}

@test "_trg_run: write-capable credentials are not visible to the suite" {
  GH_TOKEN=secret GITHUB_TOKEN=secret run _trg_run 'echo "[${GH_TOKEN:-}${GITHUB_TOKEN:-}]"'
  [[ "$output" == "[]" ]]
}

@test "trg_scan_pass: an unbaselinable base (unknown sha) is unbaselined and not blocked" {
  d="$BATS_TEST_TMPDIR/repo"; mkdir -p "$d"; cd "$d"
  git init -q; git -c user.email=t@t -c user.name=T commit -q --allow-empty -m i
  DEV_LEAD_TEST_CMD="echo 'not ok 1 broken'; exit 1" run trg_scan_pass "0000000000000000000000000000000000000000"
  [[ "${lines[0]}" == $'unbaselined\t'* ]]
  [[ "$status" -eq 0 ]]
}

@test "dev-lead-reusable.yml installs bats before the first Run step and maps DEV_LEAD_TEST_CMD from vars (#2013)" {
  local wf="$BATS_TEST_DIRNAME/../../../.github/workflows/dev-lead-reusable.yml"
  local inst run
  inst=$(grep -n -- '- name: Install bats' "$wf" | head -1 | cut -d: -f1)
  run=$(grep -n -- '- name: Run ' "$wf" | head -1 | cut -d: -f1)
  [[ -n "$inst" && -n "$run" && "$inst" -lt "$run" ]]
  grep -q 'apt-get install -y bats' "$wf"
  grep -qF 'DEV_LEAD_TEST_CMD: ${{ vars.DEV_LEAD_TEST_CMD }}' "$wf"
}
