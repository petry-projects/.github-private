#!/usr/bin/env bats
# Tests for the single approval diagnostic (issue #1894, AC #1 + AC #2).
#
# scripts/lib/approval-diagnostic.sh answers ONE deterministic question for a PR:
# "why is this PR not approved?" — naming the blocking gate, the specific unmet
# condition, and what would satisfy it. It reports the DEEPEST ENDURING blocker,
# not review-one-pr.sh's first-indicated skip reason (#1902): the advisory gate
# never truly withholds (it times out and proceeds), so a maintainer comment/thread
# that STILL blocks after that timeout is reported ahead of advisory-waiting. It is
# PURE (reads a PR snapshot JSON, writes JSON / Markdown, no network) so it is
# unit-tested here.
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
  # grep -c already prints 0 and exits 1 when there are no matches; `|| true` keeps
  # that clean under set -e without appending a duplicate 0 (which would break the
  # integer comparison in the caller).
  reviewer_sources_advisory_gate_logins | grep -c . || true
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

@test "diagnostic: an approving review at head with a lagging reviewDecision reports approved=true (appr_at_head fallback)" {
  # reviewDecision is REVIEW_REQUIRED (lagging, or the ruleset needs more approvers)
  # yet an approving review from the approver stands at headRefOid with no blocking
  # comment/thread. This exercises the appr_at_head fallback branch — NOT the
  # decision=="APPROVED" short-circuit that every other "approved" snapshot here hits
  # (thread I / cubic P3, #1902) — so a regression in that fallback cannot ship silently.
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
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

@test "diagnostic: incomplete advisory evidence reports waiting-for-advisory-bots, not timeout" {
  # No advisory bot has participated yet (0/2). This is a fresh partial state, NOT a
  # timeout fallback — the diagnostic must report the advisory gate as WAITING rather
  # than claiming approval-would-issue-via-timeout (the b76 hQT distinction).
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
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "waiting-for-advisory-bots" ]
  # via_timeout must be false while merely WAITING: no approval has issued, so no
  # timeout fallback fired — the renderer must not annotate a timeout (codeant nitpick).
  [ "$(jq -r '.advisory.via_timeout' <<<"$output")" = "false" ]
}

@test "diagnostic: a standing approval on incomplete advisory evidence is NOT annotated via_timeout (snapshot cannot prove it)" {
  # An approving review from the bot stands at head, yet only 1 of 2 advisory bots
  # participated. The snapshot CANNOT prove the approval issued via a timeout fallback
  # — it could equally have issued on the reduced effective denominator or manually —
  # so via_timeout must be false rather than falsely claiming a timeout (thread H,
  # #1902). via_timeout is reserved for the snapshot-provable head-age-timeout case.
  local snap='{
    "reviewDecision": "APPROVED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "gemini-code-assist"}, "state": "COMMENTED", "commit": {"oid": "abc123"}, "body": "advisory", "submittedAt": "2026-09-21T10:00:00Z"},
      {"author": {"login": "donpetry-bot"}, "state": "APPROVED", "commit": {"oid": "abc123"}, "body": "approved", "submittedAt": "2026-09-21T10:05:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "true" ]
  [ "$(jq -r '.advisory.submitted' <<<"$output")" = "1" ]
  [ "$(jq -r '.advisory.required' <<<"$output")" = "2" ]
  [ "$(jq -r '.advisory.via_timeout' <<<"$output")" = "false" ]
}

@test "diagnostic: complete advisory evidence but no approval reports approval-not-yet-issued" {
  # Both advisory bots participated (2/2) but no approving review from the bot exists
  # at head — the terminal state where approval would issue on the next pr-review run.
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "gemini-code-assist"}, "state": "COMMENTED", "commit": {"oid": "abc123"}, "body": "advisory", "submittedAt": "2026-09-21T10:00:00Z"},
      {"author": {"login": "copilot-pull-request-reviewer"}, "state": "COMMENTED", "commit": {"oid": "abc123"}, "body": "advisory", "submittedAt": "2026-09-21T10:01:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "false" ]
  [ "$(jq -r '.advisory.submitted' <<<"$output")" = "2" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "approval-not-yet-issued" ]
}

@test "diagnostic: a bot whose LATEST submission is a rate-limit notice is not counted (b76)" {
  # The advisory gate keeps only each bot's latest submission and drops it when that
  # latest is a rate-limit notice. gemini posted a real review, then a rate-limit
  # comment — its newest signal is the rate-limit notice, so it must NOT count as
  # participated and must appear in missing, matching get_advisory_bot_states().
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "gemini-code-assist"}, "state": "COMMENTED", "commit": {"oid": "abc123"}, "body": "advisory", "submittedAt": "2026-09-21T10:00:00Z"}
    ],
    "labels": [],
    "comments": [
      {"author": {"login": "gemini-code-assist"}, "body": "You have reached your usage limit. Please try again later.", "isMinimized": false, "minimizedReason": "", "createdAt": "2026-09-21T11:00:00Z"}
    ]
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.advisory.submitted' <<<"$output")" = "0" ]
  [ "$(jq -r '.advisory.missing | index("gemini-code-assist") != null' <<<"$output")" = "true" ]
}

