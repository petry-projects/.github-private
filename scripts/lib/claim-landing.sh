#!/usr/bin/env bash
# claim-landing.sh — "did the push land, and which claims must be retracted?" as
# pure verdicts (#2013).
#
# WHAT IS WRONG WITHOUT THIS
#   The fix-reviews / fix-bot-comment model posts its "Fixed in …" reply (with the
#   addressed-marker + #1692 claim) from its OWN shell, BEFORE the harness commits
#   and pushes. On petry-projects/.github#1220 that left false "Fixed" replies
#   standing when the push never landed, and when the claim named the PR's FIRST
#   commit (a stale pre-pass head). CodeRabbit then marked a thread "✅ Confirmed as
#   addressed" on the strength of the reply, so an unverified claim cleared a gate.
#   The #1692 claim check ran only at thread-RESOLUTION time; nothing ever took a
#   posted claim back.
#
# THE CONTRACT
#   - cl_push_landed_verdict decides, from SHAs alone, whether the pass's pushed
#     commit is on the remote head. commit_and_push treats anything but `landed` as
#     a failed push.
#   - cl_select_pass_claims picks OUR claim/marker replies created during this pass.
#   - each selected claim is checked with acv_claim_in_pass against the REMOTE head
#     (addressed-claim-verify.sh); any that fails is rewritten with cl_retract_body,
#     which strips both markers so the reply can never authorize resolution again.
#
# PURITY / TESTABILITY (ADR-0004)
#   Every cl_* function except cl_remote_head is PURE: no network, no git, no gh.
#   cl_remote_head is the single impure reader. Sourced under `set -euo pipefail`,
#   so helpers only `return`, never `exit`, and fail closed on every ambiguity.

set -euo pipefail

# acv_parse_claim is the single claim parser — reuse it, never a second one.
if ! declare -F acv_parse_claim >/dev/null 2>&1; then
  # shellcheck source=addressed-claim-verify.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/addressed-claim-verify.sh"
fi

# The retraction marker. Matches the shared `<!-- dev-lead… -->` agent-marker
# discriminator, so a retracted reply is still recognised as ours, but it is NOT the
# addressed-marker, so it can never authorize resolution.
readonly _CL_RETRACTED_PREFIX='<!-- dev-lead:retracted reason='

# cl_push_landed_verdict <start_head> <pushed_sha> <remote_head> <pushed_on_remote>
#   Echoes one token and returns 0 only for `landed`:
#     landed      <pushed_sha> advanced past <start_head> and is contained in the
#                 remote head (<pushed_on_remote> == "true"; the remote may have
#                 moved on past it).
#     unknown     any SHA is empty — fail closed.
#     no-advance  <pushed_sha> == <start_head>: nothing of this pass was pushed.
#     not-landed  the remote head does not contain <pushed_sha> (rejected /
#                 non-fast-forward / remote moved without our commit).
#   Pure — no gh/git/network.
cl_push_landed_verdict() {
  local start="${1:-}" pushed="${2:-}" remote="${3:-}" on_remote="${4:-}"
  if [[ -z "$start" || -z "$pushed" || -z "$remote" ]]; then
    echo "unknown"
    return 1
  fi
  if [[ "$pushed" == "$start" ]]; then
    echo "no-advance"
    return 1
  fi
  if [[ "$on_remote" != "true" ]]; then
    echo "not-landed"
    return 1
  fi
  echo "landed"
  return 0
}

