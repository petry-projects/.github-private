#!/usr/bin/env bash
# bot-comment-retry.sh — retry a lost fix-bot-comment pass for an undispositioned
# registered reviewer-bot PR issue comment (#2017).
#
# WHY THIS EXISTS
#   A registered bot's PR issue comment is dispositioned ONLY by dev-lead's
#   fix-bot-comment intent, and the maintainer-comment gate withholds approval
#   until it is (#1813). Every PR event shares one concurrency lane
#   (dev-lead-pr-<N>), and GitHub keeps at most ONE pending run per group: a burst
#   of bot comments right after a PR opens supersedes the pending fix-bot-comment
#   runs before they start (#2009: the CodeRabbit and CodeAnt runs were cancelled
#   with zero steps while the `opened` run held the lane). Nothing retried them, so
#   the PR sat green behind the gate until a human @mentioned dev-lead.
#
#   The comment still exists, so — unlike on-mention's USER_INSTRUCTION — its
#   context CAN be reconstructed: the retry pass re-fetches it by node id.
#
# WHAT THIS LIBRARY DECIDES (bcr_retry_decisions, PURE — no gh/network)
#   For each candidate comment — authored by a trusted registered reviewer bot,
#   not agent-marked, not minimized RESOLVED, not cleared by its source's
#   info_status_pattern (the same filters the gate applies) — whether to dispatch
#   a fix-bot-comment retry now. A comment's VERSION is lastEditedAt // createdAt;
#   all coverage checks are against the current version, so an edit re-opens it.
#     dispositioned            a `dev-lead:comment-disposition id=<id>` reply exists
#                              at/after the version → covered, nothing to do
#     pass-completed           a fix-bot-comment pass already ended on this version
#                              (its terminal marker carries `comment=<id>`) without
#                              a disposition → do not loop; only an edit re-opens
#     retry-pending            a retry marker for this version is younger than the
#                              pending window → that retry may still be queued or
#                              running; never duplicate it
#     retry-attempts-exhausted this version already had MAX retry attempts
#     grace-period             the comment is too new — the original event-driven
#                              run may still be pending or running
#     (dispatch)               otherwise, as attempt <previous attempts + 1>
#
#   Only markers from a trusted author association (OWNER/MEMBER/COLLABORATOR —
#   our own automation) count, so an outside commenter can neither forge a
#   disposition that suppresses the retry nor a marker that blocks it (CWE-863).
#
# SECURITY: nothing here (or in the sweep that uses it) minimizes or resolves a
#   comment. A retry only causes dev-lead to post a disposition, which the harness
#   then verifies as usual (resolve_dispositioned_comments). The gate is unchanged.
#
# Tunables (env):
#   BOT_COMMENT_RETRY_MIN_AGE_SEC   grace for the original run (default 900 = 15 min)
#   BOT_COMMENT_RETRY_PENDING_SEC   how long a dispatched retry is treated as still
#                                   pending/running (default 9000 = 150 min: the
#                                   dispatch job's 120-min timeout plus queue time)
#   BOT_COMMENT_RETRY_MAX_ATTEMPTS  retries per comment version (default 2)

# The gate's agent-marker regex and info-status registry reader — one source of
# truth for "which comments need a disposition" (#1813 / #1918). Source the gate
# library only if the caller has not already (its marker regex is readonly).
if [ -z "${_MAINTAINER_GATE_AGENT_MARKERS:-}" ]; then
  # shellcheck source=maintainer-comment-gate.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/maintainer-comment-gate.sh"
fi

BCR_RETRY_MARKER_NAME="dev-lead-bot-comment-retry"

