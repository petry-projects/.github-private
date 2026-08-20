#!/usr/bin/env bash
# Maintainer review-thread gate (issue #1415)
#
# The review-path sibling of the #1290 issue-comment gate. On a dev-lead-authored
# PR, dev-lead acts as the owner `don-petry` (AGENTS.md "Agent identity & credential
# secrets"; #1316 set this on purpose) — the *same* account a human maintainer
# uses. That shared identity removes both of the owner's mechanically-blocking
# review paths on a dev-lead PR:
#   1. CHANGES_REQUESTED is refused ("Can not request changes on your own pull
#      request"), and
#   2. the inline-review-thread fallback is defeated because the agent can resolve
#      the maintainer's own threads (observed on PR #1413: four threads first-
#      authored by don-petry, all resolvedBy: don-petry, auto-merge enabled).
#
# Because login alone cannot separate the agent from the maintainer here, this gate
# keys on the **automation marker** in a thread's originating comment — exactly the
# discriminator maintainer-comment-gate.sh uses on the issue-comment path. It has
# two parts:
#
#   review_thread_is_agent_authored <originating_comment_body>
#     The pure resolve-guard classifier. 0 = the comment carries one of our markers
#     → the thread is ours → the agent may resolve it; 1 = marker-less (or
#     undeterminable) → a maintainer finding → the agent must NOT resolve it. This
#     is what dev-lead-fix-reviews.sh consults before calling resolveReviewThread.
#
#   check_maintainer_review_threads <threads_json> <head_committer_date_iso> [bot_user]
#     The pr-review approval gate. Withholds approval while an UNRESOLVED maintainer
#     review thread postdates the last push, mirroring the issue-comment gate. It
#     clears the #1290 way: a commit pushed at/after the finding marks it addressed,
#     and a human resolving the thread also clears it. Human-resolution is a safe
#     clear precisely because the resolve-guard above prevents the agent from
#     resolving a marker-less thread — the two halves are coupled (see
#     docs/pr-review-agent/maintainer-comment-gate.md and
#     docs/agentic-interaction-model.md §7 rule 2 extended to review/merge gates).
#
# Both checks FAIL CLOSED (the #1290/#1415 posture): an inability to determine
# authorship or addressed-state must block, never read as "no findings".
#
# check_maintainer_review_threads returns:
#   0 = no unaddressed maintainer review thread (none exist, all are ours/bots,
#       resolved, or a fix was pushed at/after the finding)
#   1 = an unaddressed maintainer review thread postdates the last push, OR its
#       authorship/created/push-time is undeterminable (fail closed) → withhold
#       approval
#   2 = the threads snapshot could not be evaluated (malformed) → fail closed
#
# The gate is pure jq (no gh/network). mrtg_fetch_review_threads() is the thin gh
# helper the caller uses to obtain <threads_json>; the head-commit push time is
# obtained via maintainer_gate_head_committer_date() from the sibling issue-comment
# gate (same cherry-pick-safe committer.date semantics).

set -euo pipefail

# Authors that are never maintainers: advisory/review bots (already gated by
# advisory-review-gate.sh) and generic automation accounts. Kept identical to the
# issue-comment gate so the two paths exclude the same set. The agent's own login
# is excluded separately via the bot_user argument. Fail-closed principle: anything
# NOT on this list and NOT carrying one of our markers is treated as a human
# maintainer, so an unknown author blocks rather than slips.
# shellcheck disable=SC2034
declare -ar MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS=(
  gemini-code-assist
  copilot-pull-request-reviewer
  sonarqubecloud
  chatgpt-codex-connector
  coderabbitai
  github-actions
  "github-actions[bot]"
  dependabot
  "dependabot[bot]"
)

# JSON array form of the excluded-bot list, built lazily on first use so jq
# execution (and any failure) happens inside the gate function where it is caught
# and can fail closed.
_MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS_JSON=""

# Regex (case-sensitive) matching the HTML markers our own automation stamps into
# comment bodies — pr-review reviews/acks (`<!-- pr-review-agent ... -->`,
# `<!-- persona:pr-review -->`), dev-lead notes (`<!-- dev-lead ... -->`), and the
# dependency-advisory pass (`<!-- dependency-advisory -->`). A comment carrying any
# of these is ours, never a maintainer finding. Identical to the issue-comment
# gate's marker set (the discriminator is deliberately shared across both paths).
readonly _MAINTAINER_REVIEW_GATE_AGENT_MARKERS='<!-- (pr-review-agent|persona:|dev-lead|dependency-advisory)'

