#!/usr/bin/env bats
# Unit tests for the undispositioned bot-comment retry (#2017).
#
# A registered reviewer bot's PR issue comment is dispositioned ONLY by
# dev-lead's fix-bot-comment intent. When that run is lost (superseded while
# pending in the per-PR concurrency lane — the #2009 case), nothing retried it and
# the PR stalled at the maintainer-comment gate. These tests pin:
#   • the pure decision (lib/bot-comment-retry.sh, bcr_retry_decisions);
#   • the sweep wiring in dev-lead-retry.sh (exactly one dispatch, dedup marker,
#     payload carries the comment node id — never its body).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/bot-comment-retry.sh"
RETRY_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-retry.sh"

TRUSTED='coderabbitai[bot],codeant-ai[bot],chatgpt-codex-connector[bot]'
INFO='{"chatgpt-codex-connector":"^You have reached your Codex usage limits"}'
# 2026-10-02T01:00:00Z — two hours after the comments below were posted.
NOW_EPOCH=1790902800

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
  export BOT_COMMENT_RETRY_MIN_AGE_SEC=900
  export BOT_COMMENT_RETRY_PENDING_SEC=9000
  export BOT_COMMENT_RETRY_MAX_ATTEMPTS=2
}

# _bot <id> <login> <body> [createdAt] [lastEditedAt] [minimizedReason]
_bot() {
  jq -nc --arg id "$1" --arg l "$2" --arg b "$3" \
    --arg c "${4:-2026-10-01T23:05:43Z}" --arg e "${5:-}" --arg m "${6:-}" '
    {id:$id, author:{login:$l, __typename:"Bot"}, authorAssociation:"NONE",
     body:$b, createdAt:$c, lastEditedAt:(if $e == "" then null else $e end),
     isMinimized:($m != ""), minimizedReason:(if $m == "" then null else $m end)}'
}

# _ours <body> [createdAt] [association] — a comment from our own automation.
_ours() {
  jq -nc --arg b "$1" --arg c "${2:-2026-10-01T23:30:00Z}" --arg a "${3:-OWNER}" '
    {id:("IC_ours_" + ($c | gsub("[^0-9]";""))), author:{login:"don-petry", __typename:"User"},
     authorAssociation:$a, body:$b, createdAt:$c, lastEditedAt:null,
     isMinimized:false, minimizedReason:null}'
}

_decide() {
  local comments
  comments="$(jq -sc '.' <<< "$*")"
  bcr_retry_decisions "$comments" "$TRUSTED" "$INFO" "$NOW_EPOCH"
}

_dispatches() { jq -r '[.[] | select(.decision == "dispatch")] | length' <<< "$1"; }
_reason_for() { jq -r --arg id "$2" 'first(.[] | select(.id == $id)) | .reason // "none"' <<< "$1"; }

# ── bcr_retry_decisions: AC5 matrix ──────────────────────────────────────────

@test "bcr: registered-bot comment, no disposition, no info-status match → exactly one dispatch" {
  out="$(_decide "$(_bot IC_cr coderabbitai 'Walkthrough: summary of changes')")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].id' <<< "$out")" = "IC_cr" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "1" ]
  [ "$(jq -r '.[0].version' <<< "$out")" = "2026-10-01T23:05:43Z" ]
}

@test "bcr: a comment with a current disposition dispatches none" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
Summary only, nothing to fix.')")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "dispositioned" ]
}

@test "bcr: a disposition that PREDATES an edit does not cover the edited comment" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-01T23:40:00Z)" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
ok' 2026-10-01T23:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].version' <<< "$out")" = "2026-10-01T23:40:00Z" ]
}

@test "bcr: a disposition citing ANOTHER comment does not cover this one" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr2 disposition=informational -->
ok')")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a disposition marker from an untrusted author is ignored (CWE-863)" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=invalid -->
spoof' 2026-10-01T23:30:00Z NONE)")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a pending/running retry (marker inside the pending window) is not duplicated" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-pending" ]
}

