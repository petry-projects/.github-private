#!/usr/bin/env bats
# Tests for the single approval diagnostic (issue #1894, AC #1 + AC #2).
#
# scripts/lib/approval-diagnostic.sh answers ONE deterministic question for a PR:
# "why is this PR not approved?" — naming the blocking gate, the specific unmet
# condition, and what would satisfy it. It evaluates the approval gate chain in
# the SAME ORDER review-one-pr.sh applies it, so the diagnostic and the runtime
# gate can never disagree. It is PURE (reads a PR snapshot JSON, writes JSON /
# Markdown, no network) so it is unit-tested here.
#
# AC #2: the advisory denominator is reconciled with the registry — `required`
# equals the count of advisory_gate=yes logins in reviewer-sources.tsv and the
# missing bots are named, so `6 != 7` can never be silently possible.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DIAG_SH="$REPO_ROOT/scripts/lib/approval-diagnostic.sh"
REG_SH="$REPO_ROOT/scripts/lib/reviewer-sources.sh"

setup() {
  # shellcheck source=scripts/lib/approval-diagnostic.sh
  source "$DIAG_SH"
}

# Registry advisory_gate=yes count — the reconciled denominator (AC #2).
_registry_advisory_count() {
  # shellcheck source=scripts/lib/reviewer-sources.sh
  source "$REG_SH"
  reviewer_sources_advisory_gate_logins | grep -c .
}

# ── Structure ────────────────────────────────────────────────────────────────

@test "diagnostic: library exists and is shellcheck-clean" {
  [ -f "$DIAG_SH" ]
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash "$DIAG_SH"
}

# ── AC #1: the blocking gate is named, with a satisfaction path ───────────────

@test "diagnostic: undispositioned maintainer comment is the blocking gate" {
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [],
    "labels": [],
    "comments": [
      {"author": {"login": "some-maintainer"}, "body": "This is broken.", "isMinimized": false, "minimizedReason": "", "createdAt": "2026-09-20T10:00:00Z"}
    ]
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "false" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "maintainer-comment-gate" ]
  # names the specific condition and a satisfaction path
  [ -n "$(jq -r '.condition' <<<"$output")" ]
  [ -n "$(jq -r '.satisfied_by' <<<"$output")" ]
}

@test "diagnostic: an approval standing at head does NOT mask an undispositioned comment (#1813 revocation)" {
  # The maintainer-comment gate dismisses a standing approval. So even with an
  # approving review present at head, an undispositioned comment must be reported
  # as the blocking gate — otherwise the diagnostic would claim approved while the
  # next gate run revokes it (exactly the #1894 systemic defect).
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "donpetry-bot"}, "state": "APPROVED", "commit": {"oid": "abc123"}, "body": "ok", "submittedAt": "2026-09-21T10:00:00Z"}
    ],
    "labels": [],
    "comments": [
      {"author": {"login": "some-maintainer"}, "body": "still broken.", "isMinimized": false, "minimizedReason": "", "createdAt": "2026-09-20T10:00:00Z"}
    ]
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "false" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "maintainer-comment-gate" ]
}

@test "diagnostic: a comment minimized RESOLVED does not block" {
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [],
    "labels": [],
    "comments": [
      {"author": {"login": "some-maintainer"}, "body": "This is broken.", "isMinimized": true, "minimizedReason": "RESOLVED", "createdAt": "2026-09-20T10:00:00Z"}
    ]
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" != "maintainer-comment-gate" ]
}

@test "diagnostic: an already-approved PR reports approved=true, not blocked" {
  local snap='{
    "reviewDecision": "APPROVED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "donpetry-bot"}, "state": "APPROVED", "commit": {"oid": "abc123"}, "body": "ok", "submittedAt": "2026-09-21T10:00:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "true" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "none" ]
}

@test "diagnostic: changes-requested at head is named as the blocking gate" {
  local snap='{
    "reviewDecision": "CHANGES_REQUESTED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "some-maintainer"}, "state": "CHANGES_REQUESTED", "commit": {"oid": "abc123"}, "body": "no", "submittedAt": "2026-09-21T10:00:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "changes-requested" ]
}

@test "diagnostic: clean PR with no approving review reports the terminal state" {
  # Nothing blocks (no undispositioned comment, no changes requested) but there is
  # no approving review at head yet — the diagnostic must say so explicitly rather
  # than claim nothing is wrong.
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [],
    "labels": [],
    "comments": []
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "false" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "approval-not-yet-issued" ]
}

# ── AC #2: advisory denominator reconciled with the registry ─────────────────

@test "diagnostic: advisory.required equals the registry advisory_gate count" {
  local expected
  expected="$(_registry_advisory_count)"
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [],
    "labels": [],
    "comments": []
  }'
  # No advisory arg → the diagnostic must derive the denominator from the registry.
  run diagnose_approval "$snap"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.advisory.required' <<<"$output")" = "$expected" ]
}

@test "diagnostic: missing advisory bots are named (no silent drop)" {
  # Two advisory bots registered; only one submitted → the other must be listed
  # by name in advisory.missing so a partial denominator is observable.
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "gemini-code-assist"}, "state": "COMMENTED", "commit": {"oid": "abc123"}, "body": "advisory", "submittedAt": "2026-09-21T10:00:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.advisory.required' <<<"$output")" = "2" ]
  [ "$(jq -r '.advisory.submitted' <<<"$output")" = "1" ]
  [ "$(jq -r '.advisory.missing | index("copilot-pull-request-reviewer") != null' <<<"$output")" = "true" ]
  [ "$(jq -r '.advisory.missing | index("gemini-code-assist")' <<<"$output")" = "null" ]
}

@test "diagnostic: an advisory bot that posted only an issue comment counts as submitted" {
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [],
    "labels": [],
    "comments": [
      {"author": {"login": "codeant-ai"}, "body": "advisory finding", "isMinimized": false, "minimizedReason": "", "createdAt": "2026-09-21T10:00:00Z"}
    ]
  }'
  run diagnose_approval "$snap" '["codeant-ai","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  # codeant-ai submitted via a comment; it is NOT in missing.
  [ "$(jq -r '.advisory.missing | index("codeant-ai")' <<<"$output")" = "null" ]
  [ "$(jq -r '.advisory.missing | index("gemini-code-assist") != null' <<<"$output")" = "true" ]
}

# ── Fail-closed on malformed input (mirrors the gate posture) ─────────────────

@test "diagnostic: malformed snapshot fails closed (non-zero, does not claim approved)" {
  run diagnose_approval 'not json at all'
  [ "$status" -ne 0 ]
}

# ── Renderer ─────────────────────────────────────────────────────────────────

@test "renderer: produces a Markdown block naming the gate and satisfaction path" {
  local verdict='{
    "pr": "https://example/pull/1",
    "approved": false,
    "blocking_gate": "maintainer-comment-gate",
    "condition": "1 PR issue comment lacks a verified disposition",
    "satisfied_by": "dev-lead posts a verified disposition reply",
    "advisory": {"required": 7, "submitted": 4, "missing": ["copilot-pull-request-reviewer"], "via_timeout": true}
  }'
  run render_approval_diagnostic "$verdict"
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintainer-comment-gate"* ]]
  [[ "$output" == *"verified disposition"* ]]
  # advisory reconciliation surfaced: 4/7 and the missing bot named
  [[ "$output" == *"4/7"* ]]
  [[ "$output" == *"copilot-pull-request-reviewer"* ]]
}
