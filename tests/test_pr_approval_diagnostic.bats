#!/usr/bin/env bats
# #1894: "why isn't this PR approved?" — answered by the REAL gate chain.
#
# scripts/review-one-pr.sh in diagnose mode (PR_REVIEW_DIAGNOSE=true) runs every
# gate in order on the live snapshot, then stops before any model runs. It is
# read-only and never forced. scripts/pr-approval-diagnostic.sh wraps it and adds
# the PR facts. These tests drive both end to end with the same gh stub as
# tests/test_review_one_pr_force_re_review.bats, and assert the run never writes
# to GitHub and never starts an engine.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REVIEW_SCRIPT="$REPO_ROOT/scripts/review-one-pr.sh"
  export DIAG_SCRIPT="$REPO_ROOT/scripts/pr-approval-diagnostic.sh"

  export SHA="1894a1b2c3d4e5f60718293a4b5c6d7e8f901234"
  export PR_URL="https://github.com/petry-projects/.github-private/pull/1894"

  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export SNAPSHOT="$TEST_DIR/snapshot.json"
  export ENGINE_LOG="$TEST_DIR/engines.log"; : > "$ENGINE_LOG"
  export GH_LOG="$TEST_DIR/gh_calls.log"
  : > "$GH_LOG"

  # gh stub: honors `pr view --jq <filter>` (so the idempotency block's own marker
  # query works), returns the snapshot for a plain `pr view`, and answers the
  # GraphQL shapes the gates use with old timestamps so they clear.
  cat > "$TEST_DIR/bin/gh" <<'GHEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  jqf=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqf="$a"
    prev="$a"
  done
  if [ -n "$jqf" ]; then jq -r "$jqf" "$SNAPSHOT"; else cat "$SNAPSHOT"; fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  case "$*" in
    *reviewThreads*) printf '%s' '{"data":{"resource":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
    *pushedDate*)    printf '%s' '{"data":{"resource":{"commits":{"nodes":[{"commit":{"pushedDate":"2020-01-01T00:00:00Z","committer":{"date":"2020-01-01T00:00:00Z"}}}]}}}}' ;;
    *)               printf '%s\n' '2020-01-01T00:00:00Z' ;;
  esac
  exit 0
fi
exit 0
GHEOF
  chmod +x "$TEST_DIR/bin/gh"

  # Stub engines so a bypassed (proceed) run can't block on a real CLI.
  for e in claude copilot gemini; do
    printf '#!/bin/bash\necho "%s" >> "$ENGINE_LOG"\nexit 0\n' "$e" > "$TEST_DIR/bin/$e"
    chmod +x "$TEST_DIR/bin/$e"
  done

  export PATH="$TEST_DIR/bin:$PATH"
  export REVIEW_ENGINE="claude" GH_TOKEN="fake"
  unset DRY_RUN GITHUB_STEP_SUMMARY
  unset FORCE_REVIEW FORCE_RE_REVIEW
}


ROLLUP_PASS='[{"name":"CI / build","status":"COMPLETED","conclusion":"SUCCESS"}]'
ROLLUP_FAIL='[{"name":"CI / build","status":"COMPLETED","conclusion":"FAILURE"}]'
ROLLUP_PENDING='[{"name":"CI / build","status":"IN_PROGRESS","conclusion":null}]'

# write_snap <rollup> [labels-json] [comments-json] [reviews-json] [reviewDecision]
write_snap() {
  jq -n --arg sha "$SHA" --argjson rollup "$1" --argjson labels "${2:-[]}" \
        --argjson comments "${3:-[]}" --argjson reviews "${4:-[]}" --arg rd "${5:-REVIEW_REQUIRED}" '{
    state: "OPEN", isDraft: false, mergeStateStatus: "BLOCKED",
    headRefOid: $sha, baseRefName: "main", statusCheckRollup: $rollup, reviewDecision: $rd,
    reviews: $reviews, labels: ($labels | map({name: .})), closingIssuesReferences: [],
    body: "PR body", comments: $comments
  }' > "$SNAPSHOT"
}

# _assert_read_only — no GitHub write of any kind, and no engine ran.
_assert_read_only() {
  ! grep -qE 'pr (comment|edit|review|merge)|mutation|--method (POST|PUT|PATCH|DELETE)|-X (POST|PUT|PATCH|DELETE)' "$GH_LOG"
  [ ! -s "$ENGINE_LOG" ]
}

_verdict() { grep -E '^\{"pr":' <<<"$output" | tail -n 1; }

@test "diagnose: every gate passes → proceed/gates-clear, and the cascade never starts" {
  write_snap "$ROLLUP_PASS"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [ "$(_verdict | jq -r '.decision + "/" + .reason')" = "proceed/gates-clear" ]
  [[ "$output" == *"diagnose: every gate passes"* ]]
  _assert_read_only
}