@test "bcr: a retry marker past the pending window (lost run) re-dispatches as the next attempt" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-01T22:00:00Z -->' 2026-10-01T22:00:00Z)")"
  # NOW - 22:00 = 3h > 150 min pending window → the retry is no longer live.
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "2" ]
}

@test "bcr: attempts for this comment version exhausted → no dispatch" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-01T20:00:00Z -->' 2026-10-01T20:00:00Z)" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=2 at=2026-10-01T21:00:00Z -->' 2026-10-01T21:00:00Z)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "retry-attempts-exhausted" ]
}

@test "bcr: a retry marker for an OLDER version does not block an edited comment" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-02T00:40:00Z)" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:30:00Z -->' 2026-10-02T00:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
  [ "$(jq -r '.[0].attempt' <<< "$out")" = "1" ]
}

@test "bcr: a fix-bot-comment pass that ENDED without a disposition is not retried" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr -->
## Dev-Lead — fix-bot-comment (no-changes)')")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "pass-completed" ]
}

@test "bcr: a pass that ended BEFORE the comment was edited does not block a retry" {
  out="$(_decide \
    "$(_bot IC_cr coderabbitai 'Walkthrough v2' 2026-10-01T23:05:43Z 2026-10-01T23:50:00Z)" \
    "$(_ours '<!-- dev-lead-fix-reviews pr=2009 sha=abc intent=fix-bot-comment status=no-changes comment=IC_cr -->' 2026-10-01T23:30:00Z)")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: a comment still inside the grace period (original run may be pending) → no dispatch" {
  out="$(_decide "$(_bot IC_cr coderabbitai 'Walkthrough' 2026-10-02T00:55:00Z)")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(_reason_for "$out" IC_cr)" = "grace-period" ]
}

@test "bcr: info_status_pattern match is not a candidate" {
  out="$(_decide "$(_bot IC_cx chatgpt-codex-connector 'You have reached your Codex usage limits for code reviews.')")"
  [ "$(_dispatches "$out")" = "0" ]
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: a comment already minimized RESOLVED is not a candidate" {
  out="$(_decide "$(_bot IC_cr coderabbitai 'Walkthrough' 2026-10-01T23:05:43Z '' RESOLVED)")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: unregistered bots and humans are not candidates" {
  human="$(jq -nc '{id:"IC_h", author:{login:"alice",__typename:"User"}, authorAssociation:"CONTRIBUTOR",
    body:"please fix", createdAt:"2026-10-01T23:05:43Z", lastEditedAt:null, isMinimized:false, minimizedReason:null}')"
  out="$(_decide "$human" "$(_bot IC_x some-other-bot 'hello')")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: our own agent-marked comments are never candidates" {
  out="$(_decide "$(_bot IC_m coderabbitai '<!-- dev-lead note --> mirrored')")"
  [ "$(jq 'length' <<< "$out")" = "0" ]
}

@test "bcr: node ids with regex metacharacters are compared literally" {
  out="$(_decide \
    "$(_bot 'IC_a+b/c=' coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_aXb/c= disposition=informational -->
ok')")"
  [ "$(_dispatches "$out")" = "1" ]
}

@test "bcr: malformed comments JSON fails closed (non-zero, no decision)" {
  run bcr_retry_decisions 'not-json' "$TRUSTED" "$INFO" "$NOW_EPOCH"
  [ "$status" -ne 0 ]
}

# ── dev-lead-retry.sh sweep wiring ───────────────────────────────────────────

_setup_sweep() {
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:$PATH"
  export DRY_RUN="false"
  export NOW_ISO="2026-10-02T01:00:00Z"
  export GH_LOG="$MOCK_BIN/gh.log"
  if [ -z "${PR_JSON:-}" ]; then
    export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"dev-lead/issue-2008-x"},"user":{"login":"don-petry"},"labels":[]}'
  fi
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  *"/dispatches"*) cat > "$GH_LOG.payload"; exit 0 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"--method POST"*"/comments"*) echo "777" ;;
  # The post-write marker listing (concurrency check) sees only our own marker.
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*) echo "777" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
  # shellcheck source=/dev/null
  source "$RETRY_SCRIPT"
  # The automation-budget gate needs its own API reads; it is covered elsewhere.
  pr_resume_suppressed() { return 1; }
}

