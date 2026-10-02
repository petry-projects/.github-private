#!/usr/bin/env bash
# test-regression-guard.sh — a fix pass may not push with the suite newly red (#2013).
#
# WHAT IS WRONG WITHOUT THIS
#   On petry-projects/.github#1220 the `15a919e` fix added a NEW test and broke an
#   EXISTING one without editing it. The test-tamper guard is silent about that (no
#   existing test line changed) and the claim names a real in-pass commit, so every
#   other check passed. Only running the suite against the pre-pass baseline sees it.
#
# THE RULE
#   Run the repo's test command on the pass's result. Then:
#     green        the suite passes;
#     preexisting  it fails, but every failing test also fails on the pre-pass head;
#     regression   a test fails that did not fail on the pre-pass head (a previously
#                  passing test broke, or a new test fails). The harness refuses to
#                  push and escalates to a human;
#     unattributed it fails on both heads and no failing test names could be read,
#                  so the failure cannot be pinned on the pass (reported, not blocked);
#     unbaselined  it fails and the pre-pass head could not be run (not blocked, said
#                  loudly);
#     timeout      the suite did not finish (not blocked, said loudly);
#     not-run      no test command could be determined — the suite was NOT run, and
#                  the run summary says so. Never report or imply green.
#
# HOW THE COMMAND IS FOUND (no workflow_call input — channel-pin sequencing)
#   1. $DEV_LEAD_TEST_CMD, 2. `npm test` (package.json with a test script),
#   3. `make test` (Makefile with a test target), 4. `pytest` (pytest config or tests
#   dir with test_*.py), 5. `bats --recursive tests` when bats and *.bats are present.
#
# PURITY / TESTABILITY (ADR-0004)
#   trg_extract_failures, trg_classify and trg_summary_line are PURE. trg_discover_cmd
#   only reads the working tree; trg_scan_pass is the single impure gatherer (runs the
#   suite, and checks out the pre-pass head to baseline a red suite). Sourced under
#   `set -euo pipefail`; helpers only `return`, never `exit`.

set -euo pipefail

# trg_extract_failures — failing test names from suite output on stdin, sorted and
# unique. Reads TAP (`not ok 3 name`, as bats/prove print) and pytest short summaries
# (`FAILED path::name - reason`). A `# TODO`/`# skip` TAP line is not a failure. Pure.
trg_extract_failures() {
  local line name
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^not\ ok\ [0-9]+[[:space:]]+(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      [[ "$name" =~ \#[[:space:]]*(TODO|skip|SKIP) ]] && continue
      printf '%s\n' "$name"
    elif [[ "$line" =~ ^FAILED\ ([^[:space:]]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done | sort -u
}

# trg_classify <base_ran:true|false> <base_rc> <base_failures_nl> <head_rc> <head_failures_nl>
#   Echoes the verdict (above) on the first line, then the offending test names for a
#   regression, one per line. Returns 1 only for `regression`. A non-numeric head rc
#   fails closed (regression). Pure.
trg_classify() {
  local base_ran="${1:-false}" base_rc="${2:-}" base_fail="${3:-}" head_rc="${4:-}" head_fail="${5:-}"
  if ! [[ "$head_rc" =~ ^[0-9]+$ ]]; then
    echo "regression"
    echo "(suite result unreadable)"
    return 1
  fi
  if (( head_rc == 0 )); then
    echo "green"
    return 0
  fi
  if (( head_rc == 124 )); then
    echo "timeout"
    return 0
  fi
  if [[ "$base_ran" != "true" ]] || ! [[ "$base_rc" =~ ^[0-9]+$ ]]; then
    echo "unbaselined"
    return 0
  fi
  local new="" t
  if [[ -n "$(printf '%s' "$head_fail" | tr -d '[:space:]')" ]]; then
    while IFS= read -r t; do
      [[ -z "$t" ]] && continue
      printf '%s\n' "$base_fail" | grep -qxF -- "$t" || new+="${t}"$'\n'
    done <<<"$head_fail"
    if [[ -n "$new" ]]; then
      echo "regression"
      printf '%s' "$new"
      return 1
    fi
    echo "preexisting"
    return 0
  fi
  # Red on the head, no names to compare.
  if (( base_rc == 0 )); then
    echo "regression"
    echo "(suite exited ${head_rc}; it passed on the pre-pass head)"
    return 1
  fi
  echo "unattributed"
  return 0
}

# trg_summary_line <verdict> [cmd] — the one line for the run summary. Never implies
# green unless the suite really passed. Pure.
trg_summary_line() {
  local verdict="${1:-}" cmd="${2:-}"
  case "$verdict" in
    green)        echo "Test suite: PASSED on the pass's result (\`${cmd}\`)." ;;
    preexisting)  echo "Test suite: red, but every failing test already failed on the pre-pass head (\`${cmd}\`) — not caused by this pass." ;;
    unattributed) echo "Test suite: red on both the pre-pass head and the result (\`${cmd}\`); no test names could be read, so the failure could not be attributed. NOT verified green." ;;
    unbaselined)  echo "Test suite: red (\`${cmd}\`) and the pre-pass head could not be run for comparison. NOT verified green." ;;
    timeout)      echo "Test suite: did not finish within the time limit (\`${cmd}\`). NOT verified green." ;;
    regression)   echo "Test suite: REGRESSION — a test that passed on the pre-pass head fails on the result (\`${cmd}\`). Push refused." ;;
    not-run|*)    echo "Test suite: NOT RUN — no test command could be determined (set DEV_LEAD_TEST_CMD). The pass is NOT verified green." ;;
  esac
}