@test "diagnose: failing CI names the ci-failing gate and what clears it" {
  write_snap "$ROLLUP_FAIL"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "ci-failing" ]
  [[ "$(_verdict | jq -r '.would_change')" == *"turn green"* ]]
  _assert_read_only
}

@test "diagnose: pending CI reports ci-pending without polling" {
  write_snap "$ROLLUP_PENDING"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [[ "$(_verdict | jq -r '.reason')" == ci-pending* ]]
  [[ "$output" != *"waiting"*"for checks to settle"* ]]
  _assert_read_only
}

@test "diagnose is never forced: FORCE_REVIEW in the environment does not bypass a gate" {
  write_snap "$ROLLUP_FAIL"
  FORCE_REVIEW=true FORCE_RE_REVIEW=true PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "ci-failing" ]
  [[ "$output" != *"bypassing the ci-failing gate"* ]]
  _assert_read_only
}

@test "diagnose: an escalated PR holding needs-human-review reports the human escalation" {
  write_snap "$ROLLUP_PASS" '["needs-human-review"]' \
    '[{"author":{"login":"donpetry-bot"},"createdAt":"2026-10-09T04:44:00Z","body":"<!-- pr-review-agent human-escalation v1 -->\nescalated"}]'
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "human-escalated" ]
  _assert_read_only
}

@test "diagnose: a verdict already at head reports already-reviewed-at-head" {
  write_snap "$ROLLUP_PASS" '[]' \
    '[{"author":{"login":"donpetry-bot"},"createdAt":"2026-10-09T05:00:00Z","body":"<!-- pr-review-agent v1 sha='"$SHA"' --> <!-- decision=fix-requested risk=MEDIUM -->"}]'
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  [ "$(_verdict | jq -r '.reason')" = "already-reviewed-at-head" ]
  _assert_read_only
}

@test "verdicts are also written to the step summary (#1894 — where an operator looks)" {
  write_snap "$ROLLUP_FAIL"
  export GITHUB_STEP_SUMMARY="$TEST_DIR/summary.md"
  PR_REVIEW_DIAGNOSE=true run timeout 25 bash "$REVIEW_SCRIPT" "$PR_URL"
  grep -q "$PR_URL"'.*`skip` (ci-failing)\. Changes when: ' "$GITHUB_STEP_SUMMARY"
}

@test "wrapper: markdown report names the gate, what clears it, holds and approvals" {
  write_snap "$ROLLUP_FAIL" '["dev-lead:hands-off","bug"]' '[]' \
    '[{"author":{"login":"cubic-dev-ai"},"state":"APPROVED","commit":{"oid":"'"$SHA"'"},"body":"ok"}]'
  run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## pr-review approval diagnostic: $PR_URL"* ]]
  [[ "$output" == *'**Not approved** (review decision: `REVIEW_REQUIRED`).'* ]]
  [[ "$output" == *'| What pr-review would do now | `skip` — `ci-failing` |'* ]]
  [[ "$output" == *'| Hold labels | `dev-lead:hands-off` |'* ]]
  [[ "$output" == *'| Approvals at head | cubic-dev-ai |'* ]]
  [[ "$output" == *"This is the first gate that holds the PR"* ]]
  _assert_read_only
}

@test "wrapper: --json emits the verdict plus facts as one JSON object" {
  write_snap "$ROLLUP_PASS"
  run timeout 30 bash "$DIAG_SCRIPT" "$PR_URL" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<<"$output")" = "proceed" ]
  [ "$(jq -r '.facts.reviewDecision' <<<"$output")" = "REVIEW_REQUIRED" ]
  [ "$(jq -r '.facts.holds | length' <<<"$output")" = "0" ]
}

@test "wrapper: rejects a non-PR URL" {
  run bash "$DIAG_SCRIPT" "https://github.com/o/r/issues/1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "skill: every reason in the why-not-approved table is one review-one-pr.sh actually emits" {
  local skill="$REPO_ROOT/.claude/skills/why-not-approved/SKILL.md" r
  head -4 "$skill" | grep -q '^name: why-not-approved$'
  head -4 "$skill" | grep -q '^description: '
  while IFS= read -r r; do
    grep -qE "emit_verdict [a-z-]+ ${r} " "$REPO_ROOT/scripts/review-one-pr.sh" \
      || { echo "reason '$r' in SKILL.md is not emitted by review-one-pr.sh"; return 1; }
  done < <(awk -F'|' '/^\| `/ {print $2}' "$skill" | grep -oE '`[a-z-]+`' | tr -d '`' | grep -vxE 'reason|proceed' | sort -u)
}
