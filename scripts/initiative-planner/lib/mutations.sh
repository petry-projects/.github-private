#!/usr/bin/env bash
# mutations.sh — GitHub issue/sub-issue/dependency mutations for the initiative
# planner, with a DRY_RUN switch. Mirrors the feature-ideation
# discussion-mutations.sh contract: when DRY_RUN=1 every mutating call logs a
# structured "planned action" JSONL entry instead of touching GitHub, so the
# planner can be smoke-tested and audited before it writes anything.
#
# Native GitHub APIs used (verified against this repo's existing epics):
#   - sub-issues:    POST repos/{repo}/issues/{epic}/sub_issues   {sub_issue_id}
#   - dependencies:  POST repos/{repo}/issues/{n}/dependencies/blocked_by {issue_id}
# Both take the issue's REST id (not its number); create_issue returns both.
#
# IMPORTANT: this library NEVER applies the `initiative:auto` label. Activation
# of auto-implementation is a deliberate human step (see apply-plan.sh).
#
# Env:
#   DRY_RUN      "1" => log instead of execute
#   DRY_RUN_LOG  JSONL log path (default: ./dry-run.jsonl)
#   GH_TOKEN     required when not in DRY_RUN (gh reads it)

set -euo pipefail

_is_dry_run() { [[ "${DRY_RUN:-0}" == "1" ]]; }

_dry_log() {
  printf '%s\n' "$1" >>"${DRY_RUN_LOG:-./dry-run.jsonl}"
}

# Synthetic, monotonically-increasing number/id for dry runs so blocked_by edges
# still thread distinct values. Backed by a file (not a shell var) because
# create_issue is called inside process-substitution subshells, where a mutated
# global would not persist back to the caller.
_next_dry_id() {
  local f="${DRY_RUN_LOG:-./dry-run.jsonl}.seq" n
  n="$(cat "$f" 2>/dev/null || printf '900000')"
  n=$((n + 1))
  printf '%s' "$n" >"$f"
  printf '%s' "$n"
}

# create_issue <repo> <title> <body> <labels_csv>
# Prints "<number> <id>" (space-separated) on stdout.
create_issue() {
  if [[ "$#" -ne 4 ]]; then
    printf '[create_issue] expected 4 args (repo title body labels_csv), got %d\n' "$#" >&2
    return 64
  fi
  local repo="$1" title="$2" body="$3" labels="$4"

  if _is_dry_run; then
    local n
    n="$(_next_dry_id)"
    _dry_log "$(jq -nc \
      --arg op create_issue --arg title "$title" --arg labels "$labels" --arg body "$body" \
      --argjson number "$n" \
      '{op:$op, number:$number, title:$title, labels:($labels|split(",")|map(select(length>0))), body:$body}')"
    printf '%s %s\n' "$n" "$n"
    return 0
  fi

  local payload resp number id
  payload="$(jq -nc --arg t "$title" --arg b "$body" --arg l "$labels" \
    '{title:$t, body:$b, labels:($l|split(",")|map(select(length>0)))}')"
  resp="$(printf '%s' "$payload" | gh api "repos/${repo}/issues" -X POST --input -)"
  number="$(printf '%s' "$resp" | jq -r '.number')"
  id="$(printf '%s' "$resp" | jq -r '.id')"
  printf '%s %s\n' "$number" "$id"
}

# issue_id <repo> <number> — resolve an existing issue's REST id (live only).
issue_id() {
  local repo="$1" number="$2"
  gh api "repos/${repo}/issues/${number}" --jq '.id'
}

# find_existing_epic <repo> <back_reference>
# Idempotency guard: searches open `initiative` issues for an epic whose body
# already embeds <back_reference> (the "Planned from idea discussion #N" marker
# apply-plan.sh writes into every epic). Prints the matching epic number on
# stdout, or nothing when no epic exists.
#
# DRY_RUN: returns the DRY_RUN_EXISTING_EPIC stub env (empty if unset) so the
# offline bats suite can simulate both the "already planned" and "first run"
# paths without touching the network.
find_existing_epic() {
  local repo="$1" backref="$2"
  if _is_dry_run; then
    printf '%s' "${DRY_RUN_EXISTING_EPIC:-}"
    return 0
  fi
  # --search is GitHub's tokenized full-text search; re-filter with an exact
  # substring match so a tokenized hit on a different discussion can't match.
  gh issue list --repo "$repo" --label initiative --state open \
    --search "\"$backref\"" --json number,body \
    | jq -r --arg ref "$backref" 'first(.[] | select(.body | contains($ref)) | .number) // empty'
}

# link_sub_issue <repo> <epic_number> <child_id>
link_sub_issue() {
  local repo="$1" epic="$2" child_id="$3"
  if _is_dry_run; then
    _dry_log "$(jq -nc --arg op add_sub_issue \
      --argjson epic "$epic" --argjson child "$child_id" \
      '{op:$op, epic:$epic, sub_issue_id:$child}')"
    return 0
  fi
  gh api "repos/${repo}/issues/${epic}/sub_issues" -X POST -F sub_issue_id="${child_id}" >/dev/null
}

# add_blocked_by <repo> <issue_number> <blocker_number>
# Resolves the blocker's REST id at call time (live); logs by number (dry).
add_blocked_by() {
  local repo="$1" issue="$2" blocker="$3"
  if _is_dry_run; then
    _dry_log "$(jq -nc --arg op add_blocked_by \
      --argjson issue "$issue" --argjson blocker "$blocker" \
      '{op:$op, issue:$issue, blocked_by:$blocker}')"
    return 0
  fi
  local blocker_id
  blocker_id="$(issue_id "$repo" "$blocker")"
  gh api "repos/${repo}/issues/${issue}/dependencies/blocked_by" \
    -X POST -F issue_id="${blocker_id}" >/dev/null
}

# comment_on_discussion <discussion_node_id> <body>
comment_on_discussion() {
  local node_id="$1" body="$2"
  if _is_dry_run; then
    _dry_log "$(jq -nc --arg op comment_on_discussion \
      --arg id "$node_id" --arg body "$body" \
      '{op:$op, discussion_id:$id, body:$body}')"
    return 0
  fi
  gh api graphql -f query='
    mutation($id:ID!,$b:String!){ addDiscussionComment(input:{discussionId:$id, body:$b}){ comment{ url } } }
  ' -f id="$node_id" -f b="$body" --jq '.data.addDiscussionComment.comment.url'
}