# cl_select_pass_claims <comments_json> <bot_user> <since_iso>
#   <comments_json> is the REST `pulls/{pr}/comments` array ({id, user.login, body,
#   created_at}). Emits one `<id>\t<sha>` row per comment that (a) our account
#   authored (bot_user or its [bot]-suffixed / stripped form), (b) was created at or
#   after <since_iso> (the pass start), and (c) still carries the addressed-marker or
#   a claim comment. <sha> is the parsed claim SHA, or empty when the claim is
#   missing/malformed (unverifiable -> the caller retracts). An empty <since_iso> or
#   a non-array payload selects nothing: without a pass boundary the sweep must
#   never reach back and retract a previous pass's replies. Pure.
cl_select_pass_claims() {
  local comments_json="${1:-}" bot_user="${2:-}" since="${3:-}"
  [[ -z "$since" ]] && return 0
  local bot_stripped="${bot_user%\[bot\]}"

  local rows
  rows=$(jq -r \
    --arg u "$bot_user" --arg us "$bot_stripped" --arg since "$since" \
    --arg marker "$_DEV_LEAD_ADDRESSED_MARKER" --arg claim "$_ACV_CLAIM_PREFIX" '
      if type == "array" then
        .[] | objects
        | (.user.login // "") as $l
        | select($l == $u or $l == $us or $l == ($us + "[bot]"))
        | select((.created_at // "") >= $since)
        | select(((.body // "") | test($marker)) or ((.body // "") | contains($claim)))
        | [(.id | tostring), ((.body // "") | @base64)]
        | @tsv
      else empty end
    ' <<<"$comments_json" 2>/dev/null) || return 0
  [[ -z "$rows" ]] && return 0

  local id body_b64 body claim sha
  while IFS=$'\t' read -r id body_b64; do
    [[ -z "$id" ]] && continue
    body=$(base64 --decode <<<"$body_b64" 2>/dev/null || printf '')
    sha=""
    if claim=$(acv_parse_claim "$body"); then
      sha=$(jq -r '.sha // ""' <<<"$claim" 2>/dev/null || printf '')
    fi
    printf '%s\t%s\n' "$id" "$sha"
  done <<<"$rows"
}

# cl_retract_body <body> <reason>
#   The retracted form of a claim reply. Removes the addressed-marker and the claim
#   comment (so neither the thread gate nor another bot can treat it as a fix),
#   prefixes a plain-language retraction, keeps the original text as a quote for
#   the record, and appends `<!-- dev-lead:retracted reason=<reason> -->`. <reason>
#   is restricted to [a-z-] (anything else becomes `unknown`) so it can never break
#   out of the HTML comment. Pure.
cl_retract_body() {
  local body="${1:-}" reason="${2:-unknown}"
  [[ "$reason" =~ ^[a-z][a-z-]*$ ]] || reason="unknown"

  local stripped
  stripped=$(jq -Rsr --arg marker "$_DEV_LEAD_ADDRESSED_MARKER" '
      gsub($marker; "")
      | gsub("<!--[[:space:]]*dev-lead:claim[^>]*-->"; "")
      | sub("\\s+$"; "")
    ' <<<"$body" 2>/dev/null) || stripped=""
  local quoted
  quoted=$(printf '%s\n' "$stripped" | sed 's/^/> /')

  printf '%s\n\n%s\n\n%s\n\n%s%s -->\n' \
    "**⚠️ Retracted by the dev-lead harness (\`${reason}\`).** The fix this reply describes is **not** on the PR head: its commit was not produced and pushed by this pass, or the push did not land. The thread stays open; the next dev-lead pass re-verifies against the pushed diff." \
    "Original reply, kept for the record (it does not describe the PR head):" \
    "$quoted" \
    "$_CL_RETRACTED_PREFIX" "$reason"
}

# cl_remote_head
#   The single impure reader: fetch the current branch's upstream and echo the TRUE
#   remote head SHA (not a stale remote-tracking ref). Returns 1 (echoing nothing)
#   when the branch has no upstream, 2 when the fetch or lookup fails.
cl_remote_head() {
  local up remote branch
  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  [[ -z "$up" ]] && return 1
  remote="${up%%/*}"
  branch="${up#*/}"
  git fetch --quiet "$remote" "$branch" 2>/dev/null || return 2
  local sha
  sha=$(git rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" 2>/dev/null \
    || git rev-parse --verify --quiet FETCH_HEAD 2>/dev/null || true)
  [[ -z "$sha" ]] && return 2
  echo "$sha"
}
