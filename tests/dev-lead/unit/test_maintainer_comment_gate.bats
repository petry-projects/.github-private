#!/usr/bin/env bats
# Tests for maintainer-comment-gate.sh (issues #1290, #1813)
#
# #1813 redesign: "addressed" is no longer a timestamp proxy against the head
# push (pushedDate is always null, and a push says nothing about whether a
# comment's finding was researched, answered, and resolved). Instead, a PR issue
# comment is "addressed" only once it carries a VERIFIED DISPOSITION — surfaced
# server-side as the comment being minimized with classifier RESOLVED (the
# harness minimizes it after verifying dev-lead's disposition reply). The gate
# withholds pr-review's approval while ANY non-agent issue comment lacks that
# signal — bots and humans alike, with the ONLY exclusion being our own account
# and our own agent-marked disposition/ack/note replies. It FAILS CLOSED: an
# undeterminable snapshot blocks and is reported distinctly (never disguised as
# the legitimate hold).
#
# check_maintainer_comments <pr_snapshot_json> [bot_user]
#   0 = every non-agent issue comment is minimized RESOLVED (or none exist)
#   1 = at least one non-agent issue comment lacks a verified disposition → block
#   2 = snapshot could not be evaluated (malformed) → fail closed → block

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  GATE="$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
}

teardown() {
  unset SCRIPT_DIR
}

_run_check() {
  # _run_check <json> [bot_user]
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" \"\$2\"" _ "$1" "${2:-donpetry-bot}"
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "Maintainer gate: script is executable" {
  [ -x "$GATE" ]
}

@test "Maintainer gate: script has correct shebang" {
  head -1 "$GATE" | grep -q "^#!/usr/bin/env bash"
}

@test "Maintainer gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$GATE"
}

@test "Maintainer gate: defines check_maintainer_comments function" {
  grep -q "check_maintainer_comments()" "$GATE"
}

@test "Maintainer gate: BASH_SOURCE guard prevents source-time execution" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$GATE"
}

@test "Maintainer gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$GATE"
}

# AC1 — no pushedDate dependency anywhere in the gate.
@test "AC1: gate reads no pushedDate field" {
  ! grep -q "pushedDate" "$GATE"
}

# AC1 — the head-time helper (still used by the review-thread gate) uses committer.date.
@test "AC1: head-time helper uses committer.date, not pushedDate" {
  grep -q 'commit{committer{date}}' "$GATE"
  ! grep -q "pushedDate" "$GATE"
}

# ────────────────────────────────────────────────────────────────────
# RUNTIME BEHAVIOR TESTS
# ────────────────────────────────────────────────────────────────────

@test "Runtime: no comments → 0 (nothing to block on)" {
  _run_check '{"comments":[],"reviews":[]}'
  [ "$status" -eq 0 ]
}

@test "Runtime: null comments field is treated as no findings → 0" {
  _run_check '{"reviews":[]}'
  [ "$status" -eq 0 ]
}

# AC9(b): an undispositioned codeant-ai comment blocks.
@test "AC9b: undispositioned codeant-ai comment → 1 (block)" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"## CodeAnt AI — Review Status","createdAt":"2026-09-13T04:23:06Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(b): an undispositioned qodo-code-review comment blocks.
@test "AC9b: undispositioned qodo-code-review comment → 1 (block)" {
  local json='{"comments":[{"author":{"login":"qodo-code-review"},"body":"<!-- qodo:billing-blocked --> Qodo reviews are paused because your trial has ended.","createdAt":"2026-09-13T04:23:06Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(b): an undispositioned auto-rebase-conflict comment (authored by don-petry,
# NOT one of our agent markers) blocks — a conflict report is a finding.
@test "AC9b: undispositioned auto-rebase-conflict comment → 1 (block)" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- auto-rebase-conflict:56d8ccc7 --> Auto-rebase failed — merge conflict.","createdAt":"2026-09-13T04:28:56Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(a): pushedDate is irrelevant; every comment minimized RESOLVED → passes.
@test "AC9a: all non-agent comments minimized RESOLVED → 0 (clear)" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Review Status","createdAt":"2026-09-13T04:23:06Z","isMinimized":true,"minimizedReason":"resolved"},{"author":{"login":"qodo-code-review"},"body":"Trial ended.","createdAt":"2026-09-13T04:23:06Z","isMinimized":true,"minimizedReason":"resolved"}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

@test "Runtime: mix of resolved + one unresolved non-agent comment → 1 (block)" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Status","createdAt":"2026-09-13T04:23:06Z","isMinimized":true,"minimizedReason":"resolved"},{"author":{"login":"a-maintainer"},"body":"Please fix this.","createdAt":"2026-09-13T05:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

@test "Runtime: comment minimized for a NON-resolved reason (outdated) still blocks → 1" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Status","createdAt":"2026-09-13T04:23:06Z","isMinimized":true,"minimizedReason":"outdated"}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC9(e): our own disposition/ack reply never blocks the gate (loop safety).
@test "AC9e: our dev-lead comment-disposition reply is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"Researched and answered.\n<!-- dev-lead:comment-disposition id=123 disposition=answered -->","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

@test "Runtime: our own pr-review agent-marked comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"donpetry-bot"},"body":"<!-- pr-review-agent v1 sha=abc123 --> Review posted.","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

@test "Runtime: bot_user's own plain comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"donpetry-bot"},"body":"CI is still running.","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json" 'donpetry-bot'
  [ "$status" -eq 0 ]
}

@test "Runtime: dependency-advisory comment (posted as don-petry, marked) is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- dependency-advisory -->\n## Dependency Advisory\nNo issues.","createdAt":"2026-09-13T06:00:00Z","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
}

@test "Runtime: malformed snapshot → 2 (fail closed)" {
  _run_check 'not json at all {'
  [ "$status" -eq 2 ]
}

# ────────────────────────────────────────────────────────────────────
# INTEGRATION / WIRING TESTS (review-one-pr.sh)
# ────────────────────────────────────────────────────────────────────

@test "Wiring: review-one-pr.sh sources the maintainer-comment gate" {
  grep -q "source.*maintainer-comment-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "check_maintainer_comments" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "AC8: undispositioned hold and undeterminable error use distinct reasons" {
  # The legitimate hold reason must NOT be reused for the undeterminable/error state.
  grep -q "undispositioned-pr-comment" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "maintainer-comment-gate-error" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: FORCE_REVIEW bypasses the maintainer-comment gate" {
  grep -B8 "check_maintainer_comments" "$SCRIPT_DIR/review-one-pr.sh" | grep -q "FORCE_REVIEW"
}

@test "Manifest: maintainer-comment gate registered under pr-review.yml surface" {
  grep -q "scripts/lib/maintainer-comment-gate.sh" "$SCRIPT_DIR/lib/consumer-manifest.json"
}
