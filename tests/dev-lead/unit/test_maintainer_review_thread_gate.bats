#!/usr/bin/env bats
# Tests for maintainer-review-thread-gate.sh (issue #1415)
#
# The review-path sibling of the #1290 issue-comment gate. On a dev-lead-authored
# PR, dev-lead acts as the owner `don-petry` (AGENTS.md "Agent identity") — the
# *same* account a human maintainer uses — so login alone cannot separate a
# maintainer's review thread from one of ours. This gate keys on the **automation
# marker** in a thread's originating comment instead:
#
#   review_thread_is_agent_authored <originating_comment_body>
#     0 = carries one of our markers → ours → the agent may resolve it
#     1 = marker-less (or undeterminable) → a maintainer finding → the agent
#         must NOT resolve it (fail-closed)
#
#   check_maintainer_review_threads <threads_json> <head_committer_date_iso> [bot_user]
#     0 = no unaddressed maintainer review thread (none, resolved, or a fix was
#         pushed at/after the finding)
#     1 = an unaddressed maintainer review thread postdates the last push
#         (or authorship/created/push-time is undeterminable) → withhold approval
#     2 = the threads snapshot could not be evaluated (malformed) → fail closed

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  GATE="$SCRIPT_DIR/lib/maintainer-review-thread-gate.sh"
}

teardown() {
  unset SCRIPT_DIR
}

_run_check() {
  # _run_check <threads_json> <head_date_iso> [bot_user]
  run bash -c "source '$GATE'; check_maintainer_review_threads \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "${3:-donpetry-bot}"
}

_run_classify() {
  # _run_classify <originating_comment_body>
  run bash -c "source '$GATE'; review_thread_is_agent_authored \"\$1\"" _ "$1"
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "Review-thread gate: script is executable" {
  [ -x "$GATE" ]
}

@test "Review-thread gate: script has correct shebang" {
  (head -n 1 "$GATE" || true) | grep -q "^#!/usr/bin/env bash"
}

@test "Review-thread gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$GATE"
}

@test "Review-thread gate: defines check_maintainer_review_threads function" {
  grep -q "check_maintainer_review_threads()" "$GATE"
}

@test "Review-thread gate: defines review_thread_is_agent_authored function" {
  grep -q "review_thread_is_agent_authored()" "$GATE"
}

@test "Review-thread gate: defines review_thread_login_is_excluded_bot function" {
  grep -q "review_thread_login_is_excluded_bot()" "$GATE"
}

@test "Review-thread gate: BASH_SOURCE guard prevents source-time execution" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$GATE"
}

@test "Review-thread gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  # Mirror the CI lint invocation (dev-lead-lint.sh): --severity=warning suppresses
  # the info-level SC1091 for the standalone-path source of maintainer-comment-gate.sh.
  shellcheck --shell=bash --severity=warning "$GATE"
}

# ────────────────────────────────────────────────────────────────────
# CLASSIFIER TESTS — review_thread_is_agent_authored (the resolve-guard)
# ────────────────────────────────────────────────────────────────────

@test "Classify: pr-review-agent marker → 0 (ours, resolvable)" {
  _run_classify '<!-- pr-review-agent v1 sha=abc --> Nit: rename this.'
  [ "$status" -eq 0 ]
}

@test "Classify: dev-lead marker → 0 (ours, resolvable)" {
  _run_classify '<!-- dev-lead --> Applied the fix.'
  [ "$status" -eq 0 ]
}

@test "Classify: persona marker → 0 (ours, resolvable)" {
  _run_classify '<!-- persona:pr-review --> Suggestion.'
  [ "$status" -eq 0 ]
}

@test "Classify: dependency-advisory marker → 0 (ours, resolvable)" {
  _run_classify '<!-- dependency-advisory --> Advisory.'
  [ "$status" -eq 0 ]
}

@test "Classify: marker-less body → 1 (maintainer finding, must not resolve)" {
  _run_classify 'This fails open — an API error emits no labels and returns success.'
  [ "$status" -eq 1 ]
}

