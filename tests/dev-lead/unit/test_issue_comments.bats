#!/usr/bin/env bats
# Unit tests for scripts/lib/issue-comments.sh (#1566)
#
# The library is PURE: it takes the (possibly paginated) issues/<n>/comments JSON
# on stdin and renders a filtered, chronological, size-bounded block for the
# dev-lead implementation prompt. Fetching is the caller's job.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/issue-comments.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── AC #5: a comment answering a body question reaches the prompt ─────────────

@test "issue-comments: a human comment answering the body's question is surfaced" {
  local json='[
    {"user":{"login":"alice","type":"User"},"created_at":"2026-08-21T01:14:00Z",
     "body":"The endpoint is oauth/usage with header anthropic-beta; it returns resets_at (HTTP 200 verified)."}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"oauth/usage"* ]]
  [[ "$output" == *"resets_at"* ]]
  [[ "$output" == *"@alice"* ]]
}

# ── AC #3: bot + dev-lead marker/status comments are filtered ─────────────────

@test "issue-comments: Bot-type authors are filtered out" {
  local json='[
    {"user":{"login":"github-actions","type":"Bot"},"created_at":"2026-08-21T00:00:00Z","body":"CI passed on abc123"},
    {"user":{"login":"carol","type":"User"},"created_at":"2026-08-21T02:00:00Z","body":"Real human steering here"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Real human steering here"* ]]
  [[ "$output" != *"CI passed on abc123"* ]]
}

@test "issue-comments: dev-lead HTML-marker status comments are filtered out" {
  local json='[
    {"user":{"login":"don-petry","type":"User"},"created_at":"2026-08-21T00:00:00Z",
     "body":"<!-- dev-lead-issue 1566 status=failed attempt=1 reason=engine-error run=9 -->\n## Dev-Lead: issue #1566 implementation failed — will retry"},
    {"user":{"login":"dave","type":"User"},"created_at":"2026-08-21T03:00:00Z","body":"Please also handle the null case"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Please also handle the null case"* ]]
  [[ "$output" != *"status=failed"* ]]
  [[ "$output" != *"will retry"* ]]
}

@test "issue-comments: dev-lead '## Dev-Lead' plan/progress comments are filtered out" {
  local json='[
    {"user":{"login":"don-petry","type":"User"},"created_at":"2026-08-21T00:00:00Z",
     "body":"## Dev-Lead Implementation Plan\n\n### Scope\nDo the thing."},
    {"user":{"login":"erin","type":"User"},"created_at":"2026-08-21T04:00:00Z","body":"The API key lives in vault path secret/foo"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault path secret/foo"* ]]
  [[ "$output" != *"Implementation Plan"* ]]
}

# ── AC #2: chronological order (later comments last) ──────────────────────────

@test "issue-comments: comments render in chronological order" {
  local json='[
    {"user":{"login":"a","type":"User"},"created_at":"2026-08-21T01:00:00Z","body":"FIRST_MARK earliest"},
    {"user":{"login":"b","type":"User"},"created_at":"2026-08-21T02:00:00Z","body":"SECOND_MARK middle"},
    {"user":{"login":"c","type":"User"},"created_at":"2026-08-21T03:00:00Z","body":"THIRD_MARK latest"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  local first second third
  first=$(printf '%s\n' "$output" | awk '/FIRST_MARK/ {print NR; exit}')
  second=$(printf '%s\n' "$output" | awk '/SECOND_MARK/ {print NR; exit}')
  third=$(printf '%s\n' "$output" | awk '/THIRD_MARK/ {print NR; exit}')
  [ "$first" -lt "$second" ]
  [ "$second" -lt "$third" ]
}

# ── AC #4: size bound is applied and truncation is STATED, not silent ─────────

@test "issue-comments: most-recent-N bound drops oldest and states the omission" {
  export ISSUE_COMMENTS_MAX=2
  # 4 human comments; only the 2 most recent survive, and the note must say 2 omitted.
  local json='[
    {"user":{"login":"a","type":"User"},"created_at":"2026-08-21T01:00:00Z","body":"OLDEST_C1"},
    {"user":{"login":"b","type":"User"},"created_at":"2026-08-21T02:00:00Z","body":"OLD_C2"},
    {"user":{"login":"c","type":"User"},"created_at":"2026-08-21T03:00:00Z","body":"NEW_C3"},
    {"user":{"login":"d","type":"User"},"created_at":"2026-08-21T04:00:00Z","body":"NEWEST_C4"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  # Newest two kept
  [[ "$output" == *"NEW_C3"* ]]
  [[ "$output" == *"NEWEST_C4"* ]]
  # Oldest two dropped
  [[ "$output" != *"OLDEST_C1"* ]]
  [[ "$output" != *"OLD_C2"* ]]
  # Truncation is explicitly stated (not silent)
  [[ "$output" == *"2"* ]]
  [[ "$output" =~ [Oo]mitted|[Tt]runcat|earlier ]]
}

@test "issue-comments: character budget drops older comments and states truncation" {
  export ISSUE_COMMENTS_MAX=100
  export ISSUE_COMMENTS_CHAR_BUDGET=40
  # Two comments, each body > budget/2, so the older one cannot fit and is dropped.
  local json='[
    {"user":{"login":"a","type":"User"},"created_at":"2026-08-21T01:00:00Z","body":"OLD_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
    {"user":{"login":"b","type":"User"},"created_at":"2026-08-21T02:00:00Z","body":"NEW_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  # The newest comment always survives the budget
  [[ "$output" == *"NEW_BBBB"* ]]
  # The older one is dropped and the omission is stated
  [[ "$output" != *"OLD_AAAA"* ]]
  [[ "$output" =~ [Oo]mitted|[Tt]runcat|earlier ]]
}

# ── #1800: author-trust filter (only write-access authors steer) ──────────────

@test "issue-comments: comments from non-collaborators are filtered out" {
  local json='[
    {"user":{"login":"outsider","type":"User"},"author_association":"NONE","created_at":"2026-08-21T01:00:00Z","body":"UNTRUSTED_STEERING drop me"},
    {"user":{"login":"drive-by","type":"User"},"author_association":"CONTRIBUTOR","created_at":"2026-08-21T02:00:00Z","body":"CONTRIB_STEERING drop me too"},
    {"user":{"login":"maint","type":"User"},"author_association":"MEMBER","created_at":"2026-08-21T03:00:00Z","body":"TRUSTED_STEERING keep me"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRUSTED_STEERING"* ]]
  [[ "$output" != *"UNTRUSTED_STEERING"* ]]
  [[ "$output" != *"CONTRIB_STEERING"* ]]
}

@test "issue-comments: OWNER and COLLABORATOR comments are surfaced" {
  local json='[
    {"user":{"login":"own","type":"User"},"author_association":"OWNER","created_at":"2026-08-21T01:00:00Z","body":"OWNER_NOTE"},
    {"user":{"login":"collab","type":"User"},"author_association":"COLLABORATOR","created_at":"2026-08-21T02:00:00Z","body":"COLLAB_NOTE"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OWNER_NOTE"* ]]
  [[ "$output" == *"COLLAB_NOTE"* ]]
}

# ── #1800: character budget is a HARD bound (newest oversized → truncated) ─────

@test "issue-comments: newest comment alone over budget is truncated, truncation stated" {
  export ISSUE_COMMENTS_MAX=100
  export ISSUE_COMMENTS_CHAR_BUDGET=30
  # Single newest comment far exceeding the budget: HEAD_ + 80 'x' + _TAILMARK.
  local big
  big="HEAD_$(printf 'x%.0s' {1..80})_TAILMARK"
  local json="[
    {\"user\":{\"login\":\"z\",\"type\":\"User\"},\"author_association\":\"MEMBER\",\"created_at\":\"2026-08-21T05:00:00Z\",\"body\":\"$big\"}
  ]"
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  # Head survives (within budget); tail beyond the budget is dropped.
  [[ "$output" == *"HEAD_"* ]]
  [[ "$output" != *"TAILMARK"* ]]
  # Truncation is explicitly stated, not silent.
  [[ "$output" =~ [Tt]runcat ]]
}

# ── empty / no-human-comments case ────────────────────────────────────────────

@test "issue-comments: no human comments → explicit 'no comments' note (never empty)" {
  local json='[
    {"user":{"login":"bot","type":"Bot"},"created_at":"2026-08-21T00:00:00Z","body":"beep boop"}
  ]'
  run bash -c "printf '%s' '$json' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" =~ [Nn]o.*comment ]]
}

@test "issue-comments: empty input → explicit 'no comments' note" {
  run bash -c "printf '%s' '[]' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [Nn]o.*comment ]]
}

@test "issue-comments: paginated (multiple JSON arrays) input is flattened" {
  # gh api --paginate concatenates one array per page.
  local page1='[{"user":{"login":"a","type":"User"},"created_at":"2026-08-21T01:00:00Z","body":"PAGE1_COMMENT"}]'
  local page2='[{"user":{"login":"b","type":"User"},"created_at":"2026-08-21T02:00:00Z","body":"PAGE2_COMMENT"}]'
  run bash -c "printf '%s%s' '$page1' '$page2' | { source '$LIB'; render_issue_comments; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PAGE1_COMMENT"* ]]
  [[ "$output" == *"PAGE2_COMMENT"* ]]
}
