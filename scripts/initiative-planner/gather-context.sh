#!/usr/bin/env bash
# gather-context.sh — assemble the planning context for the BMAD Scrum Master.
#
# Discussions are not part of the git checkout, so we fetch the approved idea
# (title/body/first 50 comments + GraphQL node id) here and hand it to the agent as a
# single JSON file. We also surface the open `initiative` epics (so Bob can
# avoid duplicating one) and the issue numbers the idea references (likely
# prerequisites). The agent reads everything else (AGENTS.md, scripts, docs)
# straight from the checkout with its own tools.
#
# Emits:
#   - $CONTEXT_PATH (JSON)               the planning context
#   - DISCUSSION_NODE_ID -> $GITHUB_ENV  so apply-plan can comment back
#
# Env: REPO, DISCUSSION_NUMBER, CONTEXT_PATH (all required); GH_TOKEN.
set -euo pipefail

REPO="${REPO:?REPO required}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
CONTEXT_PATH="${CONTEXT_PATH:?CONTEXT_PATH required}"

owner="${REPO%/*}"
name="${REPO#*/}"

# ── the approved idea (GraphQL: discussion is not in the REST issues space) ────
disc="$(gh api graphql -f query='
  query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){
      discussion(number:$num){
        id title body url
        category{ name }
        comments(first:50){ nodes{ author{login} body createdAt } }
      }
    }
  }' -F owner="$owner" -F name="$name" -F num="$DISCUSSION_NUMBER")"

node_id="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.id')"
category="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.category.name // ""')"
if [[ -z $node_id ]] || [[ $node_id = "null" ]]; then
  echo "::error::discussion #${DISCUSSION_NUMBER} not found in ${REPO}" >&2
  exit 1
fi
if [[ $category != "Ideas" ]]; then
  echo "::warning::discussion #${DISCUSSION_NUMBER} is in category '${category}', not 'Ideas' — planning anyway."
fi
printf 'DISCUSSION_NODE_ID=%s\n' "$node_id" >>"${GITHUB_ENV:-/dev/null}"

# ── existing open epics (avoid duplicate initiatives) ─────────────────────────
if ! epics="$(gh issue list --repo "$REPO" --label initiative --state open \
  --json number,title --jq '[.[] | {number, title}]' 2>/dev/null)"; then
  echo "::error::failed to fetch open initiative epics for ${REPO}" >&2
  exit 1
fi

# ── issue numbers referenced by the idea (likely prerequisites) ───────────────
refs="$(printf '%s' "$disc" \
  | jq -r '.data.repository.discussion | ((.body // "") + " " + ([.comments.nodes[].body // empty] | join(" ")))' \
  | grep -oE '#[0-9]+' | tr -d '#' | sort -un | head -30 || true)"
ref_json='[]'
if [[ -n $refs ]]; then
  ref_json="$(while IFS= read -r n; do
      [[ -n $n ]] || continue
      gh api "repos/${REPO}/issues/${n}" --jq '{number, title, state}' 2>/dev/null \
        || { echo "::error::failed to fetch issue ${n} from ${REPO}" >&2; exit 1; }
    done <<<"$refs" | jq -sc '.')"
fi

# ── assemble ──────────────────────────────────────────────────────────────────
jq -n \
  --argjson disc "$disc" \
  --argjson epics "$epics" \
  --argjson refs "$ref_json" \
  --arg repo "$REPO" \
  --argjson num "$DISCUSSION_NUMBER" \
  '{
     repo: $repo,
     discussion: ($disc.data.repository.discussion | {number: $num, title, body, url, category: .category.name, comments: [.comments.nodes[] | {author: .author.login, body, createdAt}]}),
     open_epics: $epics,
     referenced_issues: $refs
   }' >"$CONTEXT_PATH"

echo "context written to ${CONTEXT_PATH} (node=${node_id}, refs=$(printf '%s' "$ref_json" | jq 'length'), epics=$(printf '%s' "$epics" | jq 'length'))"