# Addressed-marker (#1547): the stable HTML marker dev-lead stamps into a review-thread
# REPLY when it has ADDRESSED that thread's finding (fix applied or verified live at
# head). It is distinct from the generic `<!-- dev-lead -->` note marker above so a
# neutral note or a *skip* reply is never mistaken for an addressed one. The script-side
# safety net (resolve_addressed_bot_threads in dev-lead-fix-reviews.sh) resolves a
# bot-originated thread whose LAST reply carries this marker — the exact class of thread
# that, during the 2026-08-18 sweep, sat replied-to ("Applied in …") but UNRESOLVED and
# silently blocked merge under every pr-quality ruleset's required_review_thread_resolution.
readonly _DEV_LEAD_ADDRESSED_MARKER='<!--[[:space:]]*dev-lead:addressed'

log_review_gate_info() {
  echo "[maintainer-review-gate] $*" >&2
}

log_review_gate_warn() {
  echo "[maintainer-review-gate] WARNING: $*" >&2
}

# review_thread_is_agent_authored <originating_comment_body>
#   The resolve-guard classifier. Returns 0 when the body carries one of our
#   automation markers (the thread is ours → resolvable by the agent), 1 otherwise
#   (marker-less → a maintainer finding the agent must NOT resolve). An empty or
#   undeterminable body returns 1 (fail closed: never resolve what we can't prove
#   is ours). Pure — no gh/network, no jq.
review_thread_is_agent_authored() {
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    return 1
  fi
  if [[ "$body" =~ $_MAINTAINER_REVIEW_GATE_AGENT_MARKERS ]]; then
    return 0
  fi
  return 1
}

# review_reply_is_addressed_marker <reply_comment_body>
#   The addressed-marker classifier (#1547). Returns 0 when <body> carries the
#   dev-lead addressed-marker (`<!-- dev-lead:addressed -->`, whitespace-tolerant) —
#   the reply confirms the finding was addressed at head, so a bot thread ending in
#   this reply is safe for the safety net to resolve. Returns 1 otherwise (marker-less
#   or empty → not a confirmed-addressed reply, e.g. a skip note; leave the thread
#   open). Pure — no gh/network, no jq.
review_reply_is_addressed_marker() {
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    return 1
  fi
  if [[ "$body" =~ $_DEV_LEAD_ADDRESSED_MARKER ]]; then
    return 0
  fi
  return 1
}

# review_thread_login_is_excluded_bot <login>
#   Returns 0 when <login> is one of the advisory/automation accounts that are never
#   maintainers (MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS), 1 otherwise. This lets the
#   resolve-guard (dev-lead side) use the SAME maintainer definition as
#   check_maintainer_review_threads (pr-review side): an advisory-bot thread is not a
#   maintainer finding, so it stays freely agent-resolvable (e.g. an outdated
#   coderabbit/codex thread). Only a marker-less thread from a NON-excluded author is
#   a maintainer finding the agent must not resolve. Login is matched verbatim; the
#   caller passes an already `[bot]`-suffix-stripped login (GraphQL author.login
#   omits the suffix), and the list carries both forms for safety.
review_thread_login_is_excluded_bot() {
  local login="${1:-}"
  if [[ -z "$login" ]]; then
    return 1
  fi
  local b
  for b in "${MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS[@]}"; do
    [[ "$login" == "$b" ]] && return 0
  done
  return 1
}

# mrtg_fetch_review_threads <pr_url>
#   Echo a JSON object {"reviewThreads":[ ...nodes ]} for the PR's review threads,
#   each node shaped {isResolved, comments:{nodes:[{author:{login}, body,
#   createdAt}]}} — exactly what check_maintainer_review_threads consumes. Echoes
#   empty string on any API failure; the caller treats empty/malformed as fail
#   closed. Fetches up to 100 threads (GraphQL single-page max); emits an operator-
#   visible warning when pageInfo.hasNextPage is true so the operator can detect
#   when a PR exceeds the cap and threads beyond page 1 are not evaluated.
mrtg_fetch_review_threads() {
  local pr_url="${1:-}"
  if [[ -z "$pr_url" ]]; then
    return 0
  fi
  # shellcheck disable=SC2016  # $url is a GraphQL variable placeholder, not shell
  local _gql='query($url:URI!){resource(url:$url){...on PullRequest{reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved comments(first:1){nodes{author{login} body createdAt}}}}}}}'
  local _raw
  _raw=$(gh api graphql -f query="$_gql" -f url="$pr_url" 2>/dev/null) || true
  [[ -z "$_raw" ]] && return 0
  local _has_next
  _has_next=$(printf '%s' "$_raw" | jq -r '.data?.resource?.reviewThreads?.pageInfo?.hasNextPage // false' 2>/dev/null) || true
  if [[ "$_has_next" == "true" ]]; then
    log_review_gate_warn "PR has >100 review threads — pages beyond the first are not fetched; a maintainer finding in a later page would not block approval. Consider paginating."
  fi
  printf '%s' "$_raw" | jq '{reviewThreads: (.data?.resource?.reviewThreads?.nodes // [])}' 2>/dev/null || true
}

