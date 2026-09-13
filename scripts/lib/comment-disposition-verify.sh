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
#         fixed        → the cited sha is on the PR head and its diff is non-empty
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
