#!/usr/bin/env bash
# post-enhancement.sh — post a single enhancement comment to an Ideas Discussion.
# Appends an idempotency marker so a later gather-candidates pass skips the idea
# (one enhancement per idea, re-run safe). Honors DRY_RUN.
#
# Env:
#   REPO              owner/repo (required)
#   DISCUSSION_NUMBER discussion to comment on (required)
#   BODY_PATH         file holding the enhancement markdown (required)
#   ENHANCER_MARKER   idempotency marker (default below; must match gather-candidates.sh)
#   DRY_RUN / DRY_RUN_LOG  "1" => log the intended comment instead of posting
#   GH_TOKEN          token for gh
set -euo pipefail

REPO="${REPO:?REPO required}"
if [[ "$REPO" != */* ]]; then
  echo "::error::REPO must be in 'owner/repo' format" >&2
  exit 1
fi
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
BODY_PATH="${BODY_PATH:?BODY_PATH required}"
MARKER="${ENHANCER_MARKER:-<!-- idea-enhancer:enhanced -->}"

[[ -s "$BODY_PATH" ]] || { echo "::error::enhancement body '$BODY_PATH' missing or empty" >&2; exit 1; }

owner="${REPO%/*}"
name="${REPO#*/}"

# Final comment = the drafted enhancement + the marker on its own line.
body="$(printf '%s\n\n%s\n' "$(cat "$BODY_PATH")" "$MARKER")"

_is_dry_run() { [[ "${DRY_RUN:-0}" = "1" ]]; }

if _is_dry_run; then
  jq -nc --arg op post_enhancement --argjson number "$DISCUSSION_NUMBER" \
    --arg body "$body" '{op:$op, number:$number, body_len:($body|length)}' \
    >>"${DRY_RUN_LOG:-./dry-run.jsonl}"
  echo "[dry-run] would comment on discussion #${DISCUSSION_NUMBER}"
  exit 0
fi

# Resolve the discussion's node id, then add the comment via GraphQL.
discussion_id="$(gh api graphql \
  -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        discussion(number:$number){ id }
      }
    }' \
  -F owner="$owner" -F name="$name" -F number="$DISCUSSION_NUMBER" \
  --jq '.data.repository.discussion.id')"

if [[ -z "$discussion_id" || "$discussion_id" = "null" ]]; then
  echo "::error::could not resolve discussion #${DISCUSSION_NUMBER} in ${REPO}" >&2
  exit 1
fi

gh api graphql \
  -f query='
    mutation($discussionId:ID!,$body:String!){
      addDiscussionComment(input:{discussionId:$discussionId, body:$body}){
        comment{ url }
      }
    }' \
  -F discussionId="$discussion_id" -F body="$body" \
  --jq '.data.addDiscussionComment.comment.url'

echo "enhanced discussion #${DISCUSSION_NUMBER}"
