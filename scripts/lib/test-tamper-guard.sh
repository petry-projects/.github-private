#!/usr/bin/env bash
# test-tamper-guard.sh — a fix pass must not silently rewrite an existing test to
# make its own change pass (#2013).
#
# WHAT IS WRONG WITHOUT THIS
#   On petry-projects/.github#1220 a cubic finding said, literally, "update the
#   older test to assert failure precedence so the Bats suite can pass". dev-lead
#   applied it: it rewrote an existing test (#1023 "success precedence …") into
#   "failure precedence", inverting a deliberate behavior, and the rewritten test
#   did not even match the branch. "Do not modify tests to force a pass" lived only
#   in the prompt, so nothing in the harness could stop it.
#
# THE RULE
#   A fix pass (base = the pre-pass head) is:
#     clean      it changes no existing line of a test file and adds no skip —
#                ADDING a new test is always fine;
#     justified  it does change/delete an existing test line or add a skip, AND a
#                commit in the pass carries an explicit, cited
#                `Test-Change-Justification: <why, with a reference>` trailer;
#     tampered   it does so with no justification. The harness refuses to push and
#                escalates to a human.
#   "Changed" means the test file has REMOVED lines in `git diff --numstat` (an
#   edit is a removal + an addition; a deletion is all removals), so a pure
#   addition never trips it.
#
# PURITY / TESTABILITY (ADR-0004)
#   ttg_is_test_path, ttg_touched_existing_tests, ttg_count_added_skips,
#   ttg_has_justification and ttg_classify are PURE. ttg_scan_pass is the single
#   impure gatherer (all git calls). Sourced under `set -euo pipefail`; helpers only
#   `return`, never `exit`.

set -euo pipefail

# Minimum length of the justification text — rules out a bare "so it passes".
readonly _TTG_MIN_JUSTIFICATION_CHARS=20

# Added lines that silence a test, across the frameworks the org uses.
readonly _TTG_SKIP_RE='^\+[[:space:]]*(skip([[:space:]]|$|\()|@pytest\.mark\.(skip|xfail)|pytestmark[[:space:]]*=[[:space:]]*(\[[[:space:]]*)?pytest\.mark\.(skip|xfail)|pytest\.(skip|xfail|importorskip)\(|@unittest\.skip|@Disabled|@Ignore|#\[ignore\]|t\.Skip(Now|f)?\(|(it|test|describe)\.(skip|todo)\(|x(it|describe|test)\()'

