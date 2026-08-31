#!/usr/bin/env bats
# Tests for scripts/lib/pr-review-miss-rate.sh — the DETERMINISTIC false-negative
# metric for pr-review (issue #1596). No LLM is involved: every figure is computed
# with jq from GitHub review data.
#
# The crux under test is the accepted-vs-refuted disposition rule: a finding a
# trusted advisory bot opened AFTER pr-review's approving review counts as a
# `missed_finding` ONLY when the resolving reply accepted it (a fix landed / it
# was explicitly accepted). A refuted false positive, or any AMBIGUOUS
# disposition, must count as NOT a miss.
#
# Run locally: bats tests/test_pr_review_miss_rate.bats

setup() {
  # shellcheck source=scripts/lib/pr-review-miss-rate.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/pr-review-miss-rate.sh"
  BOTS='["copilot-pull-request-reviewer","gemini-code-assist","coderabbitai","codeant-ai","graphite-app"]'
  # An approving pr-review review, submitted before the bot findings below.
  APPROVAL='{"author":{"login":"donpetry-bot"},"state":"APPROVED","submittedAt":"2026-08-30T10:00:00Z","bodyText":"Approving.\n<!-- pr-review-agent v1 sha=deadbeef decision=approved risk=LOW -->"}'
}

# ---------------------------------------------------------------------------
# Disposition classifier — the documented accepted/refuted/ambiguous rule
# ---------------------------------------------------------------------------

@test "classify: accepted when the resolving reply accepts the finding (a real miss)" {
  thread='{"isResolved":true,"comments":{"nodes":[
    {"author":{"login":"codeant-ai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"Contract test compares rendered text, so 50 passes as an integer."},
    {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"Good catch — fixed in abc1234."}
  ]}}'
  run pr_review_classify_disposition "$thread" "$BOTS"
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
}

@test "classify: refuted when the resolving reply calls it a false positive" {
  thread='{"isResolved":true,"comments":{"nodes":[
    {"author":{"login":"codeant-ai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"yq appears to be missing."},
    {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"This is a false positive; the dedicated test workflow installs yq."}
  ]}}'
  run pr_review_classify_disposition "$thread" "$BOTS"
  [ "$status" -eq 0 ]
  [ "$output" = "refuted" ]
}

@test "classify: ambiguous when the reply gives no clear accept/refute signal" {
  thread='{"isResolved":true,"comments":{"nodes":[
    {"author":{"login":"codeant-ai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"Possible issue here."},
    {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"thanks"}
  ]}}'
  run pr_review_classify_disposition "$thread" "$BOTS"
  [ "$status" -eq 0 ]
  [ "$output" = "ambiguous" ]
}

@test "classify: an explicit disposition marker wins over keyword heuristics" {
  thread='{"isResolved":true,"comments":{"nodes":[
    {"author":{"login":"codeant-ai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"good catch phrasing that would look accepted"},
    {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"On reflection <!-- disposition: refuted --> not a real bug."}
  ]}}'
  run pr_review_classify_disposition "$thread" "$BOTS"
  [ "$output" = "refuted" ]
}

# ---------------------------------------------------------------------------
# Per-PR metrics — missed / caught / partial-evidence
# ---------------------------------------------------------------------------

@test "pr_metrics: an accepted bot finding after approval is a missed_finding, attributed to the bot" {
  pr='{"url":"https://x/pull/1","createdAt":"2026-08-30T09:00:00Z","isDraft":false,"author":{"login":"alice"},
    "reviews":{"nodes":['"$APPROVAL"']},
    "comments":{"nodes":[]},
    "reviewThreads":{"nodes":[
      {"isResolved":true,"comments":{"nodes":[
        {"author":{"login":"coderabbitai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"exempt note drift"},
        {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"Good catch, fixed."}
      ]}}
    ]}}'
  run pr_review_pr_metrics "$pr" "$BOTS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.missed_findings' <<<"$output")" = "1" ]
  [ "$(jq -r '.caught_findings' <<<"$output")" = "0" ]
  [ "$(jq -r '.per_bot["coderabbitai"]' <<<"$output")" = "1" ]
}

