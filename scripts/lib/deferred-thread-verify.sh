#!/usr/bin/env bash
# deferred-thread-verify.sh — the pure verifier for the dev-lead review-thread
# DEFERRAL marker (#2045).
#
# WHY THIS EXISTS
#   A bot review thread whose finding dev-lead judged valid but out of scope had no
#   outcome. The addressed-marker (+ verified claim, #1692) is reserved for a real
#   fix, a skip note carries no marker, and the agent may not resolve threads. So a
#   deferred thread stayed unresolved forever and, under
#   required_review_thread_resolution, blocked merge (PR #1953: five Codex threads
#   replied "Valid, but deferring — out of scope" and were hand-resolved). PR issue
#   comments already had this outcome — `disposition=out-of-scope ref=#<n>`
#   (comment-disposition-verify.sh, #1813) — and this is its review-thread sibling.
#
# THE MARKER (normative — the single source of truth)
#   dev-lead's reply on the bot thread ends with exactly one
#
#     <!-- dev-lead:deferred ref=#<n> -->
#
#   where #<n> is the repo's single deferred-findings tracking issue (AC6: one per
#   repo, shared with the issue-comment `out-of-scope` disposition). The harness
#   (resolve_deferred_bot_threads in dev-lead-fix-reviews.sh) resolves the thread
#   only when that issue exists, is an open issue (not a PR), and its body or one of
#   its comments links this thread. The `<!-- dev-lead` prefix also makes the reply
#   agent-authored to review_thread_is_agent_authored, so it is never mistaken for a
#   maintainer finding.
#
# PURITY / TESTABILITY
#   Every dtv_* function is PURE: no gh/git/network. The caller fetches the thread
#   and the tracking issue and passes them in. Sourced under `set -euo pipefail`, so
#   the helpers only `return`, never `exit`, and fail closed on every ambiguity.

set -euo pipefail

readonly _DTV_MARKER_PREFIX='<!-- dev-lead:deferred'
readonly _DTV_MARKER_SUFFIX='-->'
readonly _DTV_TRACKER_TITLE='dev-lead: deferred review findings'