_graphql_page() {
  jq -nc --argjson nodes "$(jq -sc '.' <<< "$*")" \
    '{data:{repository:{pullRequest:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}}}'
}

@test "sweep: an undispositioned registered-bot comment dispatches exactly one fix-bot-comment retry by node id" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough body \$(rm -rf /)')" \
    "$(_bot IC_ca codeant-ai 'Nitpicks' 2026-10-01T23:08:08Z)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "1" ]
  # Exactly ONE dispatch per PR per scan (a second would supersede the first
  # while it is pending in the per-PR lane).
  [ "$(grep -c '/dispatches' "$GH_LOG")" -eq 1 ]
  payload="$(cat "$GH_LOG.payload")"
  [ "$(jq -r '.event_type' <<< "$payload")" = "dev-lead-reviews-retry" ]
  [ "$(jq -r '.client_payload.intent_type' <<< "$payload")" = "fix-bot-comment" ]
  [ "$(jq -r '.client_payload.comment_node_id' <<< "$payload")" = "IC_cr" ]
  [ "$(jq -r '.client_payload.pr_number' <<< "$payload")" = "2009" ]
  # The comment body is never forwarded — the pass re-fetches it by node id.
  [[ "$payload" != *"Walkthrough"* ]]
  # A dedup marker was posted BEFORE the dispatch.
  grep -q 'dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1' "$GH_LOG"
  marker_line=$(grep -n 'dev-lead-bot-comment-retry' "$GH_LOG" | head -1 | cut -d: -f1)
  dispatch_line=$(grep -n '/dispatches' "$GH_LOG" | head -1 | cut -d: -f1)
  [ "$marker_line" -lt "$dispatch_line" ]
}

@test "sweep: a dispositioned comment dispatches nothing" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead:comment-disposition id=IC_cr disposition=informational -->
ok')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  ! grep -q '/dispatches' "$GH_LOG"
}

@test "sweep: a pending retry is not duplicated" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page \
    "$(_bot IC_cr coderabbitai 'Walkthrough')" \
    "$(_ours '<!-- dev-lead-bot-comment-retry id=IC_cr version=2026-10-01T23:05:43Z attempt=1 at=2026-10-02T00:50:00Z -->' 2026-10-02T00:50:00Z)")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0" ]
  ! grep -q '/dispatches' "$GH_LOG"
}

@test "sweep: a closed PR is never swept" {
  export PR_JSON='{"state":"closed","head":{"sha":"abc","ref":"dev-lead/issue-1-x"},"user":{"login":"don-petry"},"labels":[]}'
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  ! grep -q '/dispatches' "$GH_LOG"
}

@test "sweep: a human-authored PR (not dev-lead's) is never swept" {
  export PR_JSON='{"state":"open","head":{"sha":"abc","ref":"feature/x"},"user":{"login":"alice"},"labels":[]}'
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  ! grep -q '/dispatches' "$GH_LOG"
}

@test "sweep: DRY_RUN posts no marker and sends no dispatch" {
  _setup_sweep
  export DRY_RUN="true"
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "1" ]
  [[ "$output" == *"would dispatch dev-lead-reviews-retry"*"fix-bot-comment"* ]]
  ! grep -q '/dispatches' "$GH_LOG"
  ! grep -q 'dev-lead-bot-comment-retry' "$GH_LOG"
}

@test "sweep: a comment-fetch failure fails closed (no dispatch)" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE='{"errors":[{"message":"boom"}]}'

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  ! grep -q '/dispatches' "$GH_LOG"
}

@test "retry header: the 'cannot be reconstructed' rationale names on-mention only" {
  run grep -n 'NOT retried automatically: on-mention$' "$RETRY_SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qE 'NOT retried automatically:.*fix-bot-comment' "$RETRY_SCRIPT"
}