@test "pr_metrics: a refuted bot finding after approval is NOT a miss" {
  pr='{"url":"https://x/pull/2","createdAt":"2026-08-30T09:00:00Z","isDraft":false,"author":{"login":"alice"},
    "reviews":{"nodes":['"$APPROVAL"']},
    "comments":{"nodes":[]},
    "reviewThreads":{"nodes":[
      {"isResolved":true,"comments":{"nodes":[
        {"author":{"login":"codeant-ai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"registry assertion unguarded"},
        {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"False positive — the adjacent test covers it."}
      ]}}
    ]}}'
  run pr_review_pr_metrics "$pr" "$BOTS"
  [ "$(jq -r '.missed_findings' <<<"$output")" = "0" ]
}

@test "pr_metrics: a finding opened BEFORE approval is not a miss (no standing approval to miss against)" {
  pr='{"url":"https://x/pull/3","createdAt":"2026-08-30T09:00:00Z","isDraft":false,"author":{"login":"alice"},
    "reviews":{"nodes":['"$APPROVAL"']},
    "comments":{"nodes":[]},
    "reviewThreads":{"nodes":[
      {"isResolved":true,"comments":{"nodes":[
        {"author":{"login":"coderabbitai"},"createdAt":"2026-08-30T09:30:00Z","bodyText":"early finding"},
        {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T09:45:00Z","bodyText":"Good catch, fixed."}
      ]}}
    ]}}'
  run pr_review_pr_metrics "$pr" "$BOTS"
  [ "$(jq -r '.missed_findings' <<<"$output")" = "0" ]
}

@test "pr_metrics: a finding pr-review raised itself, accepted, is a caught_finding" {
  pr='{"url":"https://x/pull/4","createdAt":"2026-08-30T09:00:00Z","isDraft":false,"author":{"login":"alice"},
    "reviews":{"nodes":['"$APPROVAL"']},
    "comments":{"nodes":[]},
    "reviewThreads":{"nodes":[
      {"isResolved":true,"comments":{"nodes":[
        {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T09:20:00Z","bodyText":"This drops an error; please fix."},
        {"author":{"login":"alice"},"createdAt":"2026-08-30T09:50:00Z","bodyText":"Good catch — fixed."}
      ]}}
    ]}}'
  run pr_review_pr_metrics "$pr" "$BOTS"
  [ "$(jq -r '.caught_findings' <<<"$output")" = "1" ]
  [ "$(jq -r '.missed_findings' <<<"$output")" = "0" ]
}

@test "pr_metrics: a partial-evidence marker counts as a partial_evidence_approval" {
  pr='{"url":"https://x/pull/5","createdAt":"2026-08-30T09:00:00Z","isDraft":false,"author":{"login":"alice"},
    "reviews":{"nodes":['"$APPROVAL"']},
    "comments":{"nodes":[
      {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T10:00:05Z","bodyText":"<!-- pr-review-agent partial-evidence v1 sha=deadbeef submitted=2 required=3 reason=head-age-timeout -->"}
    ]},
    "reviewThreads":{"nodes":[]}}'
  run pr_review_pr_metrics "$pr" "$BOTS"
  [ "$(jq -r '.partial_evidence_approvals' <<<"$output")" = "1" ]
}

# ---------------------------------------------------------------------------
# Aggregation — overall miss rate + per reviewer
# ---------------------------------------------------------------------------

@test "aggregate: overall miss rate and per-reviewer attribution across PRs" {
  # Two miss_pr records: one accepted miss (coderabbitai), one caught finding.
  records='{"kind":"miss_pr","repo":"o/r","pr":"p1","approved":true,"missed_findings":1,"caught_findings":0,"partial_evidence_approvals":0,"per_bot":{"coderabbitai":1}}
{"kind":"miss_pr","repo":"o/r","pr":"p2","approved":true,"missed_findings":0,"caught_findings":1,"partial_evidence_approvals":1,"per_bot":{}}'
  out="$(printf '%s\n' "$records" | pr_review_aggregate_misses)"
  [ "$(jq -r '.missed_findings' <<<"$out")" = "1" ]
  [ "$(jq -r '.caught_findings' <<<"$out")" = "1" ]
  [ "$(jq -r '.partial_evidence_approvals' <<<"$out")" = "1" ]
  # miss rate = missed / (missed + caught) = 1/2 = 50%
  [ "$(jq -r '.miss_rate_pct' <<<"$out")" = "50" ]
  [ "$(jq -r '.per_bot["coderabbitai"]' <<<"$out")" = "1" ]
}

# ---------------------------------------------------------------------------
# Standing-approval invalidation detector (AC6)
# ---------------------------------------------------------------------------

@test "invalidatable: a post-approval accepted finding flags the approval SHA for dismissal" {
  pr='{"url":"https://x/pull/6","createdAt":"2026-08-30T09:00:00Z","isDraft":false,"author":{"login":"alice"},
    "reviews":{"nodes":['"$APPROVAL"']},
    "comments":{"nodes":[]},
    "reviewThreads":{"nodes":[
      {"isResolved":true,"comments":{"nodes":[
        {"author":{"login":"coderabbitai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"real defect"},
        {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"Good catch, fixed."}
      ]}}
    ]}}'
  run pr_review_invalidatable_approvals "$pr" "$BOTS"
  [ "$status" -eq 0 ]
  [ "$output" = "deadbeef" ]
}

@test "invalidatable: no accepted post-approval finding leaves the approval standing" {
  pr='{"url":"https://x/pull/7","createdAt":"2026-08-30T09:00:00Z","isDraft":false,"author":{"login":"alice"},
    "reviews":{"nodes":['"$APPROVAL"']},
    "comments":{"nodes":[]},
    "reviewThreads":{"nodes":[
      {"isResolved":true,"comments":{"nodes":[
        {"author":{"login":"coderabbitai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"nit"},
        {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"False positive."}
      ]}}
    ]}}'
  run pr_review_invalidatable_approvals "$pr" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