# bcr_retry_decisions <comments_json> <trusted_bots_csv> <info_patterns_json> <now_epoch>
#   <comments_json>      the PR's issue-comment nodes, each {id, author{login},
#                        authorAssociation, body, createdAt, lastEditedAt,
#                        isMinimized, minimizedReason} (bcr_fetch_pr_comments)
#   <trusted_bots_csv>   registered bots dev-lead acts on ("coderabbitai[bot],…";
#                        the [bot] suffix is optional)
#   <info_patterns_json> {bare_login: info_status_pattern} (may be "{}")
#   <now_epoch>          current time, unix seconds
# Echoes a compact JSON array, oldest comment first, of
#   {id, login, version, attempt, decision: "dispatch"|"skip", reason}
# Returns non-zero (and echoes nothing) when the input cannot be evaluated, so a
# caller fails closed rather than dispatching on a misread.
bcr_retry_decisions() {
  local comments="${1:-}" trusted_csv="${2:-}" info_patterns="${3:-}" now_epoch="${4:-}"
  [ -n "$info_patterns" ] || info_patterns='{}'
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
  local min_age="${BOT_COMMENT_RETRY_MIN_AGE_SEC:-900}"
  local pending="${BOT_COMMENT_RETRY_PENDING_SEC:-9000}"
  local max_attempts="${BOT_COMMENT_RETRY_MAX_ATTEMPTS:-2}"
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=900
  [[ "$pending" =~ ^[0-9]+$ ]] || pending=9000
  [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=2

  printf '%s' "$comments" | jq -ce \
    --arg markers "$_MAINTAINER_GATE_AGENT_MARKERS" \
    --arg trusted "$trusted_csv" \
    --arg retry_name "$BCR_RETRY_MARKER_NAME" \
    --argjson info "$info_patterns" \
    --argjson now "$now_epoch" \
    --argjson min_age "$min_age" \
    --argjson pending "$pending" \
    --argjson max_attempts "$max_attempts" '
    def bare: if endswith("[bot]") then .[0:-5] else . end;
    def epoch: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601);
    # Attribute strings of every <!-- <name> ... --> marker in this comment body.
    def markers($name): [ (.body // "") | scan("<!--\\s*" + $name + "\\s+([^>]*?)\\s*-->") | .[0] ];
    def attr($k): [ scan("(?:^|\\s)" + $k + "=(\\S+)") | .[0] ] | first // null;

    if type != "array" then error("comments must be an array") else . end
    | ($trusted | split(",") | map(gsub("^\\s+|\\s+$"; "") | bare) | map(select(length > 0))) as $tb
    # Our own automation: trusted association only (never login — the agent posts
    # as the human owner, and an outside commenter must not be able to forge one).
    | [ .[] | objects
        | select(((.authorAssociation // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) != null)
        | {t: (.createdAt | epoch),
           disp: markers("dev-lead:comment-disposition"),
           pass: (markers("dev-lead-fix-reviews") | map(select(attr("intent") == "fix-bot-comment"))),
           retry: markers($retry_name)} ] as $notes
    | [ .[] | objects
        | (.author?.login // "" | tostring | bare) as $l
        | select($l != "" and ($tb | index($l)) != null)
        | select(((.body // "") | test($markers)) | not)
        | select(($info[$l] // null) as $p | ($p == null) or (((.body // "") | test($p)) | not))
        | select(((.isMinimized // false) == true
                  and ((.minimizedReason // "") | ascii_downcase) == "resolved") | not)
        | .id as $id
        | (.lastEditedAt // .createdAt) as $ver
        | ($ver | epoch) as $vt
        | ([ $notes[] | select(.t >= $vt) | .disp[] | select(attr("id") == $id) ] | length > 0) as $covered
        | ([ $notes[] | select(.t >= $vt) | .pass[] | select(attr("comment") == $id) ] | length > 0) as $ran
        | [ $notes[] | .t as $t | .retry[]
            | select(attr("id") == $id and ((attr("version") // "") | (try epoch catch null)) == $vt)
            | {t: $t, attempt: ((attr("attempt") // "0") | tonumber? // 0)} ] as $retries
        | ([ $retries[].attempt ] + [ ($retries | length) ] | max) as $attempts
        | ([ $retries[].t ] | max) as $last_retry
        | {id: $id, login: $l, version: $ver, created: .createdAt, attempt: ($attempts + 1)}
        + ( if $covered then {decision: "skip", reason: "dispositioned"}
            elif $ran then {decision: "skip", reason: "pass-completed"}
            elif ($last_retry != null and ($now - $last_retry) < $pending)
              then {decision: "skip", reason: "retry-pending"}
            elif $attempts >= $max_attempts then {decision: "skip", reason: "retry-attempts-exhausted"}
            elif ($now - $vt) < $min_age then {decision: "skip", reason: "grace-period"}
            else {decision: "dispatch", reason: "undispositioned"}
            end )
      ]
    | sort_by(.created) | map(del(.created))
  ' 2>/dev/null
}

# bcr_fetch_pr_comments <repo> <pr_number>
#   Echo every PR issue-comment node (paginated GraphQL) as one JSON array with
#   the fields bcr_retry_decisions reads. Returns 1 (echoing nothing) on any API or
#   parse failure — a partial list could hide a disposition, so callers fail closed.
bcr_fetch_pr_comments() {
  local repo="$1" pr="$2"
  # shellcheck disable=SC2016  # $owner/$repo/$pr/$cursor are GraphQL variables
  local query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        comments(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{ id author{login} authorAssociation body createdAt lastEditedAt isMinimized minimizedReason }
        }
      }
    }
  }'
  local all='[]' cursor="" has_next="true" page nodes
  local cursor_args=()
  while [ "$has_next" = "true" ]; do
    page=$(gh api graphql -f query="$query" -F owner="${repo%%/*}" -F repo="${repo##*/}" \
      -F pr="$pr" "${cursor_args[@]}" 2>/dev/null) || return 1
    # Fail closed on a partial response: any GraphQL error, a missing comments
    # connection, or a non-boolean hasNextPage means the snapshot is unreadable.
    printf '%s' "$page" | jq -e '(.errors // null) == null
      and (.data.repository.pullRequest.comments.pageInfo.hasNextPage | type) == "boolean"' \
      >/dev/null 2>&1 || return 1
    nodes=$(printf '%s' "$page" | jq -ce '.data.repository.pullRequest.comments.nodes | arrays' 2>/dev/null) \
      || return 1
    all=$(jq -cn --argjson a "$all" --argjson b "$nodes" '$a + $b') || return 1
    has_next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage')
    cursor=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor // ""')
    # More pages promised but no cursor to fetch them: the list is incomplete.
    if [ "$has_next" = "true" ] && [ -z "$cursor" ]; then return 1; fi
    cursor_args=(-f "cursor=${cursor}")
  done
  printf '%s\n' "$all"
}

# bcr_retry_marker <comment_id> <version> <attempt> <now_iso>
#   The hidden dedup marker the sweep posts BEFORE dispatching. It carries the
#   `dev-lead` prefix, so the maintainer-comment gate never counts it as a finding.
bcr_retry_marker() {
  printf '<!-- %s id=%s version=%s attempt=%s at=%s -->' \
    "$BCR_RETRY_MARKER_NAME" "$1" "$2" "$3" "$4"
}
