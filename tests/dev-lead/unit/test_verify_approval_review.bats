#!/usr/bin/env bats
# Tests for scripts/lib/verify-approval-review.sh — the pure post-condition check
# behind issue #1874. pr-review posted an approval ANNOUNCEMENT while the review
# write silently failed (a fine-grained PAT can `gh pr comment` but cannot
# `addPullRequestReview`), so a PR stranded at REVIEW_REQUIRED with a comment that
# lied. The fix verifies the review object actually exists by reading back the
# reviews API; `approval_review_present` is the pure decision at the heart of it.
#
# Run locally: bats tests/dev-lead/unit/test_verify_approval_review.bats

setup() {
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  source "$SCRIPT_DIR/lib/verify-approval-review.sh"
}

@test "approval present: REST shape (.user.login/.commit_id) matches bot+state+sha" {
  local reviews='[{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"deadbeef"}]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 0 ]
}

@test "approval present: gh shape (.author.login/.commit.oid) matches bot+state+sha" {
  local reviews='[{"author":{"login":"donpetry-bot"},"state":"APPROVED","commit":{"oid":"deadbeef"}}]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 0 ]
}

@test "approval absent: only COMMENTED entries from other accounts (the #1874 evidence)" {
  local reviews='[
    {"user":{"login":"don-petry"},"state":"COMMENTED","commit_id":"deadbeef"},
    {"user":{"login":"coderabbitai"},"state":"COMMENTED","commit_id":"deadbeef"},
    {"user":{"login":"gemini-code-assist"},"state":"COMMENTED","commit_id":"deadbeef"}
  ]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}

@test "approval absent: empty reviews array" {
  run approval_review_present "[]" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}

@test "approval absent: empty json argument" {
  run approval_review_present "" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}

@test "approval absent: APPROVED but by a different account" {
  local reviews='[{"user":{"login":"someone-else"},"state":"APPROVED","commit_id":"deadbeef"}]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}

@test "approval absent: bot APPROVED but at a stale (non-head) commit" {
  local reviews='[{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"cafef00d"}]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}

@test "approval present: sha empty (unspecified) accepts any commit for the bot's APPROVED review" {
  local reviews='[{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"whatever"}]'
  run approval_review_present "$reviews" "donpetry-bot" ""
  [ "$status" -eq 0 ]
}

@test "approval absent: DISMISSED review by the bot at head does not count" {
  local reviews='[{"user":{"login":"donpetry-bot"},"state":"DISMISSED","commit_id":"deadbeef"}]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}

@test "malformed json is treated as absent, not an error abort" {
  run approval_review_present "not json" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}

# #1875: `gh api --paginate` can emit one JSON array per page as a concatenated
# stream. The count must span all pages so an approval on a later page is found.
@test "approval present: split across paginated arrays (approval on the 2nd page)" {
  local reviews='[{"user":{"login":"coderabbitai"},"state":"COMMENTED","commit_id":"deadbeef"}][{"user":{"login":"donpetry-bot"},"state":"APPROVED","commit_id":"deadbeef"}]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 0 ]
}

@test "approval absent: multiple paginated arrays with no bot approval stay absent" {
  local reviews='[{"user":{"login":"coderabbitai"},"state":"COMMENTED","commit_id":"deadbeef"}][{"user":{"login":"gemini-code-assist"},"state":"COMMENTED","commit_id":"deadbeef"}]'
  run approval_review_present "$reviews" "donpetry-bot" "deadbeef"
  [ "$status" -eq 1 ]
}
