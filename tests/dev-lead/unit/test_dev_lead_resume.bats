#!/usr/bin/env bats
# Unit tests for scripts/dev-lead-resume.sh — the event-first resume bridge
# (#1407). On a clearing event (a review submitted or a check_run success), a
# blocked/rate-limited dev-lead state is re-dispatched IMMEDIATELY via PAT
# repository_dispatch instead of waiting for the dev-lead-retry.yml safety-net
# cron. The resume reuses scan_pr_for_rate_limits from dev-lead-retry.sh so the
# dispatch + every stop condition (human markers, per-PR automation budget,
# reset window, terminal markers) is identical to the cron path.
#
# resume_main is guarded behind a BASH_SOURCE check so sourcing the script here
# exposes it without resolving a real event.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RESUME_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-resume.sh"

setup() {
  MOCK_BIN="$BATS_TEST_TMPDIR"
  export PATH="$MOCK_BIN:$PATH"

  export DRY_RUN="true"
  export NOW_ISO="2026-08-08T00:00:00Z"
  export HEAD_SHA="abc123def456"
  # A fix-ci rate-limited marker on the current head with a reset already in the
  # past → eligible to resume (so a suppress is the only thing that stops it).
  export COMMENTS_JSON
  COMMENTS_JSON="$(jq -nc --arg s "$HEAD_SHA" \
    '["<!-- dev-lead-fix-ci sha=\($s) status=rate-limited reset=2020-01-01T00:00:00Z check=CI failure -->"]')"
  export LABELS_JSON='[]'
  # gather_pr_automation_events pulls commits/reviews for the budget check;
  # default to empty so the budget is not exhausted unless a test says so.
  export COMMITS_JSON='[]'

  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*)          cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *pulls/*/commits*)     printf '%s' "${COMMITS_JSON}" ;;
  *pulls/*/reviews*)     printf '%s' "${DROPPED_REVIEWS_JSON:-[]}" ;;
  *pulls/*/comments*)    printf '%s' "${DROPPED_REVIEW_COMMENTS_JSON:-[]}" ;;
  *issues/*/comments*)   printf '%s' "${COMMENTS_JSON}" ;;
  *check-runs*)          printf '%s' '{"id":"","details_url":""}' ;;
  *pulls/*)              jq -nc --arg s "${HEAD_SHA}" --argjson l "${LABELS_JSON}" \
                           --arg state "${PR_STATE:-open}" \
                           --arg ref "${HEAD_REF:-}" --arg author "${PR_AUTHOR:-}" \
                           '{head:{sha:$s, ref:$ref}, user:{login:$author}, labels:($l | map({name:.})), state:$state}' ;;
  *)                     echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  export REPO="petry-projects/demo"
  export PR_NUMBER="860"

  source "$RESUME_SCRIPT"
}

teardown() {
  :
}

# ── (a) a clearing event resumes a pending rate-limited state ──────────────────
@test "resume: clearing event with a pending rate-limited marker dispatches a resume" {
  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-ci-failure"* ]]
}

# ── (b) an exhausted budget suppresses the resume ─────────────────────────────
@test "resume: exhausted per-PR automation budget suppresses the resume" {
  # 10 bot commits since the last human interaction → budget exhausted (#926).
  COMMITS_JSON="$(jq -nc '[range(10) | {commit:{author:{date:"2026-08-08T00:00:00Z"}}, author:{login:"donpetry-bot"}}]')"

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── (c) a human stop marker suppresses the resume ─────────────────────────────
@test "resume: needs-human-review marker suppresses the resume" {
  LABELS_JSON='["needs-human-review"]'

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── (d) no pending blocked state → nothing to resume ──────────────────────────
@test "resume: no rate-limited marker → no dispatch" {
  COMMENTS_JSON='["just a normal human comment"]'

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── (e2) clearing event recovers a DROPPED review-handling run (#1741) ────────
@test "resume: unaddressed trusted-reviewer finding on HEAD with no fix-reviews marker dispatches a reviews-retry" {
  # A run that was cancelled while pending posts no marker, so the rate-limited
  # scan can't see it. The dropped-review scan keys on an unaddressed trusted
  # CHANGES_REQUESTED pinned to HEAD with no dev-lead-fix-reviews marker.
  export HEAD_REF="dev-lead/issue-99"
  export TRUSTED_REVIEWERS="coderabbitai"
  # A normal comment only → the rate-limited scan does NOT fire, isolating the
  # dropped-review dispatch (and no dispatch guard / fix-reviews marker present).
  COMMENTS_JSON='["a normal human comment"]'
  export DROPPED_REVIEWS_JSON
  DROPPED_REVIEWS_JSON="$(jq -nc --arg s "$HEAD_SHA" \
    '[{state:"CHANGES_REQUESTED", commit_id:$s, submitted_at:"2026-08-08T00:00:00Z", user:{login:"coderabbitai"}}]')"

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" == *"would dispatch dev-lead-reviews-retry"* ]]
}

# ── (e) clearing event for a closed PR → no dispatch ──────────────────────────
@test "resume: closed PR suppresses the resume" {
  export PR_STATE="closed"

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

# ── unresolved PR (event carried no PR) → clean no-op ─────────────────────────
@test "resume: empty PR_NUMBER is a clean no-op" {
  PR_NUMBER=""

  run resume_main

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [[ "$output" == *"nothing to resume"* ]]
}