# dtv_parse_deferral <reply_body>
#   Extract the tracking-issue number from the single deferral marker in a reply.
#   On success echoes the bare issue number (e.g. "2050") and returns 0. On failure
#   echoes a reason token and returns 1: no-deferral | multiple-deferrals |
#   malformed | missing-ref | bad-ref. A ref must be exactly `#<n>` in this repo;
#   a repeated `ref=` key is ambiguous and rejected. Pure.
dtv_parse_deferral() {
  local body="${1:-}"
  local count
  count=$( { grep -oF "$_DTV_MARKER_PREFIX" <<<"$body" || true; } | wc -l | tr -d '[:space:]')
  if [[ "$count" == "0" ]]; then
    echo "no-deferral"
    return 1
  fi
  if [[ "$count" != "1" ]]; then
    echo "multiple-deferrals"
    return 1
  fi

  local rest attrs
  rest="${body#*"$_DTV_MARKER_PREFIX"}"
  # The prefix must be followed by whitespace or the closing `-->` directly, so a
  # different marker such as `<!-- dev-lead:deferredX … -->` is not accepted.
  if [[ ! "$rest" =~ ^([[:space:]]|-->) ]] || [[ "$rest" != *"$_DTV_MARKER_SUFFIX"* ]]; then
    echo "malformed"
    return 1
  fi
  attrs=" ${rest%%"$_DTV_MARKER_SUFFIX"*}"
  # The marker must END the reply: only whitespace may follow its closing `-->`.
  local trailing="${rest#*"$_DTV_MARKER_SUFFIX"}"
  if [[ "$trailing" =~ [^[:space:]] ]]; then
    echo "malformed"
    return 1
  fi

  local refs
  refs=$( { grep -oE '[[:space:]]ref=[^[:space:]]*' <<<"$attrs" || true; } | wc -l | tr -d '[:space:]')
  if [[ "$refs" == "0" ]]; then
    echo "missing-ref"
    return 1
  fi
  if [[ "$refs" != "1" ]]; then
    echo "bad-ref"
    return 1
  fi
  # The WHOLE attribute region must be exactly one `ref=#<n>`; stray tokens fail.
  if [[ "$attrs" =~ ^[[:space:]]+ref=#([1-9][0-9]*)[[:space:]]*$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "bad-ref"
  return 1
}

# dtv_latest_own_reply_index <comments_json> <bot_user>
#   Echo the 0-based index of the LATEST comment in the thread authored by our
#   account (bot_user or its [bot]-stripped form, since GraphQL omits the suffix)
#   and return 0. Return 1 when our account never replied. The deferral is judged
#   on this reply only: a later reply of ours (e.g. a fix) supersedes an earlier
#   deferral. Pure.
dtv_latest_own_reply_index() {
  local comments_json="${1:-}" bot_user="${2:-}"
  local bot_user_stripped="${bot_user%\[bot\]}"
  [[ -z "$bot_user" ]] && return 1
  local idx
  idx=$(jq -r --arg u "$bot_user" --arg s "$bot_user_stripped" '
      if type == "array" then
        to_entries
        | map(select((.value.author.login // "") as $l | $l == $u or $l == $s))
        | last | .key // ""
      else "" end
    ' <<<"$comments_json" 2>/dev/null) || return 1
  [[ -n "$idx" ]] || return 1
  echo "$idx"
}

# dtv_text_mentions_thread <text> <thread_id> <origin_database_id> [<owner/repo> <pr_number>]
#   0 when <text> links the review thread: it names the thread node id
#   (`PRRT_…`) or the originating comment's anchor `discussion_r<databaseId>` inside a
#   review-comment URL (`…/pull/<n>#discussion_r<id>`; bare prose tokens don't count). Matches are bounded so `discussion_r12` does
#   not match `discussion_r123`. An identifier with an unexpected shape is ignored
#   rather than used as a pattern; with neither identifier usable this returns 1.
#   When <owner/repo> and <pr_number> are given, the URL must point at exactly that
#   repository and pull request. Pure.
dtv_text_mentions_thread() {
  local text="${1:-}" thread_id="${2:-}" db_id="${3:-}" repo="${4:-}" pr="${5:-}"
  [[ -z "$text" ]] && return 1
  if [[ "$thread_id" =~ ^[A-Za-z0-9_=-]+$ ]] \
     && [[ "$text" =~ (^|[^A-Za-z0-9_=-])${thread_id}([^A-Za-z0-9_=-]|$) ]]; then
    return 0
  fi
  if [[ "$db_id" =~ ^[1-9][0-9]*$ ]]; then
    local url_re='/pull/[0-9]+#discussion_r'
    if [[ -n "$repo" || -n "$pr" ]]; then
      # Scoped: unusable repo/PR identifiers never fall back to the loose match.
      [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
      url_re="github\\.com/${repo//./\\.}/pull/${pr}#discussion_r"
    fi
    if [[ "$text" =~ ${url_re}${db_id}([^0-9A-Za-z_]|$) ]]; then
      return 0
    fi
  fi
  return 1
}

# dtv_verify_tracking_issue <issue_json> <issue_comments_json> <thread_id> <origin_database_id> [<owner/repo> <pr_number>]
#   Decide whether the tracking issue a deferral cites can back resolution.
#   <issue_json> is the REST issue object (number, state, body, pull_request?);
#   <issue_comments_json> is the REST array of its comments ({body}). Echoes "ok"
#   and returns 0 when the issue is an OPEN ISSUE (not a pull request) whose body or
#   any comment links the thread (dtv_text_mentions_thread). Otherwise echoes a
#   reason and returns 1: missing | not-an-issue | wrong-title | closed | no-mention.
#   The issue must carry the exact shared-tracker title
#   `dev-lead: deferred review findings` (AC6), never a per-finding issue. An empty or
#   unparseable <issue_json> (a failed or 404 fetch) reads as missing; unparseable
#   comments read as none. Pure.
dtv_verify_tracking_issue() {
  local issue_json="${1:-}" comments_json="${2:-}" thread_id="${3:-}" db_id="${4:-}"
  local repo="${5:-}" pr="${6:-}"
  local facts
  facts=$(jq -c '
      if type == "object" and ((.number // null) | type) == "number" then
        {kind: (if has("pull_request") and .pull_request != null then "pr" else "issue" end),
         state: ((.state // "") | ascii_downcase),
         title: (.title // ""),
         body: (.body // "")}
      else empty end
    ' <<<"$issue_json" 2>/dev/null || true)
  if [[ -z "$facts" ]]; then
    echo "missing"
    return 1
  fi
  local kind state
  kind=$(jq -r '.kind' <<<"$facts" 2>/dev/null) || kind=""
  state=$(jq -r '.state' <<<"$facts" 2>/dev/null) || state=""
  if [[ "$kind" != "issue" ]]; then
    echo "not-an-issue"
    return 1
  fi
  local title
  title=$(jq -r '.title' <<<"$facts" 2>/dev/null) || title=""
  if [[ "$title" != "$_DTV_TRACKER_TITLE" ]]; then
    echo "wrong-title"
    return 1
  fi
  if [[ "$state" != "open" ]]; then
    echo "closed"
    return 1
  fi
  local text
  text=$(jq -r '.body' <<<"$facts")
  if dtv_text_mentions_thread "$text" "$thread_id" "$db_id" "$repo" "$pr"; then
    echo "ok"
    return 0
  fi
  local comment_text
  comment_text=$(jq -r 'if type == "array" then .[] | objects | (.body // "") else empty end' \
    <<<"${comments_json:-[]}" 2>/dev/null || true)
  if dtv_text_mentions_thread "$comment_text" "$thread_id" "$db_id" "$repo" "$pr"; then
    echo "ok"
    return 0
  fi
  echo "no-mention"
  return 1
}