@test "diagnostic: when every AVAILABLE advisory bot submitted and one is unavailable, the gate is NOT waiting (effective denominator, #657)" {
  # The runtime advisory gate decides against effective_total = required − unavailable,
  # dropping RATE_LIMITED/UNSUPPORTED bots. gemini submitted a real review; copilot is
  # UNSUPPORTED → effective = 2 − 1 = 1, submitted = 1. The diagnostic must NOT report
  # waiting-for-advisory-bots (it would contradict the gate returning ready-to-approve).
  # It falls through to approval-not-yet-issued (no standing approval), and the full
  # registry count stays in advisory.required (thread H / cubic P2, #1902). copilot's
  # unavailability is modelled as an UNSUPPORTED review rather than a rate-limit issue
  # comment so the maintainer-comment gate (which counts any non-agent comment) is not
  # tripped — isolating the effective-denominator behaviour under test.
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "gemini-code-assist"}, "state": "COMMENTED", "commit": {"oid": "abc123"}, "body": "advisory finding", "submittedAt": "2026-09-21T10:00:00Z"},
      {"author": {"login": "copilot-pull-request-reviewer"}, "state": "UNSUPPORTED", "commit": {"oid": "abc123"}, "body": "n/a", "submittedAt": "2026-09-21T10:01:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.advisory.submitted' <<<"$output")" = "1" ]
  [ "$(jq -r '.advisory.required' <<<"$output")" = "2" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" != "waiting-for-advisory-bots" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "approval-not-yet-issued" ]
}

@test "diagnostic: incomplete advisory evidence past the head-age timeout reports the timeout fallback, not waiting (thread D)" {
  # An old PR (head pushed well past the 1200s head-age timeout) with no advisory
  # output. The runtime advisory gate would PROCEED on partial evidence via the
  # head-age timeout, so the diagnostic must predict that — reporting the timeout
  # fallback with via_timeout=true rather than "still waiting", so the step summary
  # matches the run (thread D / cubic P2, #1902). Head date is supplied (the caller
  # already fetches it for the review-thread gate).
  local snap='{
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "abc123",
    "reviews": [],
    "labels": [],
    "comments": []
  }'
  # Head committer date far in the past → head-age >> 1200s.
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot "" "2020-01-01T00:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "false" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" != "waiting-for-advisory-bots" ]
  [ "$(jq -r '.advisory.via_timeout' <<<"$output")" = "true" ]
}

# ── b78: the maintainer review-thread gate is modelled when threads are supplied ──

@test "diagnostic: an unresolved maintainer review thread is the blocking gate (#1415)" {
  # reviewDecision=APPROVED with a standing approval at head, but an unresolved,
  # marker-less maintainer review thread postdates the head push. The runtime
  # maintainer-review-thread gate dismisses the approval — so the diagnostic must
  # report that gate as blocking rather than approved:true (the b78 gap).
  local snap='{
    "reviewDecision": "APPROVED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "donpetry-bot"}, "state": "APPROVED", "commit": {"oid": "abc123"}, "body": "ok", "submittedAt": "2026-09-21T10:00:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  local threads='{"reviewThreads":[
    {"isResolved": false, "comments": {"nodes": [
      {"author": {"login": "some-maintainer"}, "body": "This needs a rethink.", "createdAt": "2026-09-22T10:00:00Z"}
    ]}}
  ]}'
  # Head pushed BEFORE the thread was created → the thread postdates the push → blocks.
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot "$threads" "2026-09-21T09:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "false" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "maintainer-review-thread-gate" ]
}

@test "diagnostic: a resolved maintainer review thread does not block an approval" {
  local snap='{
    "reviewDecision": "APPROVED",
    "headRefOid": "abc123",
    "reviews": [
      {"author": {"login": "donpetry-bot"}, "state": "APPROVED", "commit": {"oid": "abc123"}, "body": "ok", "submittedAt": "2026-09-21T10:00:00Z"}
    ],
    "labels": [],
    "comments": []
  }'
  local threads='{"reviewThreads":[
    {"isResolved": true, "comments": {"nodes": [
      {"author": {"login": "some-maintainer"}, "body": "This needs a rethink.", "createdAt": "2026-09-22T10:00:00Z"}
    ]}}
  ]}'
  run diagnose_approval "$snap" '["copilot-pull-request-reviewer","gemini-code-assist"]' donpetry-bot "$threads" "2026-09-21T09:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.approved' <<<"$output")" = "true" ]
  [ "$(jq -r '.blocking_gate' <<<"$output")" = "none" ]
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
  # Assert the specific fail-closed code (2), not merely non-zero, so a syntax or
  # command-not-found error can't masquerade as the expected fail-closed path.
  [ "$status" -eq 2 ]
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