# check_maintainer_review_threads <threads_json> <head_committer_date_iso> [bot_user]
check_maintainer_review_threads() {
  local json="${1:-}"
  local head_date="${2:-}"
  local bot_user="${3:-donpetry-bot}"

  if [[ -z "$json" ]]; then
    log_review_gate_warn "review-threads snapshot is empty — failing closed (blocking approval)"
    return 2
  fi

  # Build excluded-bots JSON lazily on first use so jq execution stays inside the
  # function where errors are caught and the gate can fail closed.
  if [[ -z "$_MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS_JSON" ]]; then
    _MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS_JSON=$(jq -n '$ARGS.positional' --args "${MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS[@]}") \
      || {
        log_review_gate_warn "could not build excluded-bots list — failing closed (blocking approval)"
        return 2
      }
  fi

  # Classify every thread as "ok" (not a blocking maintainer finding) or "block".
  # A thread blocks when it is a maintainer thread (author not the agent's own login
  # and not an excluded advisory bot) AND it is unaddressed: not resolved, and no
  # commit was pushed at/after the finding. Body markers are NOT used to determine
  # maintainer authorship — a user-controlled field is not a server-verifiable record.
  # Undeterminable originating comment / createdAt / push-time all fail closed to "block".
  #
  # A jq failure here (malformed snapshot) exits non-zero → return 2 so
  # undeterminable input fails closed rather than reading as "no findings".
  local blockers
  blockers=$(printf '%s' "$json" | jq -r \
    --arg botuser "$bot_user" \
    --argjson bots "$_MAINTAINER_REVIEW_GATE_EXCLUDED_BOTS_JSON" \
    --arg headdate "$head_date" '
      def is_maintainer($c):
        ($c.author?.login // "" | tostring) as $l
        | ($l != $botuser)
          and (($bots | index($l)) == null);
      ($headdate | if . == "" then null else (try fromdateiso8601 catch null) end) as $head
      | [ (.reviewThreads // [])[] | objects
          | (.comments.nodes[0]? // null) as $c
          | if $c == null then "block"
            elif (is_maintainer($c) | not) then "ok"
            elif (.isResolved == true) then "ok"
            else
              (($c.createdAt // "") | if . == "" then null else (try fromdateiso8601 catch null) end) as $created
              | if $created == null then "block"
                elif $head == null then "block"
                elif ($created <= $head) then "ok"
                else "block" end
            end
        ]
      | map(select(. == "block")) | length
    ' 2>/dev/null) || {
    log_review_gate_warn "could not parse review-threads snapshot — failing closed (blocking approval)"
    return 2
  }

  # Empty output (no reviewThreads key at all, jq produced nothing) is treated as
  # undeterminable → fail closed rather than as "no findings".
  if [[ -z "$blockers" ]]; then
    log_review_gate_warn "review-threads snapshot produced no verdict — failing closed (blocking approval)"
    return 2
  fi

  if [[ "$blockers" -eq 0 ]]; then
    log_review_gate_info "no unaddressed maintainer review threads"
    return 0
  fi

  log_review_gate_warn "$blockers unaddressed maintainer review thread(s) postdate the last push (or are undeterminable) — withholding approval (#1415)"
  return 1
}

# Run standalone against a PR URL (only if executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  _pr_url="${1:-}"
  if [[ -z "$_pr_url" ]]; then
    echo "usage: maintainer-review-thread-gate.sh <pr-url>" >&2
    exit 2
  fi
  # The head-commit push time comes from the sibling issue-comment gate's helper
  # (same committer.date semantics); source it only in this standalone path so the
  # library remains hermetic when sourced.
  # shellcheck source=maintainer-comment-gate.sh
  source "$(dirname "${BASH_SOURCE[0]}")/maintainer-comment-gate.sh"
  _threads=$(mrtg_fetch_review_threads "$_pr_url")
  _hd=$(maintainer_gate_head_committer_date "$_pr_url")
  check_maintainer_review_threads "$_threads" "$_hd" "${BOT_USER:-donpetry-bot}"
  exit $?
fi