# trg_discover_cmd [dir] — echoes the test command for <dir> (default .), or returns 1
# when none can be determined.
trg_discover_cmd() {
  local dir="${1:-.}"
  if [[ -n "${DEV_LEAD_TEST_CMD:-}" ]]; then
    echo "$DEV_LEAD_TEST_CMD"
    return 0
  fi
  if [[ -f "$dir/package.json" ]] && grep -q '"test"[[:space:]]*:' "$dir/package.json" 2>/dev/null; then
    echo "npm test"
    return 0
  fi
  if [[ -f "$dir/Makefile" ]] && grep -qE '^test[[:space:]]*:' "$dir/Makefile" 2>/dev/null; then
    echo "make test"
    return 0
  fi
  if [[ -f "$dir/pytest.ini" || -f "$dir/tox.ini" || -f "$dir/pyproject.toml" || -f "$dir/setup.cfg" ]] \
     && command -v pytest >/dev/null 2>&1 \
     && [[ -n "$(find "$dir" -path "$dir/.git" -prune -o -name 'test_*.py' -print -quit 2>/dev/null)" ]]; then
    echo "pytest -q"
    return 0
  fi
  if [[ -d "$dir/tests" ]] && command -v bats >/dev/null 2>&1 \
     && [[ -n "$(find "$dir/tests" -name '*.bats' -print -quit 2>/dev/null)" ]]; then
    echo "bats --recursive tests"
    return 0
  fi
  return 1
}

# _trg_run <cmd> — run the suite in the current directory with a time limit; combined
# output on stdout, the exit status as the return code.
_trg_run() {
  local cmd="$1" limit="${DEV_LEAD_TEST_TIMEOUT:-1500}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$limit" bash -c "$cmd" 2>&1
  else
    bash -c "$cmd" 2>&1
  fi
}

# trg_scan_pass <base_sha>
#   The single impure gatherer. Runs the suite on the CURRENT checkout (the pass's
#   result). Only when it is red, checks out <base_sha> (detached), runs it again, and
#   restores the checkout. Echoes `<verdict>\t<cmd>` on the first line, then the
#   offending tests. Returns 1 only for `regression`.
trg_scan_pass() {
  local base="${1:-}" cmd out head_rc=0 head_fail base_out base_rc="" base_fail="" base_ran=false
  if ! cmd=$(trg_discover_cmd .); then
    printf 'not-run\t\n'
    return 0
  fi
  out=$(_trg_run "$cmd") || head_rc=$?
  head_fail=$(printf '%s\n' "$out" | trg_extract_failures)
  if (( head_rc != 0 && head_rc != 124 )) && [[ -n "$base" ]] && git cat-file -e "${base}^{commit}" 2>/dev/null; then
    local orig
    orig=$(git symbolic-ref -q --short HEAD 2>/dev/null || git rev-parse HEAD)
    if git checkout -q --detach "$base" 2>/dev/null; then
      base_rc=0
      base_out=$(_trg_run "$cmd") || base_rc=$?
      base_fail=$(printf '%s\n' "$base_out" | trg_extract_failures)
      base_ran=true
      git checkout -q "$orig" 2>/dev/null || { echo "::error::test-regression guard could not restore ${orig}" >&2; printf 'regression\t%s\n(checkout not restored)\n' "$cmd"; return 1; }
    fi
  fi
  local verdict_out rc=0
  verdict_out=$(trg_classify "$base_ran" "$base_rc" "$base_fail" "$head_rc" "$head_fail") || rc=$?
  printf '%s\t%s\n' "$(printf '%s\n' "$verdict_out" | head -1)" "$cmd"
  printf '%s\n' "$verdict_out" | sed '1d'
  return "$rc"
}
