#!/usr/bin/env bash
# open-review-threads.sh — enumerate EVERY unresolved review thread on a PR for a
# dev-lead fix-reviews / review-changes pass (#2046).
#
# WHY THIS EXISTS
#   OPEN_THREADS_JSON used to come from a single `reviewThreads(first:50)` page.
#   GitHub returns threads oldest first, so on a PR with more than 50 threads a
#   pass only ever saw the oldest page. On PR #1953 that page held five
#   already-deferred Codex threads, and the newer cubic and Codex threads never
#   reached the engine, which left them with no reply and no resolution. This
#   helper pages through every thread. It filters only on isResolved, never on
#   the triggering reviewer or review, so a pass sees every unresolved thread
#   from every reviewer.

# fetch_open_review_threads <repo> <pr_number>
#   Echo a JSON array of the PR's unresolved review threads, each
#   {id, isResolved, isOutdated, line, path, comments{nodes[{body, author{login,
#   __typename}}]}} (the first 100 comments). `gh --paginate` applies the --jq
#   filter to each page and prints one array per page, which are concatenated
#   here. It fails closed (non-zero, nothing on stdout) on any API failure, a
#   malformed page, or an unresolved thread with more than 100 comments, so a
#   pass never runs on an incomplete snapshot.
fetch_open_review_threads() {
  local repo="$1" pr="$2" pages
  # shellcheck disable=SC2016  # $owner/$repo/$pr/$endCursor are GraphQL variables
  pages=$(gh api graphql --paginate -f query='
      query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:100, after:$endCursor) {
              pageInfo { hasNextPage endCursor }
              nodes { id isResolved isOutdated line path comments(first:100) { pageInfo { hasNextPage } nodes { body author { login __typename } } } }
            }
          }
        }
      }' \
      -F owner="${repo%%/*}" -F repo="${repo##*/}" -F pr="$pr" \
      2>/dev/null) || { echo "::error::fetch_open_review_threads: thread fetch failed for ${repo}#${pr}" >&2; return 1; }
  # Filter locally (not via gh --jq). Fail closed: a page whose thread list is not
  # an array is a partial snapshot, and so is an open thread with >100 comments.
  printf '%s\n' "$pages" | jq -sce '
      [ .[] | .data.repository.pullRequest.reviewThreads.nodes
        | if type == "array" then . else error("non-array page") end ]
      | [ .[][] | select(.isResolved == false) ]
      | if any(.[]; .comments.pageInfo.hasNextPage == true)
        then error("open thread has more than 100 comments") else . end' 2>/dev/null \
    || { echo "::error::fetch_open_review_threads: incomplete thread pages for ${repo}#${pr}" >&2; return 1; }
}
