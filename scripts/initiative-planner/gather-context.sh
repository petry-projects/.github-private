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
# Under RECONCILE=1 (#708 reconcile-in-place) we additionally bind to the epic
# already planned for this idea (via the same back-reference #598/apply-plan.sh
# key) and harvest its sub-issues — their state, labels (in-flight detection),
# and comments — so Bob can surface newly-flagged follow-ups from review/sub-issue
# threads and route them through the plan-critic acceptance gate. Read-only: this
# never mutates the epic.
#
# Emits:
#   - $CONTEXT_PATH (JSON)               the planning context
#   - DISCUSSION_NODE_ID -> $GITHUB_ENV  so apply-plan can comment back
#
# Env: REPO, DISCUSSION_NUMBER, CONTEXT_PATH (all required); GH_TOKEN;
#      RECONCILE (optional, "1" => also harvest the bound epic's sub-issues).
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
      # A referenced #N may be an issue, a PR, a Discussion, or the idea's own
      # number. Note that the GitHub issues API also returns PRs, so both issues
      # and PRs are fetched successfully. Skip anything the issues endpoint
      # can't return (404 for discussions / self-refs) instead of failing the
      # whole run; a genuine API/auth fault still surfaces via the epics query
      # above (which fails fast).
      gh api "repos/${REPO}/issues/${n}" --jq '{number, title, state}' 2>/dev/null \
        || echo "::notice::skipping referenced #${n} (not a fetchable issue/PR — discussion/self-ref)" >&2
    done <<<"$refs" | jq -sc '.')"
fi

# ── reconcile harvest (#708): the bound epic's sub-issues + comments ──────────
# Only under RECONCILE=1. Bind to the epic already planned for this idea using
# the SAME back-reference as apply-plan.sh/find_existing_epic, then harvest its
# sub-issues (open + closed) with labels and comments so Bob can pick up
# follow-ups flagged in review/sub-issue threads. Read-only; on no bound epic we
# emit an empty harvest and let apply-plan's reconcile no-op path handle it.
reconcile_json='null'
if [[ "${RECONCILE:-0}" == "1" ]]; then
  backref="Planned from idea discussion #${DISCUSSION_NUMBER}"
  bound_epic="$(gh issue list --repo "$REPO" --label initiative --state open \
    --search "\"$backref\"" --json number,body 2>/dev/null \
    | jq -r --arg ref "$backref" 'first(.[] | select((.body // "" | tostring) | contains($ref)) | .number) // empty' || true)"
  subs_json='[]'
  if [[ -n $bound_epic ]]; then
    # sub_issues returns every child regardless of state; enrich each with its
    # labels and comment thread so in-flight (dev-lead-labelled) stories are
    # distinguishable and comment-surfaced follow-ups are visible to Bob.
    # Fetch sub_issues once (paginated); --jq emits one NDJSON object per sub-issue
    # so metadata is extracted without a separate API call per sub-issue. Comments are
    # capped to the first page (no --paginate) to keep the harvest bounded (#708).
    sub_issues_meta="$(gh api "repos/${REPO}/issues/${bound_epic}/sub_issues" --paginate \
      --jq '.[] | {number, title, state, labels: [.labels[].name]}' 2>/dev/null || true)"
    if [[ -n $sub_issues_meta ]]; then
      subs_json="$(while IFS= read -r sub; do
          [[ -n $sub ]] || continue
          sn="$(jq -r '.number' <<< "$sub")"
          cmts="$(gh api "repos/${REPO}/issues/${sn}/comments" \
            --jq '[.[] | {author: .user?.login, body, createdAt: .created_at}]' 2>/dev/null || echo '[]')"
          jq -nc --argjson m "$sub" --argjson c "$cmts" '$m + {comments: $c}'
        done <<< "$sub_issues_meta" | jq -sc '.')"
    fi
    reconcile_json="$(jq -nc --argjson epic "$bound_epic" --argjson subs "$subs_json" \
      '{mode:"reconcile", epic:$epic, sub_issues:$subs}')"
  else
    echo "::warning::reconcile: no existing epic bound to idea discussion #${DISCUSSION_NUMBER} — harvesting nothing."
    reconcile_json="$(jq -nc '{mode:"reconcile", epic:null, sub_issues:[]}')"
  fi
fi

# ── assemble ──────────────────────────────────────────────────────────────────
jq -n \
  --argjson disc "$disc" \
  --argjson epics "$epics" \
  --argjson refs "$ref_json" \
  --argjson reconcile "$reconcile_json" \
  --arg repo "$REPO" \
  --argjson num "$DISCUSSION_NUMBER" \
  '{
     repo: $repo,
     discussion: ($disc.data.repository.discussion | {number: $num, title, body, url, category: .category.name, comments: [.comments.nodes[] | {author: .author.login, body, createdAt}]}),
     open_epics: $epics,
     referenced_issues: $refs,
     reconcile: $reconcile
   }' >"$CONTEXT_PATH"

echo "context written to ${CONTEXT_PATH} (node=${node_id}, refs=$(printf '%s' "$ref_json" | jq 'length'), epics=$(printf '%s' "$epics" | jq 'length')$(if [[ "${RECONCILE:-0}" == "1" ]]; then printf ', reconcile_subs=%s' "$(printf '%s' "$reconcile_json" | jq '.sub_issues | length')"; fi))"
