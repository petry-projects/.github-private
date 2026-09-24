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
# #1918 — data-driven info-status classifier (SonarCloud clean passes)
# ────────────────────────────────────────────────────────────────────

# SonarCloud's real "Quality Gate passed" comment shape (trimmed): the headline plus
# per-metric lines. `_sonar_body <new_issues> <hotspots>` renders it with the given
# counts; `_sonar_json <login> <body> [reviews_json]` wraps it in a gate snapshot.
_sonar_body() {
  printf '%s' "## [![Quality Gate Passed](https://sonarsource.github.io/qg-passed-20px.png 'Quality Gate Passed')](https://sonarcloud.io/dashboard) **Quality Gate passed**  
Issues  
![](https://sonarsource.github.io/passed-16px.png '') [$1 New issues](https://sonarcloud.io/project/issues)  
![](https://sonarsource.github.io/accepted-16px.png '') [0 Accepted issues](https://sonarcloud.io/project/issues)

Measures  
![](https://sonarsource.github.io/passed-16px.png '') [$2 Security Hotspots](https://sonarcloud.io/project/security_hotspots)  
![](https://sonarsource.github.io/passed-16px.png '') [0.0% Coverage on New Code](https://sonarcloud.io/component_measures)"
}
_sonar_json() {
  jq -cn --arg l "$1" --arg b "$2" --argjson r "${3:-[]}" \
    '{reviews:$r, comments:[{author:{login:$l}, body:$b, isMinimized:false, minimizedReason:""}]}'
}

# AC1: a clean SonarCloud "Quality Gate passed" status comment (0 new issues, 0
# security hotspots) clears the gate with NO dev-lead and NO human — the classifier
# is keyed off the reviewer-source registry (sonarqubecloud + its info_status_pattern).
@test "AC1: SonarCloud 'Quality Gate passed' (0 new issues, 0 hotspots) clears → 0" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 0 0)")"
  [ "$status" -eq 0 ]
}

# AC1: the App login may surface with a [bot] suffix in some read shapes; it must
# still match the bare registry login.
@test "AC1: SonarCloud clean pass with a [bot] suffix login clears → 0" {
  _run_check "$(_sonar_json 'sonarqubecloud[bot]' "$(_sonar_body 0 0)")"
  [ "$status" -eq 0 ]
}

# AC1 precision (#1918 review): a gate can PASS while still reporting new issues or
# security hotspots (depends on the gate's conditions). Those are findings — the
# headline alone must not clear them.
@test "AC1: 'Quality Gate passed' but 2 New issues still blocks → 1" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 2 0)")"
  [ "$status" -eq 1 ]
}

@test "AC1: 'Quality Gate passed' but 1 Security Hotspot still blocks → 1" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 0 1)")"
  [ "$status" -eq 1 ]
}

@test "AC1: '10 New issues' is not mistaken for '0 New issues' → 1" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 10 0)")"
  [ "$status" -eq 1 ]
}

@test "AC1: bare 'Quality Gate passed' text without the zero-count lines blocks → 1" {
  _run_check "$(_sonar_json sonarqubecloud "Quality Gate passed")"
  [ "$status" -eq 1 ]
}

# AC2: a SonarCloud "Quality Gate failed" comment still blocks — it carries findings.
@test "AC2: SonarCloud 'Quality Gate failed' comment blocks → 1" {
  local json='{"comments":[{"author":{"login":"sonarqubecloud"},"body":"## Quality Gate failed\n\n2 new issues.","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC2: an unclassifiable SonarCloud comment (author registered, body does NOT match
# its info-status pattern) fails closed and blocks.
@test "AC2: unclassifiable SonarCloud comment blocks (fail closed) → 1" {
  local json='{"comments":[{"author":{"login":"sonarqubecloud"},"body":"Analysis in progress…","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC2: the pattern is per-author — a DIFFERENT bot with no info-status pattern is
# NOT cleared even if its body happens to contain "Quality Gate passed".
@test "AC2: a bot with no info-status pattern is not cleared by matching text → 1" {
  local json='{"comments":[{"author":{"login":"codeant-ai"},"body":"Quality Gate passed","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 1 ]
}

# AC5 (regression, whole loop): a PR carrying an approving pr-review review AND a
# later clean SonarCloud "Quality Gate passed" comment stays cleared — the gate
# returns 0, so review-one-pr.sh never dismisses the approval and no cycle is burned.
@test "AC5: approving review + later clean SonarCloud pass stays cleared → 0" {
  _run_check "$(_sonar_json sonarqubecloud "$(_sonar_body 0 0)" '[{"author":{"login":"donpetry-bot"},"state":"APPROVED"}]')"
  [ "$status" -eq 0 ]
}

# AC3 loop-safety: the maintainer escape-hatch reply carries a `maintainer-resolve`
# marker, so it is one of our own automation comments and never a new blocker.
@test "AC3: a maintainer-resolve marked reply is ignored → 0" {
  local json='{"comments":[{"author":{"login":"don-petry"},"body":"<!-- maintainer-resolve author=sonarqubecloud by=don-petry -->\nCleared: quality gate passed on the current head.","isMinimized":false,"minimizedReason":""}]}'
  _run_check "$json"
  [ "$status" -eq 0 ]
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
