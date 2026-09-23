#!/usr/bin/env bats
# Tests for maintainer-resolve-comment.sh (issue #1910, epic #1894 AC #4).
#
# AC #4 gap: the ONLY thing that ever minimizes an undispositioned PR issue
# comment RESOLVED is dev-lead. On a PR where dev-lead is suppressed,
# rate-limited, cancelled, or never dispatched, a maintainer's own comment stays
# undispositioned forever and no approval can stand (maintainer-comment-gate.sh
# blocks). This script gives a maintainer a dev-lead-INDEPENDENT path to satisfy
# that gate against THEIR OWN comment: minimize it with GraphQL minimizeComment
# classifier RESOLVED — the exact signal the gate already honours. It must NOT
# weaken the RESOLVED-minimized requirement, and must only ever act on the
# invoking user's own comment (fail closed otherwise).

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  MRC="$SCRIPT_DIR/maintainer-resolve-comment.sh"
  GATE="$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
}

teardown() {
  unset SCRIPT_DIR
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "MRC: script exists and is executable" {
  [ -x "$MRC" ]
}

@test "MRC: script has correct shebang" {
  head -1 "$MRC" | grep -q "^#!/usr/bin/env bash"
}

@test "MRC: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$MRC"
}

@test "MRC: BASH_SOURCE guard prevents source-time execution of main" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$MRC"
}

@test "MRC: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$MRC"
}

# AC #2 — the maintainer path is documented via --help.
@test "AC2: --help documents the RESOLVED-minimize requirement" {
  run bash "$MRC" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "RESOLVED"
  echo "$output" | grep -qi "minimiz"
  echo "$output" | grep -qi "own comment"
}

# ────────────────────────────────────────────────────────────────────
# PURE-HELPER TESTS
# ────────────────────────────────────────────────────────────────────

# AC #2 — the requirement is not weakened: the mutation hardcodes classifier RESOLVED.
@test "AC2: minimize mutation uses classifier RESOLVED and nothing else" {
  run bash -c "source '$MRC'; mrc_minimize_mutation"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "minimizeComment"
  echo "$output" | grep -q "classifier:RESOLVED"
  # It must NOT offer any weaker classifier (OUTDATED, RESOLVED must be the only one).
  ! echo "$output" | grep -q "OUTDATED"
}

@test "ref-kind: a node id (IC_...) is recognised as a node ref" {
  run bash -c "source '$MRC'; mrc_ref_kind 'IC_kwDOAbc123'"
  [ "$status" -eq 0 ]
  [ "$output" = "node" ]
}

@test "ref-kind: a PR comment URL is recognised as a url ref" {
  run bash -c "source '$MRC'; mrc_ref_kind 'https://github.com/petry-projects/.github-private/pull/42#issuecomment-999'"
  [ "$status" -eq 0 ]
  [ "$output" = "url" ]
}

@test "ref-kind: garbage input is invalid (fail closed)" {
  run bash -c "source '$MRC'; mrc_ref_kind 'not-a-ref'"
  [ "$status" -ne 0 ]
}

@test "url-parse: database id extracted from #issuecomment anchor" {
  run bash -c "source '$MRC'; mrc_comment_dbid_from_url 'https://github.com/o/r/pull/42#issuecomment-987654'"
  [ "$status" -eq 0 ]
  [ "$output" = "987654" ]
}

@test "url-parse: owner/repo extracted from URL" {
  run bash -c "source '$MRC'; mrc_repo_from_url 'https://github.com/petry-projects/.github-private/pull/42#issuecomment-1'"
  [ "$status" -eq 0 ]
  [ "$output" = "petry-projects/.github-private" ]
}

# AC #1 / self-scope — only the invoking user's OWN comment may be resolved here.
@test "authz: invoking user resolving their own comment is authorized" {
  run bash -c "source '$MRC'; mrc_authorize_self 'a-maintainer' 'a-maintainer'"
  [ "$status" -eq 0 ]
}

@test "authz: resolving someone else's comment is rejected (fail closed)" {
  run bash -c "source '$MRC'; mrc_authorize_self 'a-maintainer' 'someone-else'"
  [ "$status" -ne 0 ]
}

@test "authz: empty author or empty viewer is rejected (fail closed)" {
  run bash -c "source '$MRC'; mrc_authorize_self '' 'a-maintainer'"
  [ "$status" -ne 0 ]
  run bash -c "source '$MRC'; mrc_authorize_self 'a-maintainer' ''"
  [ "$status" -ne 0 ]
}

# Idempotency — an already-RESOLVED-minimized comment needs no action.
@test "idempotency: already-RESOLVED-minimized comment is detected" {
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'true' 'resolved'"
  [ "$status" -eq 0 ]
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'true' 'RESOLVED'"
  [ "$status" -eq 0 ]
}

@test "idempotency: a non-minimized or non-RESOLVED comment is not treated as resolved" {
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'false' ''"
  [ "$status" -ne 0 ]
  run bash -c "source '$MRC'; mrc_is_resolved_minimized 'true' 'outdated'"
  [ "$status" -ne 0 ]
}

# ────────────────────────────────────────────────────────────────────
# ROUND-TRIP: the signal this script produces is EXACTLY what the gate honours
# ────────────────────────────────────────────────────────────────────

# A comment this script has resolved (minimized RESOLVED) must clear the
# maintainer-comment gate — proving the maintainer path satisfies the gate
# without dev-lead executing, and does not invent a new/weaker signal.
@test "round-trip: a RESOLVED-minimized maintainer comment clears the gate" {
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"Please double-check the null path.","isMinimized":true,"minimizedReason":"resolved"}]}'
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" donpetry-bot" _ "$json"
  [ "$status" -eq 0 ]
}

# Control: before this script runs, the same comment (not minimized) blocks —
# so the RESOLVED-minimize is what flips the verdict, nothing else.
@test "round-trip: the same comment un-minimized still blocks the gate" {
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"Please double-check the null path.","isMinimized":false,"minimizedReason":""}]}'
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" donpetry-bot" _ "$json"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# ENTRYPOINT (main) — no-network fail-closed paths
# ────────────────────────────────────────────────────────────────────

@test "main: no argument prints usage and exits 2" {
  run bash "$MRC"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "usage"
}

@test "main: an unrecognised comment reference fails closed (exit 2, no minimize)" {
  run bash "$MRC" "totally-not-a-comment-ref"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "unrecognised comment reference"
}