# ttg_is_test_path <path>
#   0 when <path> is a test file: under a tests?/ / __tests__/ / spec/ directory, a
#   .bats file, or a test-named file (test_*.py, *_test.*, *.test.*, *.spec.*,
#   *_spec.rb). Pure.
ttg_is_test_path() {
  local p="${1:-}"
  [[ -z "$p" ]] && return 1
  local base="${p##*/}"
  case "/$p" in
    */tests/*|*/test/*|*/__tests__/*|*/spec/*) return 0 ;;
  esac
  case "$base" in
    *.bats|test_*.py|*_test.*|*.test.*|*.spec.*|*_spec.rb) return 0 ;;
  esac
  return 1
}

# ttg_touched_existing_tests <numstat>
#   <numstat> is `git diff --numstat` output (`added\tdeleted\tpath`). Echoes, one
#   per line, every test path with removed lines (changed or deleted existing
#   lines). A binary row (`-\t-`) on a test path is reported too (fail closed).
#   Pure.
ttg_touched_existing_tests() {
  local numstat="${1:-}"
  local _added deleted path
  while IFS=$'\t' read -r _added deleted path; do
    [[ -z "${path:-}" ]] && continue
    ttg_is_test_path "$path" || continue
    if [[ "$deleted" == "-" ]] || { [[ "$deleted" =~ ^[0-9]+$ ]] && (( deleted > 0 )); }; then
      printf '%s\n' "$path"
    fi
  done <<<"$numstat"
}

# ttg_count_added_skips <unified_diff>
#   Number of ADDED lines in test files (per the `+++ b/<path>` headers) that skip
#   or disable a test. Pure.
ttg_count_added_skips() {
  local diff="${1:-}"
  local line cur="" n=0
  while IFS= read -r line; do
    if [[ "$line" == "+++ "* ]]; then
      cur="${line#+++ }"
      cur="${cur#b/}"
      continue
    fi
    [[ -z "$cur" ]] && continue
    ttg_is_test_path "$cur" || continue
    [[ "$line" =~ $_TTG_SKIP_RE ]] && n=$((n + 1))
  done <<<"$diff"
  echo "$n"
}

# ttg_has_justification <commit_messages>
#   0 when some line is `Test-Change-Justification: <text>` with at least
#   _TTG_MIN_JUSTIFICATION_CHARS of non-blank text AND a recognizable reference
#   (an issue/PR `#123`, a 7-40 hex commit SHA, or a URL) to the review, issue, or
#   commit that establishes the old test was wrong. Pure.
ttg_has_justification() {
  local msgs="${1:-}" line text
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*Test-Change-Justification:[[:space:]]*(.*)$ ]] || continue
    text="${BASH_REMATCH[1]}"
    text="${text%"${text##*[![:space:]]}"}"
    (( ${#text} >= _TTG_MIN_JUSTIFICATION_CHARS )) || continue
    [[ "$text" =~ (^|[^[:alnum:]])#[0-9]+ || "$text" =~ (^|[^[:alnum:]])[0-9a-fA-F]{7,40}($|[^[:alnum:]]) || "$text" =~ https?:// ]] && return 0
  done <<<"$msgs"
  return 1
}

# ttg_classify <touched_files_nl> <added_skips> <justified:true|false>
#   Echoes clean | justified | tampered; returns 1 only for tampered. A
#   non-numeric skip count fails closed (tampered). Pure.
ttg_classify() {
  local touched="${1:-}" skips="${2:-}" justified="${3:-false}"
  local has_touch=0
  [[ -n "$(printf '%s' "$touched" | tr -d '[:space:]')" ]] && has_touch=1
  if ! [[ "$skips" =~ ^[0-9]+$ ]]; then
    echo "tampered"
    return 1
  fi
  if (( has_touch == 0 && skips == 0 )); then
    echo "clean"
    return 0
  fi
  if [[ "$justified" == "true" ]]; then
    echo "justified"
    return 0
  fi
  echo "tampered"
  return 1
}

# ttg_scan_pass <base_sha> [head]
#   The single impure gatherer. Compares <base_sha> against the WORKING TREE (so
#   committed and not-yet-committed edits are both seen), reads the justification
#   from the commit messages in <base_sha>..<head>, and echoes the verdict on the
#   first line followed by the offending test paths (one per line). Returns 0 for
#   clean/justified, 1 for tampered, 2 (echoing `unknown`) when <base_sha> is empty
#   or does not resolve.
ttg_scan_pass() {
  local base="${1:-}" head="${2:-HEAD}"
  if [[ -z "$base" ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 2
  fi
  local numstat diff msgs touched skips justified=false verdict rc=0
  numstat=$(git diff --no-renames --numstat "$base" 2>/dev/null) || { echo "unknown"; return 2; }
  diff=$(git diff --unified=0 "$base" 2>/dev/null) || { echo "unknown"; return 2; }
  msgs=$(git log --format=%B "${base}..${head}" 2>/dev/null || true)
  touched=$(ttg_touched_existing_tests "$numstat")
  skips=$(ttg_count_added_skips "$diff")
  ttg_has_justification "$msgs" && justified=true
  verdict=$(ttg_classify "$touched" "$skips" "$justified") || rc=$?
  echo "$verdict"
  [[ -n "$touched" ]] && printf '%s\n' "$touched"
  return "$rc"
}