@test "Classify: empty body → 1 (undeterminable → fail closed, must not resolve)" {
  _run_classify ''
  [ "$status" -eq 1 ]
}

# review_thread_login_is_excluded_bot — resolve-guard's bot exclusion so the guard
# uses the same maintainer definition as the gate (advisory-bot threads stay
# resolvable; only a non-excluded, marker-less author is a maintainer finding).
@test "Login: advisory bot (chatgpt-codex-connector) → 0 (excluded, not a maintainer)" {
  run bash -c "source '$GATE'; review_thread_login_is_excluded_bot 'chatgpt-codex-connector'"
  [ "$status" -eq 0 ]
}

@test "Login: coderabbitai → 0 (excluded, not a maintainer)" {
  run bash -c "source '$GATE'; review_thread_login_is_excluded_bot 'coderabbitai'"
  [ "$status" -eq 0 ]
}

@test "Login: owner account (don-petry) → 1 (maintainer-capable, not excluded)" {
  run bash -c "source '$GATE'; review_thread_login_is_excluded_bot 'don-petry'"
  [ "$status" -eq 1 ]
}

@test "Login: empty login → 1 (not excluded)" {
  run bash -c "source '$GATE'; review_thread_login_is_excluded_bot ''"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# GATE TESTS — check_maintainer_review_threads (withhold approval)
# ────────────────────────────────────────────────────────────────────

@test "Gate: no threads → 0 (nothing to block on)" {
  _run_check '{"reviewThreads":[]}' '2026-08-02T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Gate: marker-less maintainer thread postdates last push → 1 (block)" {
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"don-petry"},"body":"This resolve path is reachable by the agent.","createdAt":"2026-08-02T12:00:00Z"}]}}]}'
  _run_check "$json" '2026-08-02T10:00:00Z'
  [ "$status" -eq 1 ]
}

@test "Gate: fix pushed at/after the maintainer finding → 0 (addressed)" {
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"don-petry"},"body":"Please guard the resolve call.","createdAt":"2026-08-02T10:00:00Z"}]}}]}'
  _run_check "$json" '2026-08-02T12:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Gate: human-resolved maintainer thread → 0 (cleared by resolution)" {
  local json='{"reviewThreads":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"don-petry"},"body":"Blocking finding.","createdAt":"2026-08-02T12:00:00Z"}]}}]}'
  _run_check "$json" '2026-08-02T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Gate: marker-carrying thread from shared identity postdates push → 1 (marker alone not proof of bot authorship)" {
  # Body markers are user-controlled and not server-verifiable; a maintainer could
  # include <!-- dev-lead --> to spoof the exemption. The gate now classifies solely
  # on author login (excluded bots list + bot_user), so this thread blocks.
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"don-petry"},"body":"<!-- dev-lead --> Noted.","createdAt":"2026-08-02T12:00:00Z"}]}}]}'
  _run_check "$json" '2026-08-02T10:00:00Z'
  [ "$status" -eq 1 ]
}

@test "Gate: advisory-bot thread postdates push → 0 (handled by advisory gate)" {
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Actionable nit.","createdAt":"2026-08-02T12:00:00Z"}]}}]}'
  _run_check "$json" '2026-08-02T10:00:00Z'
  [ "$status" -eq 0 ]
}

@test "Gate: empty head date with an unresolved maintainer thread → 1 (fail closed)" {
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"don-petry"},"body":"Blocking finding.","createdAt":"2026-08-02T12:00:00Z"}]}}]}'
  _run_check "$json" ''
  [ "$status" -eq 1 ]
}

@test "Gate: empty head date but no maintainer thread → 0 (nothing to block)" {
  _run_check '{"reviewThreads":[]}' ''
  [ "$status" -eq 0 ]
}

