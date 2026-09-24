#!/usr/bin/env bash
# maintainer-resolve-comment.sh — the dev-lead-INDEPENDENT path a maintainer runs
# to satisfy the undispositioned-comment gate against THEIR OWN PR issue comment
# (issue #1910, epic #1894 AC #4).
#
# WHY THIS EXISTS
#   maintainer-comment-gate.sh (#1290, #1813) withholds pr-review's approval while
#   ANY non-agent PR issue comment lacks a VERIFIED DISPOSITION — surfaced
#   server-side as the comment being minimized with classifier RESOLVED. The gate
#   correctly REPORTS that gate and names what satisfies it (AC #1–#3, PR #1902).
#   But the ONLY actor that ever performs that minimize is dev-lead. So a comment
#   on a PR where dev-lead is suppressed, rate-limited, cancelled, or never
#   dispatched stays undispositioned forever and no approval can stand. There was
#   no path a human maintainer could invoke to satisfy the gate against their own
#   comment (AC #4). This script is that path.
#
# WHAT IT DOES (and does NOT weaken)
#   It minimizes the maintainer's OWN comment with GraphQL minimizeComment and
#   classifier RESOLVED — the EXACT signal the gate already honours (see
#   `mrc_minimize_mutation`). It invents no new/weaker signal: the gate is
#   unchanged, and a comment resolved this way clears it for the same reason a
#   dev-lead-resolved comment does. Two guardrails preserve the gate's meaning:
#     • SELF-SCOPE (#1910 AC #1): it acts ONLY on a comment the invoking user
#       authored (`mrc_authorize_self`). A maintainer cannot dismiss someone
#       else's finding through this path — that still requires dev-lead's
#       verified-`fixed` flow (cdv_authorize) or the other person's own action.
#       This mirrors the gate's own rule that a human's finding is auto-resolved
#       only on a verified `fixed`.
#     • VERIFIED DISPOSITION IS THE HUMAN'S (#1910 AC #2): the maintainer is the
#       human-in-the-loop who has verified their own finding before running this;
#       the RESOLVED classifier is required and hardcoded, never softened.
#
#   #1918 EXTENSION — a maintainer may ALSO disposition a comment authored by a
#   REGISTERED REVIEWER BOT (a row in scripts/lib/reviewer-sources.tsv, e.g.
#   sonarqubecloud). SonarCloud re-posts its "Quality Gate passed" status on every
#   push, and #1911's self-scope meant a maintainer could not clear a bot's comment
#   at all, so the #1894 queue stayed deadlocked. The bot-comment path REQUIRES
#   --reason: it is posted as a reply (carrying the `maintainer-resolve` marker so
#   the gate does not read it as a new blocker) BEFORE the original is minimized.
#   Another HUMAN's comment is STILL refused (mrc_is_registered_bot returns false
#   for a non-registered login) — that restriction is the reason #1910 was
#   self-scoped and it is preserved here.
#
#   The pure mrc_* helpers make no gh/git/network calls and are unit-tested; the
#   network `main` (guarded by BASH_SOURCE) resolves the comment, authorizes the
#   caller against its author, and performs the minimize. It FAILS CLOSED on any
#   ambiguity — an unreadable comment, an author it cannot confirm, or a viewer it
#   cannot confirm blocks the minimize rather than resolving blindly.

set -euo pipefail

# The GraphQL mutation that supplies the gate's "addressed" signal. classifier is
# RESOLVED and ONLY RESOLVED — the gate treats no other minimize reason as
# addressed (a comment minimized OUTDATED still blocks), so weakening the
# classifier here would silently fail to satisfy the gate. Kept as a function so
# the test can assert the classifier is not softened.
mrc_minimize_mutation() {
  printf '%s' 'mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:RESOLVED}){minimizedComment{isMinimized minimizedReason}}}'
}

