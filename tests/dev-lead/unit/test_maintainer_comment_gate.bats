#!/usr/bin/env bats
# Tests for maintainer-comment-gate.sh (issue #1290)
#
# A maintainer finding posted as a PR *issue comment* (gh pr comment / the
# GitHub main comment box) creates no review thread, so it neither blocks merge
# nor reaches dev-lead. This gate withholds pr-review's automated approval while
# the latest maintainer issue comment postdates the last push, and FAILS CLOSED:
# an inability to confirm the comment was addressed must block, never read as
# "no findings".
#
# check_maintainer_comments <pr_snapshot_json> <head_committer_date_iso> [bot_user]
#   0 = no unaddressed maintainer comment (none, or latest is at/older than head push)
#   1 = latest maintainer comment postdates the last push (unaddressed) → block
#   2 = snapshot could not be evaluated (malformed) → fail closed → block

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  GATE="$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
}

teardown() {
  unset SCRIPT_DIR
}

_run_check() {
  # _run_check <json> <head_date_iso> [bot_user]
  run bash -c "source '$GATE'; check_maintainer_comments \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "${3:-donpetry-bot}"
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

# ────────────────────────────────────────────────────────────────────
# RUNTIME BEHAVIOR TESTS
# ────────────────────────────────────────────────────────────────────

@test "Runtime: no comments → 0 (nothing to block on)" {
  _run_check '{"comments":[],"reviews":[]}' '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: maintainer comment postdates last push → 1 (block)" {
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"This fails open — an API error emits no labels and returns success.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 1 ]
}

@test "Runtime: push landed after the maintainer comment → 0 (addressed)" {
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"Please fix the fail-open.","createdAt":"2026-06-07T10:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T12:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: empty head date with a maintainer comment → 1 (fail closed)" {
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"Blocking finding.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" ''
  [ "$status" -eq 1 ]
}

@test "Runtime: empty head date and NO maintainer comment → 0 (nothing to block)" {
  _run_check '{"comments":[],"reviews":[]}' ''
  [ "$status" -eq 0 ]
}

@test "Runtime: malformed snapshot → 2 (fail closed)" {
  _run_check 'not json at all {' '2026-06-07T10:00:00Z'
  [ "$status" -eq 2 ]
}

@test "Runtime: our own pr-review agent-marked comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"donpetry-bot"},"body":"<!-- pr-review-agent v1 sha=abc123 --> Review posted.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: dev-lead-marked comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- dev-lead --> Rebased onto main.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: persona-marked advisory comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"donpetry-bot"},"body":"<!-- persona:pr-review --> Advisory guidance.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: dependency-advisory comment (posted as don-petry) is ignored → 0" {
  # dependency-advisory.yml posts as the human owner don-petry with a marker; it
  # must not be mistaken for a maintainer finding and self-block auto-merge.
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- dependency-advisory -->\n## Dependency Advisory\nNo issues.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: dev-lead rate-limit-ack (posted as don-petry) is ignored → 0" {
  # The rate-limit ack in dev-lead-fix-reviews.sh is authored by don-petry; its
  # <!-- dev-lead rate-limit-ack --> marker must exclude it from the gate.
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- dev-lead rate-limit-ack -->\n> [!NOTE]\n> I received your request but all AI engines are currently rate-limited.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: advisory bot issue comment is ignored → 0 (handled by advisory gate)" {
  local json='{"comments":[{"author":{"login":"gemini-code-assist"},"body":"Some advisory note.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: coderabbitai issue comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"coderabbitai"},"body":"Actionable comment.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: bot_user's own plain comment is ignored → 0" {
  local json='{"comments":[{"author":{"login":"donpetry-bot"},"body":"CI is still running.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z' 'donpetry-bot'
  [ "$status" -eq 0 ]
}

@test "Runtime: old addressed finding + newer bot comment → 0" {
  # Maintainer finding predates the last push (addressed); a later advisory bot
  # comment must not re-arm the gate.
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"Old finding.","createdAt":"2026-06-07T08:00:00Z"},{"author":{"login":"sonarqubecloud"},"body":"Quality gate passed.","createdAt":"2026-06-07T13:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Runtime: two maintainer comments, latest postdates push → 1 (block)" {
  local json='{"comments":[{"author":{"login":"a-maintainer"},"body":"First note.","createdAt":"2026-06-07T08:00:00Z"},{"author":{"login":"another-maintainer"},"body":"Second finding after the fix push.","createdAt":"2026-06-07T12:00:00Z"}],"reviews":[]}'
  _run_check "$json" '2026-06-07T10:00:00Z'
  [ "$status" -eq 1 ]
}

@test "Runtime: null comments field is treated as no findings → 0" {
  _run_check '{"reviews":[]}' '2026-06-07T10:00:00Z'
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# INTEGRATION / WIRING TESTS (review-one-pr.sh)
# ────────────────────────────────────────────────────────────────────

@test "Wiring: review-one-pr.sh sources the maintainer-comment gate" {
  grep -q "source.*maintainer-comment-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "check_maintainer_comments" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: review-one-pr.sh skips on rc=1 with unaddressed-maintainer-comment reason" {
  grep -q "unaddressed-maintainer-comment" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: review-one-pr.sh fails closed on rc=2" {
  grep -q "maintainer-comment-gate-error" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: FORCE_REVIEW bypasses the maintainer-comment gate" {
  # The gate block must be guarded by a FORCE_REVIEW check like the other gates.
  grep -B8 "check_maintainer_comments" "$SCRIPT_DIR/review-one-pr.sh" | grep -q "FORCE_REVIEW"
}

@test "Manifest: maintainer-comment gate registered under pr-review.yml surface" {
  grep -q "scripts/lib/maintainer-comment-gate.sh" "$SCRIPT_DIR/lib/consumer-manifest.json"
}
