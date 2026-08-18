#!/usr/bin/env bats
# Unit tests for the merge-ready-and-idle detection net
# (scripts/lib/pr-mergeready-detect.sh, issue #1469, epic #1402).
#
# The third member of the runaway (#948) / stall (#1410) detection family. Where
# the runaway net flags a PR with too MUCH automated activity and the stall net a
# PR awaiting a review step, this net flags a PR that is fully MERGE-READY —
# reviewDecision APPROVED, mergeable MERGEABLE, all required checks green — yet has
# sat idle past a threshold with no agent acting and nothing reporting that.
# #1451 sat merge-ready for 77h, merged only when a human noticed it.
#
# The detector must DISTINGUISH this case (AC#2) from the two adjacent shapes so
# triage doesn't re-diagnose which of the three a stalled PR is in:
#   • #1425 — agent-blocked-by-untrusted-bot: an unresolved review thread from a
#             bot OUTSIDE TRUSTED_BOTS that no agent is authorized to resolve.
#   • #1427 — reviewer-defers-on-pending-check: a pending / zombie check that makes
#             pr-review defer (ci_status == "pending").
# Neither is double-counted as merge-ready (AC#4).
#
# Detection only — the logic here never mutates a PR (AC#3). The tests pin the
# boundary behaviour (strict >), the env overrides, the human-gate fail-quiet
# (AC#2), the three-way shape classification, and the defensive guards.
#
# Run with: bats tests/test_pr_mergeready_detect.bats

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-mergeready-detect.sh"
}

teardown() {
  :
}

# args to pr_mergeready_shape / pr_mergeready_reasons / is_pr_mergeready:
#   <review_decision> <mergeable> <ci_status> <agent_blocked> <hours_idle> <gated>

# ---------------------------------------------------------------------------
# pr_mergeready_reasons / pr_mergeready_shape — the merge-ready-and-idle case.
# ---------------------------------------------------------------------------

@test "an APPROVED + MERGEABLE + green PR idle past the threshold is flagged merge-ready" {
  run pr_mergeready_shape APPROVED MERGEABLE passing false 24 false
  [ "$status" -eq 0 ]
  [ "$output" = "merge-ready-idle" ]

  run pr_mergeready_reasons APPROVED MERGEABLE passing false 24 false
  [ "$status" -eq 0 ]
  [[ "$output" == *merge-ready* ]]
  [[ "$output" == *24* ]]

  run is_pr_mergeready APPROVED MERGEABLE passing false 24 false
  [ "$status" -eq 0 ]
}

@test "the #1451 fixture — merge-ready and idle for 77h — is flagged (the positive fixture)" {
  # #1451: APPROVED, mergeable MERGEABLE, green on every required check for 77h,
  # blocked only by ONE unresolved TRUSTED-bot review thread (agent-resolvable, so
  # NOT the #1425 shape). It is the canonical positive case for this detector.
  run pr_mergeready_reasons APPROVED MERGEABLE passing false 77 false
  [ "$status" -eq 0 ]
  [[ "$output" == *merge-ready* ]]
  [[ "$output" == *77* ]]
  run is_pr_mergeready APPROVED MERGEABLE passing false 77 false
  [ "$status" -eq 0 ]
}

@test "idle exactly at the threshold does NOT fire (strict >)" {
  # default MERGEREADY_MIN_AGE_HOURS=12
  run pr_mergeready_reasons APPROVED MERGEABLE passing false 12 false
  [ -z "$output" ]
  run is_pr_mergeready APPROVED MERGEABLE passing false 12 false
  [ "$status" -ne 0 ]
}

