#!/usr/bin/env bash
# comment-disposition-verify.sh — the pure verifier for the dev-lead PR
# issue-comment DISPOSITION marker (#1813).
#
# WHY THIS EXISTS
#   maintainer-comment-gate.sh (#1290) judged an issue comment "addressed" by
#   comparing timestamps: a push after the comment cleared it. That is a proxy —
#   it says nothing about whether the comment's finding was read, checked, and
#   acted on, and it depended on pushedDate (now always null), so the gate failed
#   closed on every open PR (#1813). The redesign makes "addressed" mean a
#   VERIFIED DISPOSITION: dev-lead researches each comment and posts exactly one
#   evidence-backed reply carrying
#
#     <!-- dev-lead:comment-disposition id=<comment_id> disposition=<fixed|invalid|
#          out-of-scope|answered|informational> [sha=<40-hex>] [ref=#<n>] -->
#
#   and the harness verifies that disposition and then minimizes the ORIGINAL
#   comment with classifier RESOLVED (GraphQL minimizeComment). The pr-review gate
#   then treats a RESOLVED-minimized comment as addressed. This library is the
#   issue-comment sibling of addressed-claim-verify.sh (the review-thread path).
#
# PURITY / TESTABILITY
#   Every cdv_* function here is PURE: no gh/git/network. Verification of a claim
#   against the pushed diff (the `fixed` case) reuses acv_gather_commit_facts from
#   addressed-claim-verify.sh in the caller; this library only decides, from the
#   parsed disposition and a caller-supplied `verified` boolean, whether the
#   harness may resolve the comment. Sourced under `set -euo pipefail`, so the
#   helpers only `return`, never `exit`, and fail closed on every ambiguity.

set -euo pipefail

# The literal marker delimiters — one definition shared by the emitter (prompt)
# and this parser.
readonly _CDV_MARKER_PREFIX='<!-- dev-lead:comment-disposition '
readonly _CDV_MARKER_SUFFIX=' -->'

# The five sanctioned dispositions (issue #1813 Design). Any other word is
# unverifiable → parse fails closed rather than guessing.
readonly _CDV_VALID_DISPOSITIONS='fixed invalid out-of-scope answered informational'

# The post-disposition BOT-reply classification (AC7 loop safety) reuses the
# review-thread verifier's acknowledgement/finding discriminators so there is a
# single source of truth. Source it only if the caller has not already (the main
# script sources both, so this never double-sources or re-declares readonly vars).
if ! declare -F acv_bot_comment_is_acknowledgement >/dev/null 2>&1; then
  # shellcheck source=addressed-claim-verify.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/addressed-claim-verify.sh"
fi

# cdv_parse_disposition <reply_body>
#   Extract and validate the single disposition marker from a reply body. On
#   success echoes canonical compact JSON {id,disposition,sha,ref} and returns 0
#   (sha/ref are "" when absent). On any failure echoes a reason token and
#   returns 1: no-disposition | multiple-dispositions | bad-id | bad-disposition
#   | bad-sha | missing-ref. Pure — no gh/git/network.
cdv_parse_disposition() {
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    echo "no-disposition"
    return 1
  fi

  # Count markers. Zero → nothing to verify; more than one → malformed (never
  # silently pick one). `|| true` neutralises grep's no-match exit under pipefail.
  local count
  count=$( { grep -oF "$_CDV_MARKER_PREFIX" <<<"$body" || true; } | wc -l | tr -d '[:space:]')
  if [[ "$count" == "0" ]]; then
    echo "no-disposition"
    return 1
  fi
  if [[ "$count" != "1" ]]; then
    echo "multiple-dispositions"
    return 1
  fi

  # Extract the attribute string between the literal prefix and the trailing ` -->`.
  local rest attrs
  rest="${body#*"$_CDV_MARKER_PREFIX"}"
  # An unclosed marker (no trailing ` -->`) is malformed — reject it rather than
  # letting `attrs` absorb the entire remaining body and parse valid-looking keys.
  if [[ "$rest" != *"$_CDV_MARKER_SUFFIX"* ]]; then
    echo "bad-disposition"
    return 1
  fi
  attrs="${rest%%"$_CDV_MARKER_SUFFIX"*}"

  # Pull each key=value token. Keys are matched anchored so `id=` cannot capture
  # a substring of another key. A value runs to the next whitespace.
  local id disposition sha ref
  id=$(_cdv_attr "$attrs" id)
  disposition=$(_cdv_attr "$attrs" disposition)
  sha=$(_cdv_attr "$attrs" sha)
  ref=$(_cdv_attr "$attrs" ref)

  if [[ -z "$id" ]]; then
    echo "bad-id"
    return 1
  fi
  if [[ -z "$disposition" ]] || ! _cdv_is_valid_disposition "$disposition"; then
    echo "bad-disposition"
    return 1
  fi
  # `fixed` must cite a full 40-hex sha (abbreviated SHAs are rejected, matching
  # the addressed-claim contract).
  if [[ "$disposition" == "fixed" ]]; then
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "bad-sha"
      return 1
    fi
  fi
  # `out-of-scope` must cite the tracking reference it defers to.
  if [[ "$disposition" == "out-of-scope" && -z "$ref" ]]; then
    echo "missing-ref"
    return 1
  fi

  jq -c -n \
    --arg id "$id" \
    --arg disposition "$disposition" \
    --arg sha "$sha" \
    --arg ref "$ref" \
    '{id:$id, disposition:$disposition, sha:$sha, ref:$ref}' 2>/dev/null || {
    echo "bad-id"
    return 1
  }
}

