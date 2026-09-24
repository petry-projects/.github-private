#!/usr/bin/env bats
# Unit tests for dev-lead-retry.sh dropped-review recovery (#1741).
#
# A run cancelled while still PENDING (GitHub keeps only the newest pending run
# in a concurrency group and cancels the older ones) leaves NO marker at all —
# so the rate-limited-only scan never recovers it. This suite covers the
# widened backstop: a PR carrying trusted-reviewer findings on the current HEAD
# SHA with no dev-lead-fix-reviews marker for that SHA is a never-ran drop and
# must be re-dispatched (and once a marker exists, it must NOT be).
#
# The script guards `main "$@"` behind a BASH_SOURCE check, so sourcing exposes
# the functions without running the org-wide scan.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

setup() {
  # $BATS_TEST_TMPDIR is per-test and auto-cleaned, so no manual teardown needed.
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  export DRY_RUN="true"
  export NOW_ISO="2026-09-08T12:00:00Z"
  export TRUSTED_REVIEWERS="coderabbitai,copilot-pull-request-reviewer,gemini-code-assist"
  export BOT_USER="don-petry"

  # Per-endpoint stub inputs (each test overrides as needed).
  export PR_OBJ='{"state":"open","head":{"sha":"deadbeef","ref":"dev-lead/issue-42"},"user":{"login":"don-petry"},"labels":[]}'
  export REVIEWS_JSON='[]'
  export REVIEW_COMMENTS_JSON='[]'
  export ISSUE_COMMENTS_JSON='[]'

  export PAYLOAD_FILE="$MOCK_BIN/payload.json"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *dispatches*)             cat > "${PAYLOAD_FILE:-/dev/null}"; exit 0 ;;
  *reviews*)                printf '%s' "${REVIEWS_JSON}" ;;
  *pulls*comments*)         printf '%s' "${REVIEW_COMMENTS_JSON}" ;;
  *issues*comments*)        printf '%s' "${ISSUE_COMMENTS_JSON}" ;;
  *pulls/*)                 printf '%s' "${PR_OBJ}" ;;
  *)                        echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  source "$RETRY_SCRIPT"
}

_review() {
  # _review <login> <state> <commit_id> [submitted_at]
  # Real reviews always carry submitted_at; the default keeps ordering-agnostic
  # tests concise while ordering-sensitive tests pass an explicit timestamp.
  jq -nc --arg l "$1" --arg s "$2" --arg c "$3" --arg t "${4:-2026-09-08T10:00:00Z}" \
    '{state:$s, commit_id:$c, submitted_at:$t, user:{login:$l}}'
}

_inline_comment() {
  # _inline_comment <login> <commit_id> [created_at]
  jq -nc --arg l "$1" --arg c "$2" --arg t "${3:-2026-09-08T10:00:00Z}" \
    '{commit_id:$c, created_at:$t, user:{login:$l}}'
}

_marker() {
  # _marker <sha> <intent> <status>
  printf '<!-- dev-lead-fix-reviews pr=42 sha=%s intent=%s status=%s -->' "$1" "$2" "$3"
}

# ── has_unaddressed_head_findings (pure predicate) ────────────────────────────

@test "findings: trusted CHANGES_REQUESTED on HEAD, no marker → unaddressed" {
  local reviews; reviews="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "[]"
  [ "$status" -eq 0 ]
}

@test "findings: trusted inline comment on HEAD, no marker → unaddressed" {
  local comments; comments="[$(_inline_comment "coderabbitai[bot]" deadbeef)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "[]" "$comments" "[]"
  [ "$status" -eq 0 ]
}

@test "findings: trusted finding but a dev-lead marker exists for the SHA → addressed" {
  local reviews; reviews="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"
  local issue; issue="$(jq -nc --arg m "$(_marker deadbeef fix-reviews applied)" '[$m]')"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "$issue"
  [ "$status" -eq 1 ]
}

@test "findings: even a rate-limited marker for the SHA counts as processed" {
  local reviews; reviews="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"
  local issue; issue="$(jq -nc --arg m "$(_marker deadbeef fix-reviews rate-limited)" '[$m]')"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "$issue"
  [ "$status" -eq 1 ]
}

@test "findings: finding is on an OUTDATED commit (not HEAD) → not unaddressed" {
  local reviews; reviews="[$(_review coderabbitai CHANGES_REQUESTED oldcommit)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "[]"
  [ "$status" -eq 1 ]
}

@test "findings: untrusted reviewer finding on HEAD → not unaddressed" {
  local reviews; reviews="[$(_review some-human CHANGES_REQUESTED deadbeef)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "[]"
  [ "$status" -eq 1 ]
}

@test "findings: an APPROVED review from a trusted bot on HEAD → not a finding" {
  local reviews; reviews="[$(_review coderabbitai APPROVED deadbeef)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "[]"
  [ "$status" -eq 1 ]
}

@test "findings: CHANGES_REQUESTED then a later APPROVED on the same SHA → superseded, not a finding" {
  # A later APPROVED (by submitted_at) resolves the earlier CHANGES_REQUESTED,
  # so the stale finding must not trigger recovery.
  local reviews
  reviews="[$(_review coderabbitai CHANGES_REQUESTED deadbeef 2026-09-08T10:00:00Z),$(_review coderabbitai APPROVED deadbeef 2026-09-08T11:00:00Z)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "[]"
  [ "$status" -eq 1 ]
}

@test "findings: CHANGES_REQUESTED then a later COMMENTED (no APPROVED) → still a finding (#1742)" {
  # The reviewer downgraded to COMMENTED but never APPROVED — the change request
  # is still open. The old latest-state collapse dropped it; ordering keeps it.
  local reviews
  reviews="[$(_review coderabbitai CHANGES_REQUESTED deadbeef 2026-09-08T10:00:00Z),$(_review coderabbitai COMMENTED deadbeef 2026-09-08T11:00:00Z)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "[]" "[]"
  [ "$status" -eq 0 ]
}

@test "findings: inline comment on HEAD but the author later APPROVED it → not a finding" {
  # APPROVED at 11:00 resolves the inline comment created at 10:00.
  local reviews; reviews="[$(_review coderabbitai APPROVED deadbeef 2026-09-08T11:00:00Z)]"
  local comments; comments="[$(_inline_comment "coderabbitai[bot]" deadbeef 2026-09-08T10:00:00Z)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "$comments" "[]"
  [ "$status" -eq 1 ]
}

@test "findings: inline comment left AFTER an APPROVED on the same SHA → still a finding (#1742)" {
  # The reviewer approved at 10:00, then posted a new inline concern at 11:00.
  # The old latest-state collapse treated any post-APPROVED comment as resolved;
  # timestamp ordering correctly counts the later comment as unaddressed.
  local reviews; reviews="[$(_review coderabbitai APPROVED deadbeef 2026-09-08T10:00:00Z)]"
  local comments; comments="[$(_inline_comment "coderabbitai[bot]" deadbeef 2026-09-08T11:00:00Z)]"
  run has_unaddressed_head_findings 42 deadbeef "$TRUSTED_REVIEWERS" "$reviews" "$comments" "[]"
  [ "$status" -eq 0 ]
}

# ── scan_pr_for_dropped_reviews (fetch + dispatch) ────────────────────────────

@test "scan: unaddressed HEAD findings → dispatches reviews-retry and warns" {
  REVIEWS_JSON="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"

  run scan_pr_for_dropped_reviews "petry-projects/.github-private" 42

  [ "$status" -eq 0 ]
  [[ "$output" == *"dropped-review recovery"* ]]
  [[ "$output" == *"would dispatch dev-lead-reviews-retry"* ]]
  # The integer count must be the only stdout line; stderr carries the logs.
  # Capture stdout alone (Bats `run` merges stderr into $output) and assert it.
  local count
  count=$(scan_pr_for_dropped_reviews "petry-projects/.github-private" 42 2>/dev/null)
  [ "$count" = "1" ]
}

@test "scan: dispatch payload is intent=fix-reviews on HEAD SHA" {
  export DRY_RUN="false"
  REVIEWS_JSON="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"

  run scan_pr_for_dropped_reviews "petry-projects/.github-private" 42

  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_FILE" ]
  [ "$(jq -r '.event_type' "$PAYLOAD_FILE")" = "dev-lead-reviews-retry" ]
  [ "$(jq -r '.client_payload.pr_number' "$PAYLOAD_FILE")" = "42" ]
  [ "$(jq -r '.client_payload.intent_type' "$PAYLOAD_FILE")" = "fix-reviews" ]
  [ "$(jq -r '.client_payload.head_sha' "$PAYLOAD_FILE")" = "deadbeef" ]
}

@test "scan: findings already have a marker for the SHA → no dispatch" {
  REVIEWS_JSON="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"
  ISSUE_COMMENTS_JSON="$(jq -nc --arg m "$(_marker deadbeef fix-reviews applied)" '[$m]')"

  run scan_pr_for_dropped_reviews "petry-projects/.github-private" 42

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

@test "scan: closed PR → no dispatch" {
  PR_OBJ='{"state":"closed","head":{"sha":"deadbeef"},"labels":[]}'
  REVIEWS_JSON="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"

  run scan_pr_for_dropped_reviews "petry-projects/.github-private" 42

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [[ "$output" == *"is closed"* ]]
}

@test "scan: PR gated with needs-human-review → no dispatch" {
  PR_OBJ='{"state":"open","head":{"sha":"deadbeef"},"labels":[{"name":"needs-human-review"}]}'
  REVIEWS_JSON="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"

  run scan_pr_for_dropped_reviews "petry-projects/.github-private" 42

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}

@test "scan: a recent dispatch guard for the SHA → skips to avoid duplicate" {
  REVIEWS_JSON="[$(_review coderabbitai CHANGES_REQUESTED deadbeef)]"
  ISSUE_COMMENTS_JSON="$(jq -nc \
    --arg g "<!-- dev-lead-dispatch-guard sha=deadbeef at=2026-09-08T11:59:00Z -->" '[$g]')"

  run scan_pr_for_dropped_reviews "petry-projects/.github-private" 42

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
  [[ "$output" == *"dispatch guard"* ]]
}

@test "scan: no findings at all → no dispatch, returns 0" {
  run scan_pr_for_dropped_reviews "petry-projects/.github-private" 42

  [ "$status" -eq 0 ]
  [[ "$output" != *"would dispatch"* ]]
}