# mrc_ref_kind <ref>
#   Classify a comment reference. Echoes:
#     node — a GraphQL IssueComment node id (IC_...), usable directly as subjectId
#     url  — a github.com PR comment URL with an #issuecomment-<n> anchor
#   Returns 1 (echoing nothing) for anything else, so an unrecognised ref fails
#   closed rather than being guessed at. Pure.
mrc_ref_kind() {
  local ref="${1:-}"
  if [[ "$ref" =~ ^IC_[A-Za-z0-9_-]+$ ]]; then
    printf 'node'
    return 0
  fi
  # PR-only tool: accept ONLY a /pull/ comment URL, never a bare /issues/ one, so
  # this path cannot be pointed at a non-PR issue comment.
  if [[ "$ref" =~ ^https?://github\.com/[^/]+/[^/]+/pull/[0-9]+#issuecomment-[0-9]+$ ]]; then
    printf 'url'
    return 0
  fi
  return 1
}

# mrc_comment_dbid_from_url <url>
#   Echo the numeric issue-comment database id from a #issuecomment-<n> anchor.
#   Returns 1 when absent. Pure.
mrc_comment_dbid_from_url() {
  local url="${1:-}"
  if [[ "$url" =~ \#issuecomment-([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# mrc_repo_from_url <url>
#   Echo owner/repo from a github.com PR comment URL. Returns 1 when the URL does
#   not match. PR-only: a /issues/ URL is not accepted. Pure.
mrc_repo_from_url() {
  local url="${1:-}"
  if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/[0-9]+ ]]; then
    printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# mrc_pr_number_from_url <url>
#   Echo the pull-request number from a github.com PR comment URL. Returns 1 when
#   absent. Used to verify the resolved comment actually belongs to that PR before
#   minimizing it — the numeric path in the URL is untrusted until confirmed
#   against the fetched comment's issue_url. Pure.
mrc_pr_number_from_url() {
  local url="${1:-}"
  if [[ "$url" =~ ^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)#issuecomment-[0-9]+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# mrc_authorize_self <viewer_login> <comment_author_login>
#   0 iff both logins are non-empty and equal — the invoking user is resolving
#   THEIR OWN comment (#1910 AC #1). Any mismatch, or an unconfirmable login on
#   either side, fails closed. Pure.
mrc_authorize_self() {
  local viewer="${1:-}" author="${2:-}"
  [[ -n "$viewer" && -n "$author" && "$viewer" == "$author" ]]
}

# mrc_normalize_login <login>
#   Echo the login with any trailing "[bot]" suffix removed, so a GraphQL App login
#   ("sonarqubecloud") and its REST/webhook form ("sonarqubecloud[bot]") both match
#   the bare login stored in the reviewer-source registry. Pure.
mrc_normalize_login() {
  local l="${1:-}"
  if [[ "$l" == *"[bot]" ]]; then
    printf '%s' "${l%\[bot\]}"
  else
    printf '%s' "$l"
  fi
}

# mrc_is_registered_bot <author_login> <registered_logins_newline>
#   0 iff <author_login> (with any "[bot]" suffix stripped) matches a line in the
#   newline-separated list of registered reviewer-bot logins (#1918 AC #3). This is
#   what lets a maintainer disposition a REGISTERED reviewer bot's comment while a
#   human's finding — never in the registry — is still refused (#1910 restriction).
#   An empty author, or an author absent from the list, fails closed. Pure.
mrc_is_registered_bot() {
  local author="${1:-}" registered="${2:-}" norm line
  [[ -n "$author" ]] || return 1
  norm="$(mrc_normalize_login "$author")"
  [[ -n "$norm" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$norm" ]] && return 0
  done <<< "$registered"
  return 1
}

# mrc_reason_ok <reason>
#   0 iff <reason> is non-empty after trimming whitespace. The bot-comment path
#   REQUIRES a reason (posted as a reply before minimizing, #1918 AC #3) so the
#   disposition of someone else's comment always carries a recorded justification.
#   Pure.
mrc_reason_ok() {
  local reason="${1:-}" trimmed
  trimmed="$(printf '%s' "$reason" | tr -d '[:space:]')"
  [[ -n "$trimmed" ]]
}

# mrc_build_reply_body <bot_login> <viewer_login> <reason>
#   Echo the reply body posted before minimizing a registered bot's comment. It
#   carries the `maintainer-resolve` HTML marker so maintainer-comment-gate.sh
#   treats the reply as our own automation and never as a fresh blocker (#1918),
#   plus the disposing maintainer and their reason for the audit trail. Pure.
mrc_build_reply_body() {
  local bot="${1:-}" viewer="${2:-}" reason="${3:-}"
  printf '<!-- maintainer-resolve author=%s by=%s -->\n' "$bot" "$viewer"
  printf 'Maintainer disposition of @%s'"'"'s status comment by @%s:\n\n%s\n' \
    "$bot" "$viewer" "$reason"
}

# mrc_is_resolved_minimized <isMinimized> <minimizedReason>
#   0 when the comment is already minimized with classifier RESOLVED (idempotency:
#   nothing to do). The reason match is case-insensitive because the GraphQL enum
#   RESOLVED surfaces as "resolved" in some read shapes. Pure.
mrc_is_resolved_minimized() {
  local is_min="${1:-}" reason="${2:-}"
  [[ "$is_min" == "true" && "$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]')" == "resolved" ]]
}

_mrc_usage() {
  cat <<'USAGE'
maintainer-resolve-comment.sh — satisfy the undispositioned-comment gate without
dev-lead running: on YOUR OWN PR issue comment (issue #1910, epic #1894 AC #4), or
on a comment authored by a REGISTERED REVIEWER BOT (issue #1918 AC #3).

The pr-review maintainer-comment gate withholds approval while any non-agent PR
issue comment lacks a verified disposition — surfaced as the comment being
MINIMIZED with classifier RESOLVED. Normally only dev-lead performs that minimize,
so a comment on a PR where dev-lead never ran stays a permanent blocker. Two paths
clear it without dev-lead:

  • YOUR OWN comment — once you have verified your own finding is addressed, run
    this to minimize your own comment RESOLVED.
  • A REGISTERED REVIEWER BOT's comment (a row in scripts/lib/reviewer-sources.tsv,
    e.g. sonarqubecloud) — pass --reason; it is posted as a reply (carrying the
    `maintainer-resolve` marker so it is not itself a new blocker) BEFORE the
    original comment is minimized RESOLVED. Another HUMAN's comment is still
    refused — that requires dev-lead's verified-fix flow or the author's action.

USAGE:
  maintainer-resolve-comment.sh <comment-url | comment-node-id> [--reason "<why>"]
  maintainer-resolve-comment.sh --help

ARGUMENTS:
  <comment-url>       A PR comment URL, e.g.
                      https://github.com/OWNER/REPO/pull/123#issuecomment-456789
  <comment-node-id>   A GraphQL IssueComment node id, e.g. IC_kwDO...
  --reason "<why>"    Required when dispositioning a registered reviewer bot's
                      comment; posted as a reply before minimizing. Ignored (not
                      required) on your own comment.

BEHAVIOUR / SAFETY:
  • Acts on a comment YOU authored, OR one authored by a registered reviewer bot.
    Another human's finding is rejected — that still requires dev-lead's
    verified-fix flow or the other person's own action.
  • The bot-comment path REQUIRES --reason and posts it as a reply before the
    minimize, so dispositioning someone else's comment always leaves a recorded,
    human-authored justification.
  • Minimizes with classifier RESOLVED and nothing weaker; this is the exact
    signal maintainer-comment-gate.sh already treats as addressed, so the gate's
    RESOLVED requirement is preserved, not weakened.
  • Idempotent: a comment already minimized RESOLVED is left as-is.
  • Fails closed: an unreadable comment, or an author/viewer it cannot confirm,
    blocks the minimize rather than resolving blindly.

Requires gh authenticated as your own account with permission to minimize the comment.
USAGE
}

# _mrc_resolve_node_id <ref> <kind>
#   Echo the GraphQL node id for a comment ref. For a node ref, echoes it verbatim.
#   For a url ref, resolves the numeric database id to a node id via REST. Echoes
#   empty (return 1) on failure.
_mrc_resolve_node_id() {
  local ref="$1" kind="$2" repo dbid want_pr snap node issue_url got_pr status
  if [[ "$kind" == "node" ]]; then
    printf '%s' "$ref"
    return 0
  fi
  # Assign each pure parse to a variable via an explicit success check first —
  # a command substitution on the RHS of `||` runs with `set -e` disabled, which
  # would swallow a failure inside the callee.
  if ! mrc_repo_from_url "$ref" >/dev/null; then return 1; fi
  repo=$(mrc_repo_from_url "$ref")
  if ! mrc_comment_dbid_from_url "$ref" >/dev/null; then return 1; fi
  dbid=$(mrc_comment_dbid_from_url "$ref")
  if ! mrc_pr_number_from_url "$ref" >/dev/null; then return 1; fi
  want_pr=$(mrc_pr_number_from_url "$ref")

  set +e
  snap=$(gh api "repos/${repo}/issues/comments/${dbid}" 2>/dev/null)
  status=$?
  set -e
  [[ $status -eq 0 && -n "$snap" ]] || return 1

  # The comment id must belong to the pull request named in the URL. A comment
  # that resolves to a different issue/PR (or to a non-PR issue) is refused — the
  # numeric path in the URL is untrusted until confirmed against issue_url.
  issue_url=$(printf '%s' "$snap" | jq -r '.issue_url // ""' 2>/dev/null || echo "")
  if [[ "$issue_url" =~ /pull/([0-9]+)$ || "$issue_url" =~ /issues/([0-9]+)$ ]]; then
    got_pr="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  [[ -n "$got_pr" && "$got_pr" == "$want_pr" ]] || return 1

  node=$(printf '%s' "$snap" | jq -r '.node_id // ""' 2>/dev/null || echo "")
  [[ -n "$node" ]] || return 1
  printf '%s' "$node"
}

# main — network path (only when executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  # Parse a single positional comment ref plus an optional --reason (used only for
  # the registered-bot path). --help / -h anywhere prints usage and exits 0.
  _ref=""
  _reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        _mrc_usage
        exit 0
        ;;
      --reason)
        _reason="${2:-}"
        shift 2 || shift
        ;;
      --reason=*)
        _reason="${1#--reason=}"
        shift
        ;;
      *)
        if [[ -z "$_ref" ]]; then
          _ref="$1"
        else
          echo "[maintainer-resolve-comment] ERROR: unexpected extra argument '$1'" >&2
          exit 2
        fi
        shift
        ;;
    esac
  done
  if [[ -z "$_ref" ]]; then
    _mrc_usage
    exit 2
  fi

  # Assign after an explicit success check: a command substitution on the RHS of
  # `||` runs with `set -e` disabled, so a failure inside mrc_ref_kind /
  # _mrc_resolve_node_id / gh could otherwise be swallowed.
  if ! mrc_ref_kind "$_ref" >/dev/null; then
    echo "[maintainer-resolve-comment] ERROR: unrecognised comment reference '$_ref'" >&2
    echo "  expected a PR comment URL (…/pull/N#issuecomment-M) or an IssueComment node id (IC_…)" >&2
    exit 2
  fi
  _kind=$(mrc_ref_kind "$_ref")

  set +e
  _node=$(_mrc_resolve_node_id "$_ref" "$_kind")
  _status=$?
  set -e
  if [[ $_status -ne 0 || -z "$_node" ]]; then
    echo "[maintainer-resolve-comment] ERROR: could not resolve the comment node id for '$_ref'" >&2
    exit 2
  fi

  # Read the comment's author + current minimize state + url, and the authenticated
  # viewer, in one GraphQL round-trip. Fail closed if either login is unreadable.
  # `url` is the authoritative source for the repo + PR number when posting the
  # bot-path reply (it is a /pull/…#issuecomment-… URL for a PR comment).
  _q='query($id:ID!){viewer{login} node(id:$id){... on IssueComment{author{login} isMinimized minimizedReason url}}}'
  set +e
  _snap=$(gh api graphql -f query="$_q" -f id="$_node" 2>/dev/null)
  _status=$?
  set -e
  if [[ $_status -ne 0 ]]; then
    echo "[maintainer-resolve-comment] ERROR: could not read comment $_node — failing closed" >&2
    exit 2
  fi

  # A GraphQL-level failure (insufficient scope, bad node id, or a node that is
  # not an IssueComment) returns HTTP 200 with an `errors` payload and no `.data`.
  # Detect that unreadable state HERE and exit 2 with a distinct message, so it is
  # never misreported downstream as a self-scope authorization refusal.
  _node_present=$(printf '%s' "$_snap" | jq -r 'if .data.node == null then "no" else "yes" end' 2>/dev/null || echo "no")
  _viewer_present=$(printf '%s' "$_snap" | jq -r 'if .data.viewer == null then "no" else "yes" end' 2>/dev/null || echo "no")
  if [[ "$_node_present" != "yes" || "$_viewer_present" != "yes" ]]; then
    echo "[maintainer-resolve-comment] ERROR: could not read comment $_node (unreadable comment or viewer) — failing closed" >&2
    exit 2
  fi

  _viewer=$(printf '%s' "$_snap" | jq -r '.data.viewer.login // ""' 2>/dev/null || echo "")
  _author=$(printf '%s' "$_snap" | jq -r '.data.node.author.login // ""' 2>/dev/null || echo "")
  _is_min=$(printf '%s' "$_snap" | jq -r '.data.node.isMinimized // false | tostring' 2>/dev/null || echo "false")
  _min_reason=$(printf '%s' "$_snap" | jq -r '.data.node.minimizedReason // ""' 2>/dev/null || echo "")
  _url=$(printf '%s' "$_snap" | jq -r '.data.node.url // ""' 2>/dev/null || echo "")

  # Authorize FIRST — before the idempotent early return — so a caller cannot pass
  # an already-RESOLVED comment they are not entitled to and receive success while
  # bypassing the fail-closed authorization check. Two authorized paths:
  #   • SELF (#1910): the invoking user is the comment's author.
  #   • REGISTERED REVIEWER BOT (#1918): the author is a bot in the reviewer-source
  #     registry; the maintainer (a confirmed viewer) is the human-in-the-loop and
  #     MUST supply --reason, posted as a reply before the minimize.
  # Another human's comment matches neither and is refused (the #1910 restriction).
  _authz_kind=""
  if mrc_authorize_self "$_viewer" "$_author"; then
    _authz_kind="self"
  else
    # Load the registered reviewer-bot logins from the reviewer-source registry.
    # Fail closed if the registry cannot be read — never widen authorization on a
    # registry we could not consult.
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
    _registered=""
    if [[ -f "$_lib_dir/reviewer-sources.sh" ]]; then
      _registered="$(
        # shellcheck source=lib/reviewer-sources.sh
        source "$_lib_dir/reviewer-sources.sh" 2>/dev/null \
          && reviewer_sources_logins 2>/dev/null
      )" || _registered=""
    fi
    if [[ -n "$_viewer" ]] && mrc_is_registered_bot "$_author" "$_registered"; then
      _authz_kind="bot"
    fi
  fi

  if [[ -z "$_authz_kind" ]]; then
    echo "[maintainer-resolve-comment] ERROR: refusing to resolve — this path minimizes only YOUR OWN comment or a REGISTERED REVIEWER BOT's comment." >&2
    echo "  authenticated as: '${_viewer:-<unreadable>}'; comment author: '${_author:-<unreadable>}'" >&2
    echo "  a finding authored by another person must be dispositioned by dev-lead (verified fix) or by its author." >&2
    exit 3
  fi

  # The bot-comment path requires a reason (posted as a reply before minimizing),
  # so dispositioning someone else's comment always carries a recorded justification.
  if [[ "$_authz_kind" == "bot" ]] && ! mrc_reason_ok "$_reason"; then
    echo "[maintainer-resolve-comment] ERROR: --reason is required to resolve a reviewer bot's comment (author '$_author')." >&2
    echo "  usage: maintainer-resolve-comment.sh <ref> --reason \"why this bot status needs no further action\"" >&2
    exit 2
  fi

  if mrc_is_resolved_minimized "$_is_min" "$_min_reason"; then
    echo "[maintainer-resolve-comment] comment $_node is already minimized RESOLVED — nothing to do."
    exit 0
  fi

  # Bot-comment path: post the maintainer's reason as a MARKED reply BEFORE the
  # minimize. The marker keeps it out of the maintainer-comment gate, and posting
  # first means a failed reply fails the whole action closed (no silent minimize
  # without the recorded justification).
  if [[ "$_authz_kind" == "bot" ]]; then
    if ! mrc_repo_from_url "$_url" >/dev/null || ! mrc_pr_number_from_url "$_url" >/dev/null; then
      echo "[maintainer-resolve-comment] ERROR: could not derive the PR from the comment URL '$_url' — failing closed (no minimize)." >&2
      exit 2
    fi
    _reply_repo=$(mrc_repo_from_url "$_url")
    _reply_pr=$(mrc_pr_number_from_url "$_url")
    _reply_file=$(mktemp)
    # shellcheck disable=SC2064  # expand _reply_file now so the trap removes this exact file
    trap "rm -f '$_reply_file'" EXIT
    mrc_build_reply_body "$(mrc_normalize_login "$_author")" "$_viewer" "$_reason" > "$_reply_file"
    set +e
    gh api "repos/${_reply_repo}/issues/${_reply_pr}/comments" -F body=@"$_reply_file" >/dev/null 2>&1
    _status=$?
    set -e
    if [[ $_status -ne 0 ]]; then
      echo "[maintainer-resolve-comment] ERROR: could not post the reason reply on PR #${_reply_pr} — failing closed (no minimize)." >&2
      exit 1
    fi
    echo "[maintainer-resolve-comment] posted disposition reason as a reply on PR #${_reply_pr}."
  fi

  # Verify the mutation actually left the comment minimized RESOLVED rather than
  # trusting a zero exit — a partial or semantically-unsuccessful GraphQL response
  # must fail closed (AGENTS.md: confirm the resulting artifact, not command exit).
  _mutation=$(mrc_minimize_mutation)
  set +e
  _result=$(gh api graphql -f query="$_mutation" -f id="$_node" 2>/dev/null)
  _status=$?
  set -e
  if [[ $_status -ne 0 ]]; then
    echo "[maintainer-resolve-comment] ERROR: minimizeComment failed for $_node (check gh permissions)." >&2
    exit 1
  fi
  if printf '%s' "$_result" | jq -e '
      (.data.minimizeComment.minimizedComment.isMinimized == true)
      and (((.data.minimizeComment.minimizedComment.minimizedReason // "") | ascii_downcase) == "resolved")
    ' >/dev/null 2>&1; then
    echo "[maintainer-resolve-comment] minimized comment $_node RESOLVED — the maintainer-comment gate is now satisfied for it."
    exit 0
  fi
  echo "[maintainer-resolve-comment] ERROR: minimizeComment did not confirm a RESOLVED minimized comment for $_node — failing closed." >&2
  exit 1
fi