# _cdv_attr <attr_string> <key>
#   Echo the value of `<key>=<value>` in a space-delimited attribute string, or
#   empty when the key is absent. Value runs to the next whitespace.
_cdv_attr() {
  local attrs="${1:-}" key="${2:-}"
  [[ -z "$key" ]] && return 0
  # Prepend a space so a leading key matches the same ` <key>=` pattern.
  local padded=" $attrs"
  if [[ "$padded" =~ [[:space:]]${key}=([^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# _cdv_is_valid_disposition <word>
#   0 when <word> is one of the five sanctioned dispositions, 1 otherwise.
_cdv_is_valid_disposition() {
  local w="${1:-}" d
  for d in $_CDV_VALID_DISPOSITIONS; do
    [[ "$w" == "$d" ]] && return 0
  done
  return 1
}

# cdv_authorize <disposition> <is_human> <verified>
#   Decide whether the harness may resolve (minimize RESOLVED) the ORIGINAL
#   comment. <is_human> and <verified> are the strings "true"/"false".
#     - <verified> is the disposition-specific verification the CALLER computed:
#         fixed        → cdv_verify_fixed (a PR commit on head, non-empty diff,
#                        authored after the finding — #2004)
#         out-of-scope → the referenced issue exists
#         invalid/answered/informational → a reply with non-empty evidence exists
#     - A human maintainer's comment is auto-resolved ONLY on a verified `fixed`
#       (AC5); any other disposition leaves it open for the human to resolve, so
#       an agent can never dismiss a person's finding by arguing with it.
#     - A bot comment is resolved on any verified disposition (AC4).
#   Returns 0 = the harness may minimize; 1 = leave the comment open. Pure.
cdv_authorize() {
  local disposition="${1:-}" is_human="${2:-}" verified="${3:-}"
  [[ "$verified" == "true" ]] || return 1
  if [[ "$is_human" == "true" ]]; then
    [[ "$disposition" == "fixed" ]] && return 0
    return 1
  fi
  return 0
}

# cdv_verify_fixed <on_head> <on_base> <own_file_count> <sha_author_date> <finding_created_at>
#   Decide whether a `fixed` disposition's cited sha is the commit that FIXED the
#   finding (#2004). The caller gathers the facts (git); this only decides.
#     <on_head>   "true" when the sha is reachable from the PR head.
#     <on_base>   "true"/"false" — reachable from origin/<base>; anything else is
#                 unknowable and fails closed.
#     <own_file_count>  files in the sha's OWN diff (0 for a merge commit).
#     <sha_author_date> / <finding_created_at>  Z-form ISO-8601 instants. The
#                 AUTHOR date is used because a rebase rewrites committer dates.
#   The fix may have landed on an EARLIER pass (an ancestor of head), so this pass
#   need not have produced it. What it must do is POSTDATE the finding: the commit
#   that introduced a defect necessarily predates the comment reporting it (the
#   PR #1977 deadlock cited exactly that commit), while its fix postdates it.
#   An issue comment has no file/line anchor (unlike a review thread), so there is
#   no path to require the sha to touch; the non-empty own diff plus the
#   postdates-finding rule is the strongest check available without guessing.
#   Echoes "verified" and returns 0, or echoes a reason token and returns 1:
#   not-on-head | on-base-branch | base-unknown | empty-diff | undated |
#   predates-finding. Pure — no gh/git/network.
cdv_verify_fixed() {
  local on_head="${1:-}" on_base="${2:-}" own_count="${3:-}" sha_date="${4:-}" finding_date="${5:-}"
  local iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  if [[ "$on_head" != "true" ]]; then
    echo "not-on-head"
    return 1
  fi
  if [[ "$on_base" == "true" ]]; then
    echo "on-base-branch"
    return 1
  fi
  if [[ "$on_base" != "false" ]]; then
    echo "base-unknown"
    return 1
  fi
  if [[ ! "$own_count" =~ ^[0-9]+$ ]] || [[ "$own_count" -eq 0 ]]; then
    echo "empty-diff"
    return 1
  fi
  if [[ ! "$sha_date" =~ $iso ]] || [[ ! "$finding_date" =~ $iso ]]; then
    echo "undated"
    return 1
  fi
  # Same-shape Z-form instants compare correctly as strings. Strictly after.
  if [[ ! "$sha_date" > "$finding_date" ]]; then
    echo "predates-finding"
    return 1
  fi
  echo "verified"
}

# cdv_select_disposition <cid> <bot_user> <comments_json>
#   Duplicate recovery / idempotency (#1992). The pre-#1992 resolver required
#   EXACTLY ONE authorized disposition per comment and failed closed on more, so
#   a comment that was dispositioned but not minimized in the same pass could
#   never converge: each later pass posted a second disposition, the resolver
#   then skipped the comment forever, and the maintainer gate deadlocked (#1952,
#   #1953). This picks ONE disposition deterministically so N authorized replies
#   collapse to one that the caller verifies + minimizes, while the rest are
#   reported as superseded for the caller to minimize OUTDATED.
#
#   Among the comments in <comments_json> (the PR's issue-comment nodes, each
#   {id, author{login,__typename}, body, isMinimized, minimizedReason, createdAt})
#   it keeps only replies that are ALL of:
#     - authored by <bot_user> (login == bot_user or its [bot]-stripped form) —
#       the authorization gate (CWE-863): a disposition from any other author
#       never counts and can never win, so an external commenter cannot smuggle a
#       marker citing a candidate id past the resolver;
#     - explicitly NOT minimized (isMinimized == false; a missing or unreadable
#       value fails closed, and a superseded reply we minimized on a prior pass
#       stops counting, so the count truly converges to one);
#     - carrying a well-formed ISO-8601 createdAt (an unreadable timestamp could
#       otherwise win the "latest" comparison, so it fails closed);
#     - parseable by cdv_parse_disposition AND citing id=<cid> (an unparseable or
#       mis-targeted marker is ignored — fail closed, never guessed).
#   Of those it selects the LATEST by createdAt, tie-broken by node id (lexical,
#   higher wins) so the choice is fully deterministic. Recommends the latest per
#   the issue, and the latest reflects dev-lead's most recent research.
#
#   Emits compact JSON and returns 0 when >=1 authorized disposition is found:
#     {auth_count:N, chosen:{id,createdAt,disposition:{…}}, superseded:[id,…]}
#   Emits {auth_count:0, chosen:null, superseded:[]} and returns 1 when none.
#   Pure — no gh/git/network (jq + cdv_parse_disposition only).
cdv_select_disposition() {
  local cid="${1:-}" bot_user="${2:-}" comments_json="${3:-}"
  if [[ -z "$cid" || -z "$comments_json" ]]; then
    echo '{"auth_count":0,"chosen":null,"superseded":[]}'
    return 1
  fi
  local bot_stripped="$bot_user"
  [[ "$bot_user" == *"[bot]" ]] && bot_stripped="${bot_user%\[bot\]}"

  # Base64-frame each candidate record so bodies with newlines/quotes survive the
  # read loop. jq does the author + not-minimized filtering; cdv_parse_disposition
  # (bash) does the per-reply parse because it is the single source of truth.
  local records
  records=$(printf '%s' "$comments_json" | jq -r \
    --arg botuser "$bot_user" --arg botstripped "$bot_stripped" '
      (.[]? // empty) | objects
      | (.author?.login // "" | tostring) as $l
      | select($l == $botuser or $l == $botstripped)
      | select(.isMinimized == false)
      | select((.createdAt // "" | tostring) | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      | {id:(.id // ""), createdAt:.createdAt, body:(.body // "")} | @base64
    ' 2>/dev/null || true)

  local auth_count=0 chosen_id="" chosen_created="" chosen_disp=""
  local superseded=()
  local rec rec_json rid rcreated rbody parsed pid newer
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    rec_json=$(printf '%s' "$rec" | base64 -d 2>/dev/null || true)
    [[ -z "$rec_json" ]] && continue
    rbody=$(printf '%s' "$rec_json" | jq -r '.body // ""' 2>/dev/null || echo "")
    rid=$(printf '%s' "$rec_json" | jq -r '.id // ""' 2>/dev/null || echo "")
    rcreated=$(printf '%s' "$rec_json" | jq -r '.createdAt // ""' 2>/dev/null || echo "")
    parsed=$(cdv_parse_disposition "$rbody" 2>/dev/null) || continue
    pid=$(printf '%s' "$parsed" | jq -r '.id // ""' 2>/dev/null || echo "")
    [[ "$pid" == "$cid" ]] || continue
    auth_count=$((auth_count + 1))
    newer="false"
    if [[ -z "$chosen_id" ]]; then
      newer="true"
    elif [[ "$rcreated" > "$chosen_created" ]]; then
      newer="true"
    elif [[ "$rcreated" == "$chosen_created" && "$rid" > "$chosen_id" ]]; then
      newer="true"
    fi
    if [[ "$newer" == "true" ]]; then
      [[ -n "$chosen_id" ]] && superseded+=("$chosen_id")
      chosen_id="$rid"
      chosen_created="$rcreated"
      chosen_disp="$parsed"
    else
      superseded+=("$rid")
    fi
  done <<< "$records"

  if [[ "$auth_count" -eq 0 ]]; then
    echo '{"auth_count":0,"chosen":null,"superseded":[]}'
    return 1
  fi

  local sup_json
  sup_json=$(printf '%s\n' "${superseded[@]:-}" | jq -R . | jq -s 'map(select(. != ""))' 2>/dev/null || echo "[]")
  jq -c -n \
    --argjson ac "$auth_count" \
    --arg cid2 "$chosen_id" \
    --arg cc "$chosen_created" \
    --argjson disp "$chosen_disp" \
    --argjson sup "$sup_json" \
    '{auth_count:$ac, chosen:{id:$cid2, createdAt:$cc, disposition:$disp}, superseded:$sup}' 2>/dev/null
}

# cdv_disposition_is_stale <comment_lastEditedAt> <disposition_createdAt>
#   Edits re-open a dispositioned comment (#2008). CodeRabbit edits ONE summary
#   comment in place, so a disposition made BEFORE the latest edit judged an older
#   body. On PR #2000 a security finding was appended about an hour after the
#   comment was dispositioned `informational` and minimized, and it was never
#   addressed. This compares the comment's lastEditedAt with the createdAt of the
#   disposition chosen by cdv_select_disposition.
#     0 = stale: edited strictly AFTER the disposition, so a fresh one is needed
#     1 = current: never edited ("" / "null"), or edited at/before the disposition
#     2 = unreadable: a timestamp that is not ISO-8601 UTC (or an empty
#         disposition time), so the caller fails closed
#   Edit timestamps are second-granular. An edit in the same second as the
#   disposition counts as seen, so a disposition is never re-opened by its own
#   race. Pure.
cdv_disposition_is_stale() {
  local edited="${1:-}" disposed="${2:-}"
  local iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  [[ "$disposed" =~ $iso ]] || return 2
  if [[ -z "$edited" || "$edited" == "null" ]]; then
    return 1
  fi
  [[ "$edited" =~ $iso ]] || return 2
  [[ "$edited" > "$disposed" ]] && return 0
  return 1
}

# cdv_body_has_findings <comment_body>
#   0 when <comment_body> carries a FINDING-BEARING section per the reviewer-source
#   registry's reviewer_sources_finding_section_pattern (#2008), such as CodeRabbit's
#   Security Architecture Review with retained concerns, even when the same comment
#   also shows a rate-limit block. 1 when it carries none.
#   An `informational` disposition never verifies against a body this returns 0
#   for: a rate-limit notice covers only its own section, never the findings
#   beside it.
#   FAILS CLOSED: an unreadable registry or a jq error returns 0 ("has findings"),
#   so an `informational` disposition can never be certified on a body we could not
#   classify. Pure apart from reading the registry file.
cdv_body_has_findings() {
  local body="${1:-}" lib_dir pattern result
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  pattern="$(
    # shellcheck source=reviewer-sources.sh
    source "$lib_dir/reviewer-sources.sh" 2>/dev/null \
      && reviewer_sources_finding_section_pattern 2>/dev/null
  )" || return 0
  [[ -n "$pattern" ]] || return 0
  result="$(jq -nr --arg b "$body" --arg p "$pattern" '$b | test($p)' 2>/dev/null)" || return 0
  [[ "$result" == "false" ]] && return 1
  return 0
}

# cdv_reply_needs_response <bot_reply_body>
#   Loop safety (#860 / AC7): a bot that replies AFTER our disposition is answered
#   again ONLY if it raises a genuinely NEW finding — boilerplate/acknowledgements
#   never start a reply chain. Reuses acv_bot_comment_is_acknowledgement (the same
#   discriminator the review-thread path uses):
#     new finding (rc1)                    → 0 (respond)
#     acknowledgement (rc0) / ambiguous(2) → 1 (do NOT respond)
#   Pure — no gh/git/network.
cdv_reply_needs_response() {
  local body="${1:-}"
  local ack_rc=0
  acv_bot_comment_is_acknowledgement "$body" || ack_rc=$?
  [[ "$ack_rc" -eq 1 ]] && return 0
  return 1
}