@test "an APPROVED + green + MERGEABLE but recently-active PR is NOT flagged" {
  # Went green 3h ago — well within normal convergence latency; not stranded.
  run pr_mergeready_shape APPROVED MERGEABLE passing false 3 false
  [ -z "$output" ]
  run pr_mergeready_reasons APPROVED MERGEABLE passing false 3 false
  [ -z "$output" ]
  run is_pr_mergeready APPROVED MERGEABLE passing false 3 false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Only the fully merge-ready state qualifies — the un-ready states are not this
# failure mode.
# ---------------------------------------------------------------------------

@test "a not-yet-APPROVED PR does NOT fire (review is still outstanding)" {
  run pr_mergeready_reasons REVIEW_REQUIRED MERGEABLE passing false 48 false
  [ -z "$output" ]
}

@test "a CHANGES_REQUESTED PR does NOT fire" {
  run pr_mergeready_reasons CHANGES_REQUESTED MERGEABLE passing false 48 false
  [ -z "$output" ]
}

@test "a CONFLICTING (not MERGEABLE) PR does NOT fire — a rebase is owed, not a nudge" {
  run pr_mergeready_reasons APPROVED CONFLICTING passing false 48 false
  [ -z "$output" ]
}

@test "an UNKNOWN mergeable PR does NOT fire (GitHub still computing mergeability)" {
  run pr_mergeready_reasons APPROVED UNKNOWN passing false 48 false
  [ -z "$output" ]
}

@test "CI failing does NOT fire (waiting on a fix, not stranded-ready)" {
  run pr_mergeready_reasons APPROVED MERGEABLE failing false 48 false
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC#2 / AC#4 — distinguish the two adjacent shapes; never double-count them.
# ---------------------------------------------------------------------------

@test "#1427 shape (CI pending/zombie check) is classified reviewer-defer, NOT merge-ready" {
  run pr_mergeready_shape APPROVED MERGEABLE pending false 48 false
  [ "$status" -eq 0 ]
  [ "$output" = "reviewer-defer" ]
  # Excluded from the merge-ready flag — not double-counted (AC#4).
  run is_pr_mergeready APPROVED MERGEABLE pending false 48 false
  [ "$status" -ne 0 ]
  run pr_mergeready_reasons APPROVED MERGEABLE pending false 48 false
  [ -z "$output" ]
}

@test "#1425 shape (unresolved untrusted-bot thread) is classified agent-blocked, NOT merge-ready" {
  run pr_mergeready_shape APPROVED MERGEABLE passing true 48 false
  [ "$status" -eq 0 ]
  [ "$output" = "agent-blocked" ]
  # Excluded from the merge-ready flag — not double-counted (AC#4).
  run is_pr_mergeready APPROVED MERGEABLE passing true 48 false
  [ "$status" -ne 0 ]
  run pr_mergeready_reasons APPROVED MERGEABLE passing true 48 false
  [ -z "$output" ]
}

@test "an agent-blocked PR that is also recently active is not classified (not idle yet)" {
  run pr_mergeready_shape APPROVED MERGEABLE passing true 3 false
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC#2 — fail-quiet on intentional human-gated stops.
# ---------------------------------------------------------------------------

@test "a human-gated PR does NOT fire even when otherwise merge-ready and idle" {
  run pr_mergeready_shape APPROVED MERGEABLE passing false 999 true
  [ -z "$output" ]
  run pr_mergeready_reasons APPROVED MERGEABLE passing false 999 true
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Env-overridable threshold (AC#1)
# ---------------------------------------------------------------------------

@test "MERGEREADY_MIN_AGE_HOURS override is respected" {
  MERGEREADY_MIN_AGE_HOURS=24 run pr_mergeready_reasons APPROVED MERGEABLE passing false 20 false
  [ -z "$output" ]
  MERGEREADY_MIN_AGE_HOURS=24 run pr_mergeready_reasons APPROVED MERGEABLE passing false 25 false
  [[ "$output" == *merge-ready* ]]
}

@test "a non-numeric MERGEREADY_MIN_AGE_HOURS override falls back to the default (never 0)" {
  # A bad override must not silently set the threshold to 0 and flag every green PR.
  MERGEREADY_MIN_AGE_HOURS=abc run pr_mergeready_reasons APPROVED MERGEABLE passing false 3 false
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Defensive: non-numeric / missing inputs degrade to no-fire, never error.
# ---------------------------------------------------------------------------

@test "non-numeric idle input degrades to 0 (no crash, no false fire)" {
  run pr_mergeready_reasons APPROVED MERGEABLE passing false "xyz" false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing arguments degrade to no-fire" {
  run pr_mergeready_reasons
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# pr_mergeready_is_gated — the human-gate exclusions (AC#2). Reuses the canonical
# pr_has_escalation_label (needs-human-review) and the never-release hold labels.
# ---------------------------------------------------------------------------

@test "needs-human-review label is gated (reuses the canonical escalation check)" {
  run pr_mergeready_is_gated '["needs-human-review"]'
  [ "$status" -eq 0 ]
}

@test "dev-lead:hands-off label is gated" {
  run pr_mergeready_is_gated '["dev-lead:hands-off"]'
  [ "$status" -eq 0 ]
}

@test "initiative:hold label is gated" {
  run pr_mergeready_is_gated '["initiative:hold","something-else"]'
  [ "$status" -eq 0 ]
}

@test "a clean PR with no gate label is NOT gated" {
  run pr_mergeready_is_gated '["enhancement","dev-lead"]'
  [ "$status" -ne 0 ]
}

@test "empty / malformed labels degrade to not-gated" {
  run pr_mergeready_is_gated '[]'
  [ "$status" -ne 0 ]
  run pr_mergeready_is_gated 'not-json'
  [ "$status" -ne 0 ]
}

@test "MERGEREADY_HOLD_LABELS override is respected" {
  MERGEREADY_HOLD_LABELS="wip do-not-merge" run pr_mergeready_is_gated '["do-not-merge"]'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# pr_mergeready_thread_agent_blocked — the #1425 discriminator. An UNRESOLVED
# review thread authored by a Bot OUTSIDE the trusted set means no agent is
# authorized to resolve it (agent-blocked). A thread from a trusted bot, from a
# human, or that is already resolved does NOT block.
# ---------------------------------------------------------------------------

TRUSTED_CSV="copilot-pull-request-reviewer[bot],coderabbitai[bot],graphite-app[bot]"

@test "an unresolved thread from an UNTRUSTED bot is agent-blocked (#1425 shape)" {
  local threads
  threads='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"some-new-bot","__typename":"Bot"}}]}}]}'
  run pr_mergeready_thread_agent_blocked "$threads" "$TRUSTED_CSV"
  [ "$status" -eq 0 ]
}

@test "an unresolved thread from a TRUSTED bot is NOT agent-blocked (agent can resolve it)" {
  local threads
  threads='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"}}]}}]}'
  run pr_mergeready_thread_agent_blocked "$threads" "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
}

@test "a RESOLVED thread from an untrusted bot does NOT block (already cleared)" {
  local threads
  threads='{"reviewThreads":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"some-new-bot","__typename":"Bot"}}]}}]}'
  run pr_mergeready_thread_agent_blocked "$threads" "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
}

@test "an unresolved thread from a HUMAN is NOT agent-blocked by this check (bot-shape only)" {
  # A human maintainer thread is a different situation; the #1425 discriminator is
  # specifically the untrusted-BOT shape. Human threads are not classified here.
  local threads
  threads='{"reviewThreads":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"don-petry","__typename":"User"}}]}}]}'
  run pr_mergeready_thread_agent_blocked "$threads" "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
}

@test "no review threads at all is NOT agent-blocked" {
  run pr_mergeready_thread_agent_blocked '{"reviewThreads":[]}' "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
  run pr_mergeready_thread_agent_blocked '' "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
}

@test "malformed threads JSON degrades to not-blocked (fail-quiet, never crash)" {
  run pr_mergeready_thread_agent_blocked 'not-json' "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
}

@test "untrusted-bot thread on a paginated second page (combined nodes) is agent-blocked" {
  # mergeready_fetch_review_threads aggregates all pages into one array before
  # returning.  This test passes combined nodes from what would be two pages and
  # verifies that an untrusted-bot thread appearing after the first 100 nodes is
  # still correctly detected as agent-blocked.
  local threads
  threads='{"reviewThreads":[
    {"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"}}]}},
    {"isResolved":false,"comments":{"nodes":[{"author":{"login":"graphite-app","__typename":"Bot"}}]}},
    {"isResolved":false,"comments":{"nodes":[{"author":{"login":"second-page-unknown-bot","__typename":"Bot"}}]}}
  ]}'
  run pr_mergeready_thread_agent_blocked "$threads" "$TRUSTED_CSV"
  [ "$status" -eq 0 ]
}

@test "failed thread query (empty threads_json) does NOT cause agent-blocked classification" {
  # When mergeready_fetch_review_threads fails (returns exit 1), the scan marks
  # the PR scan_incomplete and skips it — it does NOT pass empty JSON to this
  # function.  This test confirms the pure classification function itself is safe
  # against empty/missing data: empty input is NOT agent-blocked.
  run pr_mergeready_thread_agent_blocked '' "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
  run pr_mergeready_thread_agent_blocked '{"reviewThreads":[]}' "$TRUSTED_CSV"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# pr_mergeready_hours_since — ISO-8601 -> integer hours since (injected now)
# ---------------------------------------------------------------------------

@test "pr_mergeready_hours_since computes whole hours against an injected now" {
  # last activity 2026-08-01T00:00:00Z, now 2026-08-04T05:00:00Z -> 77h.
  local now last
  last="2026-08-01T00:00:00Z"
  now=$(date -u -d "2026-08-04T05:00:00Z" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-08-04T05:00:00Z" +%s 2>/dev/null)
  run pr_mergeready_hours_since "$last" "$now"
  [ "$output" -eq 77 ]
}

@test "pr_mergeready_hours_since degrades to 0 on unparseable input" {
  run pr_mergeready_hours_since "not-a-date"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# generate_mergeready_report — renders a table with link + reason per candidate
# ---------------------------------------------------------------------------

@test "generate_mergeready_report renders each candidate with its link and reason" {
  local f
  f=$(mktemp "$STUB_DIR/tsv.XXXXXX")
  printf '%s\t%s\t%s\t%s\n' \
    "1451" "https://github.com/o/r/pull/1451" "Ready but stranded" "merge-ready-idle 77h: APPROVED + MERGEABLE + required checks green" \
    > "$f"
  run generate_mergeready_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#1451"* ]]
  [[ "$output" == *"https://github.com/o/r/pull/1451"* ]]
  [[ "$output" == *"merge-ready-idle 77h"* ]]
}

@test "generate_mergeready_report on an empty file prints an all-clear line, not a table" {
  local f
  f=$(mktemp "$STUB_DIR/tsv.XXXXXX")
  : > "$f"
  run generate_mergeready_report "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| PR |"* ]]
  [[ "$output" == *"No open PR"* ]]
}
