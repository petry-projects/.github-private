#!/usr/bin/env bats
# Tests for scripts/invalidate-standing-approval.sh — AC6 of issue #1596.
#
# When a trusted advisory bot opens an ACCEPTED finding AFTER a pr-review approval
# at the same head, the standing approval is a known false negative and must be
# dismissed so the PR re-opens for review. SAFETY: DRY_RUN defaults to true, so the
# wrapper reports rather than mutates unless DRY_RUN=false is set explicitly.
#
# The detector itself (pr_review_invalidatable_approvals) is unit-tested in
# tests/test_pr_review_miss_rate.bats; here we test the wrapper's plan + guardrail.
#
# Run locally: bats tests/test_invalidate_standing_approval.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/invalidate-standing-approval.sh"
  # donpetry-bot approved at sha=deadbeef; coderabbitai then opened an ACCEPTED
  # finding after the approval → the approval is invalidatable.
  export PR_NODE_JSON='{"url":"https://github.com/o/r/pull/9","reviews":{"nodes":[
    {"author":{"login":"donpetry-bot"},"state":"APPROVED","submittedAt":"2026-08-30T10:00:00Z","bodyText":"<!-- pr-review-agent v1 sha=deadbeef decision=approved risk=LOW -->"}]},
    "reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[
      {"author":{"login":"coderabbitai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"Real defect: nil deref."},
      {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"Good catch, fixed."}
    ]}}]},
    "comments":{"nodes":[]}}'
  export REST_REVIEWS_JSON='[{"id":55,"state":"APPROVED","body":"<!-- pr-review-agent v1 sha=deadbeef decision=approved risk=LOW -->","commit_id":"deadbeef"}]'
}

teardown() {
  unset PR_NODE_JSON REST_REVIEWS_JSON
}

@test "DRY_RUN default: reports the review it WOULD dismiss and makes NO gh call" {
  local tmpdir="$BATS_TEST_TMPDIR"
  cat > "$tmpdir/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMP_GH_CALLS"
exit 0
MOCK
  chmod +x "$tmpdir/gh"
  export TMP_GH_CALLS="$tmpdir/calls"
  run env PATH="$tmpdir:$PATH" DRY_RUN=true bash "$SCRIPT" "https://github.com/o/r/pull/9"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD dismiss approval review 55"* ]]
  # No mutating dismissals call was made in DRY_RUN.
  [ ! -s "$tmpdir/calls" ] || ! grep -q "dismissals" "$tmpdir/calls"
}

@test "DRY_RUN=false: dismisses the stale approval via the REST dismissals endpoint" {
  local tmpdir="$BATS_TEST_TMPDIR"
  cat > "$tmpdir/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMP_GH_CALLS"
exit 0
MOCK
  chmod +x "$tmpdir/gh"
  export TMP_GH_CALLS="$tmpdir/calls"
  run env PATH="$tmpdir:$PATH" DRY_RUN=false bash "$SCRIPT" "https://github.com/o/r/pull/9"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISMISSING approval review 55"* ]]
  grep -q "reviews/55/dismissals" "$tmpdir/calls"
}

@test "standing approval stands when the post-approval finding was refuted" {
  export PR_NODE_JSON='{"url":"https://github.com/o/r/pull/9","reviews":{"nodes":[
    {"author":{"login":"donpetry-bot"},"state":"APPROVED","submittedAt":"2026-08-30T10:00:00Z","bodyText":"<!-- pr-review-agent v1 sha=deadbeef decision=approved risk=LOW -->"}]},
    "reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[
      {"author":{"login":"coderabbitai"},"createdAt":"2026-08-30T10:40:00Z","bodyText":"maybe an issue"},
      {"author":{"login":"donpetry-bot"},"createdAt":"2026-08-30T11:05:00Z","bodyText":"False positive; not applicable."}
    ]}}]},
    "comments":{"nodes":[]}}'
  run env DRY_RUN=true bash "$SCRIPT" "https://github.com/o/r/pull/9"
  [ "$status" -eq 0 ]
  [[ "$output" == *"standing approval stands"* ]]
}