@test "sweep: a failed dispatch withdraws its retry marker (never blocks the next attempt)" {
  _setup_sweep
  export TRUSTED_BOTS="$TRUSTED"
  export GRAPHQL_RESPONSE
  GRAPHQL_RESPONSE="$(_graphql_page "$(_bot IC_cr coderabbitai 'Walkthrough')")"
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"/dispatches"*) exit 1 ;;
  *"api graphql"*) printf '%s' "$GRAPHQL_RESPONSE" ;;
  *"--method POST"*"/comments"*) echo "777" ;;
  *"comments?per_page"*"dev-lead-bot-comment-retry id="*) echo "777" ;;
  *"/pulls/"*) printf '%s' "$PR_JSON" ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  run scan_pr_for_undispositioned_bot_comments "petry-projects/.github-private" 2009
  [ "${lines[-1]}" = "0" ]
  # It reached (and failed) the dispatch — not the concurrent-scan back-off path.
  grep -q '/dispatches' "$GH_LOG"
  [[ "$output" != *"a concurrent scan already recorded a retry"* ]]
  grep -q -- '-X DELETE repos/petry-projects/.github-private/issues/comments/777' "$GH_LOG"
}

# ── AC3: pr-review acts on its own undispositioned-pr-comment verdict ─────────

@test "review-one-pr: the undispositioned-pr-comment no-op triggers the bot-comment retry scan first" {
  REVIEW="$SCRIPT_DIR/scripts/review-one-pr.sh"
  scan_line=$(grep -n 'scan_pr_for_undispositioned_bot_comments "\$_OWNER_REPO"' "$REVIEW" | head -1 | cut -d: -f1)
  verdict_line=$(grep -n 'emit_verdict skip undispositioned-pr-comment' "$REVIEW" | head -1 | cut -d: -f1)
  gate_line=$(grep -n 'if \[ "\$mc_gate_rc" -eq 1 \]' "$REVIEW" | head -1 | cut -d: -f1)
  [ -n "$scan_line" ] && [ -n "$verdict_line" ] && [ -n "$gate_line" ]
  # Inside the rc=1 (undispositioned) branch, before its verdict/exit.
  [ "$gate_line" -lt "$scan_line" ]
  [ "$scan_line" -lt "$verdict_line" ]
  # Never in DRY_RUN, and best-effort (cannot fail the review run).
  sed -n "${gate_line},${verdict_line}p" "$REVIEW" | grep -q 'DRY_RUN:-false}" != "true"'
  sed -n "${gate_line},${verdict_line}p" "$REVIEW" | grep -q ') 2>&1 ) || true'
}

@test "review-one-pr: the retry scan sourced from pr-review resolves a real function" {
  # The hook sources dev-lead-retry.sh in a subshell; make sure that works from
  # an arbitrary caller and exposes the function without running main.
  run bash -c "source '$RETRY_SCRIPT' && declare -F scan_pr_for_undispositioned_bot_comments"
  [ "$status" -eq 0 ]
  [ "$output" = "scan_pr_for_undispositioned_bot_comments" ]
}

@test "scan_repo: a PR that already got a rate-limit retry this scan gets no bot-comment dispatch" {
  _setup_sweep
  scan_pr_for_rate_limits() { echo "1"; }
  scan_pr_for_undispositioned_bot_comments() { echo "CALLED" >&2; echo "1"; }
  scan_repo_issues() { :; }
  gh() { echo '[{"number":2009,"head_sha":"abc"}]'; }

  run scan_repo "petry-projects/.github-private"
  [[ "$output" != *"CALLED"* ]]
  [[ "$output" == *"dispatched 1 PR retries"* ]]
}

@test "scan_repo: a PR with no rate-limit retry is swept for undispositioned bot comments" {
  _setup_sweep
  scan_pr_for_rate_limits() { echo "0"; }
  scan_pr_for_undispositioned_bot_comments() { echo "CALLED" >&2; echo "1"; }
  scan_repo_issues() { :; }
  gh() { echo '[{"number":2009,"head_sha":"abc"}]'; }

  run scan_repo "petry-projects/.github-private"
  [[ "$output" == *"CALLED"* ]]
  [[ "$output" == *"dispatched 1 PR retries"* ]]
}
