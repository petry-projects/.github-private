#!/usr/bin/env bash
# gather-candidates.sh — find open "Ideas" Discussions that are worth an
# automated enhancement pass: human-authored, not closed, and not yet enhanced
# (i.e. no prior comment carrying the idempotency marker).
#
# Emits $CONTEXT_PATH (JSON): { repo, marker, candidates: [ {number, title, url,
# author, createdAt, updatedAt, comments, labels, excerpt}, ... ] }. The enhancer
# agent reads it and posts one enhancement comment per candidate.
#
# Bot-authored ideas are skipped: those come from the feature-ideation run and
# are already AI-generated, so the human-added items are the ones that benefit.
#
# Env:
#   REPO              owner/repo (required)
#   CONTEXT_PATH      output JSON path (required)
#   DISCUSSION_NUMBER restrict to a single discussion (optional; used by the
#                     `discussion: created` trigger so a new human idea is
#                     enhanced immediately)
#   ENHANCER_MARKER   idempotency marker (default below; must match post-enhancement.sh)
#   GH_TOKEN          token for gh
set -euo pipefail

REPO="${REPO:?REPO required}"
if [[ "$REPO" != */* ]]; then
  echo "::error::REPO must be in 'owner/repo' format" >&2
  exit 1
fi
CONTEXT_PATH="${CONTEXT_PATH:?CONTEXT_PATH required}"
MARKER="${ENHANCER_MARKER:-<!-- idea-enhancer:enhanced -->}"
ONLY="${DISCUSSION_NUMBER:-}"

owner="${REPO%/*}"
name="${REPO#*/}"

all="[]"

if [[ -n "$ONLY" ]]; then
  page="$(gh api graphql \
    -f query='
      query($owner:String!,$name:String!,$number:Int!){
        repository(owner:$owner,name:$name){
          discussion(number:$number){
            number title url createdAt updatedAt closed
            category{ name }
            author{ login __typename }
            labels(first:20){ nodes{ name } }
            comments(first:100){ totalCount nodes{ body author{ login } } }
            bodyText
          }
        }
      }' \
    -F owner="$owner" -F name="$name" -F number="$ONLY")"

  all="$(printf '%s' "$page" | jq --arg marker "$MARKER" '
    [.data.repository.discussion
     | select(. != null)
     | select(.category.name == "Ideas")
     | select(.closed == false)
     | select((.author.__typename // "User") != "Bot")
     | select(((.author.login) // "") | endswith("[bot]") | not)
     | select([.comments.nodes[]? | select((.body // "") | contains($marker))] | length == 0)
     | {number, title, url,
        author: ((.author.login) // "unknown"),
        createdAt, updatedAt,
        comments: .comments.totalCount,
        labels: [.labels.nodes[].name],
        excerpt: (.bodyText[0:600])}]')"
else
  cursor=""
  has_next="true"

  while [[ "$has_next" = "true" ]]; do
    extra_args=()
    [[ -n "$cursor" ]] && extra_args+=(-F after="$cursor")

    page="$(gh api graphql \
      -f query='
        query($owner:String!,$name:String!,$after:String){
          repository(owner:$owner,name:$name){
            discussions(first:50, after:$after, orderBy:{field:UPDATED_AT, direction:DESC}){
              pageInfo{ hasNextPage endCursor }
              nodes{
                number title url createdAt updatedAt closed
                category{ name }
                author{ login __typename }
                labels(first:20){ nodes{ name } }
                comments(first:100){ totalCount nodes{ body author{ login } } }
                bodyText
              }
            }
          }
        }' \
      -F owner="$owner" -F name="$name" "${extra_args[@]}")"

    nodes="$(printf '%s' "$page" | jq --arg marker "$MARKER" '
      [.data.repository.discussions.nodes[]
       | select(.category.name == "Ideas")
       | select(.closed == false)
       | select((.author.__typename // "User") != "Bot")
       | select(((.author.login) // "") | endswith("[bot]") | not)
       | select([.comments.nodes[]? | select((.body // "") | contains($marker))] | length == 0)
       | {number, title, url,
          author: ((.author.login) // "unknown"),
          createdAt, updatedAt,
          comments: .comments.totalCount,
          labels: [.labels.nodes[].name],
          excerpt: (.bodyText[0:600])}]')"
    all="$(jq -n --argjson a "$all" --argjson b "$nodes" '$a + $b')"

    has_next="$(printf '%s' "$page" | jq -r '.data.repository.discussions.pageInfo.hasNextPage')"
    cursor="$(printf '%s' "$page" | jq -r '.data.repository.discussions.pageInfo.endCursor // ""')"
  done
fi

jq -n --arg repo "$REPO" --arg marker "$MARKER" --argjson candidates "$all" \
  '{repo: $repo, marker: $marker, candidates: $candidates}' >"$CONTEXT_PATH"

echo "context written to ${CONTEXT_PATH} (candidates=$(printf '%s' "$all" | jq 'length'))"
