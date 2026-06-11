#!/usr/bin/env bash
# gather-ideas.sh — assemble context for the weekly idea-triage pass: every open
# Ideas Discussion plus the signals needed to judge "ripeness" (open initiative
# epics it might already be covered by, and open issues it might reference).
#
# Emits $CONTEXT_PATH (JSON). The triage agent reads it, ranks the ideas, and
# refreshes the "Idea Promotion Queue" tracking issue.
#
# Env: REPO, CONTEXT_PATH (required); GH_TOKEN.
set -euo pipefail

REPO="${REPO:?REPO required}"
CONTEXT_PATH="${CONTEXT_PATH:?CONTEXT_PATH required}"

owner="${REPO%/*}"
name="${REPO#*/}"

all_ideas="[]"
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
              number title url createdAt updatedAt
              category{ name }
              labels(first:20){ nodes{ name } }
              comments{ totalCount }
              bodyText
            }
          }
        }
      }' \
    -F owner="$owner" -F name="$name" "${extra_args[@]}")"

  nodes="$(printf '%s' "$page" \
    | jq '[.data.repository.discussions.nodes[]
           | select(.category.name == "Ideas")
           | {number, title, url, createdAt, updatedAt,
              comments: .comments.totalCount,
              labels: [.labels.nodes[].name],
              excerpt: (.bodyText[0:600])}]')"
  all_ideas="$(jq -n --argjson a "$all_ideas" --argjson b "$nodes" '$a + $b')"

  has_next="$(printf '%s' "$page" | jq -r '.data.repository.discussions.pageInfo.hasNextPage')"
  cursor="$(printf '%s' "$page" | jq -r '.data.repository.discussions.pageInfo.endCursor // ""')"
done

ideas="$all_ideas"

if ! epics="$(gh issue list --repo "$REPO" --label initiative --state open \
  --json number,title --jq '[.[] | {number, title}]' 2>/dev/null)"; then
  echo "::error::failed to fetch open initiative epics for ${REPO}" >&2
  exit 1
fi

jq -n --argjson ideas "$ideas" --argjson epics "$epics" --arg repo "$REPO" \
  '{repo: $repo, open_ideas: $ideas, open_epics: $epics}' >"$CONTEXT_PATH"

echo "context written to ${CONTEXT_PATH} (ideas=$(printf '%s' "$ideas" | jq 'length'), epics=$(printf '%s' "$epics" | jq 'length'))"