@test "Gate: undeterminable createdAt on an unresolved maintainer thread → 1 (fail closed)" {
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"don-petry"},"body":"Finding with no timestamp."}]}}]}'
  _run_check "$json" '2026-08-02T10:00:00Z'
  [ "$status" -eq 1 ]
}

@test "Gate: undeterminable originating comment → 1 (fail closed)" {
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[]}}]}'
  _run_check "$json" '2026-08-02T10:00:00Z'
  [ "$status" -eq 1 ]
}

@test "Gate: malformed snapshot → 2 (fail closed)" {
  _run_check 'not json at all {' '2026-08-02T10:00:00Z'
  [ "$status" -eq 2 ]
}

@test "Gate: addressed maintainer thread + newer bot thread → 0 (bot does not re-arm)" {
  local json='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"don-petry"},"body":"Old finding.","createdAt":"2026-08-02T08:00:00Z"}]}},{"isResolved":false,"comments":{"nodes":[{"author":{"login":"sonarqubecloud"},"body":"Quality gate passed.","createdAt":"2026-08-02T13:00:00Z"}]}}]}'
  _run_check "$json" '2026-08-02T10:00:00Z'
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# #1413 REGRESSION FIXTURE
# Four inline review threads first-authored by `don-petry` with NO automation
# marker, unresolved, postdating the last push. This is the exact shape that on
# PR #1413 was self-resolved by the agent identity. The gate must BLOCK, and the
# classifier must refuse to resolve each marker-less thread.
# ────────────────────────────────────────────────────────────────────

@test "Regression #1413: four marker-less don-petry threads → 1 (block)" {
  local json
  json=$(cat "$SCRIPT_DIR/../tests/dev-lead/fixtures/review-threads/pr-1413-maintainer-threads.json")
  _run_check "$json" '2026-08-02T01:00:00Z'
  [ "$status" -eq 1 ]
}

@test "Regression #1413: each thread's originating comment classifies as NOT resolvable by the agent" {
  local fixture="$SCRIPT_DIR/../tests/dev-lead/fixtures/review-threads/pr-1413-maintainer-threads.json"
  # Every originating comment body in the fixture is marker-less → classifier returns 1.
  local n resolvable=0
  n=$(jq '.reviewThreads | length' "$fixture")
  [ "$n" -eq 4 ]
  for i in 0 1 2 3; do
    body=$(jq -r ".reviewThreads[$i].comments.nodes[0].body" "$fixture")
    if bash -c "source '$GATE'; review_thread_is_agent_authored \"\$1\"" _ "$body"; then
      resolvable=$((resolvable + 1))
    fi
  done
  [ "$resolvable" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# INTEGRATION / WIRING TESTS (review-one-pr.sh)
# ────────────────────────────────────────────────────────────────────

@test "Wiring: review-one-pr.sh sources the maintainer-review-thread gate" {
  grep -q "source.*maintainer-review-thread-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "check_maintainer_review_threads" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: review-one-pr.sh skips on rc=1 with unaddressed-maintainer-review-thread reason" {
  grep -q "unaddressed-maintainer-review-thread" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: review-one-pr.sh fails closed on rc=2" {
  grep -q "maintainer-review-thread-gate-error" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Wiring: FORCE_REVIEW bypasses the maintainer-review-thread gate" {
  grep -B12 "check_maintainer_review_threads" "$SCRIPT_DIR/review-one-pr.sh" | grep -q "FORCE_REVIEW"
}

@test "Guard: dev-lead-fix-reviews.sh sources the gate and guards the resolve call-site" {
  grep -q "maintainer-review-thread-gate.sh" "$SCRIPT_DIR/dev-lead-fix-reviews.sh"
  grep -q "review_thread_is_agent_authored" "$SCRIPT_DIR/dev-lead-fix-reviews.sh"
}

@test "Manifest: review-thread gate registered under pr-review.yml surface" {
  grep -q "scripts/lib/maintainer-review-thread-gate.sh" "$SCRIPT_DIR/lib/consumer-manifest.json"
}
