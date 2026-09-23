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
  if [[ "$ref" =~ ^https?://github\.com/[^/]+/[^/]+/(pull|issues)/[0-9]+#issuecomment-[0-9]+$ ]]; then
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
#   Echo owner/repo from a github.com PR/issue comment URL. Returns 1 when the URL
#   does not match. Pure.
mrc_repo_from_url() {
  local url="${1:-}"
  if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+)/(pull|issues)/[0-9]+ ]]; then
    printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
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
maintainer-resolve-comment.sh — satisfy the undispositioned-comment gate on YOUR OWN
PR issue comment without dev-lead running (issue #1910, epic #1894 AC #4).

The pr-review maintainer-comment gate withholds approval while any non-agent PR
issue comment lacks a verified disposition — surfaced as the comment being
MINIMIZED with classifier RESOLVED. Normally only dev-lead performs that minimize,
so a comment on a PR where dev-lead never ran stays a permanent blocker. Once YOU
have verified your own finding is addressed, run this to minimize your OWN comment
RESOLVED and clear the gate.

USAGE:
  maintainer-resolve-comment.sh <comment-url | comment-node-id>
  maintainer-resolve-comment.sh --help

ARGUMENTS:
  <comment-url>       A PR comment URL, e.g.
                      https://github.com/OWNER/REPO/pull/123#issuecomment-456789
  <comment-node-id>   A GraphQL IssueComment node id, e.g. IC_kwDO...

BEHAVIOUR / SAFETY:
  • Acts ONLY on a comment YOU authored (the authenticated gh user must be the
    comment's author). Resolving someone else's finding is rejected — that still
    requires dev-lead's verified-fix flow or the other person's own action.
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
  local ref="$1" kind="$2" repo dbid node
  if [[ "$kind" == "node" ]]; then
    printf '%s' "$ref"
    return 0
  fi
  repo=$(mrc_repo_from_url "$ref") || return 1
  dbid=$(mrc_comment_dbid_from_url "$ref") || return 1
  node=$(gh api "repos/${repo}/issues/comments/${dbid}" --jq '.node_id' 2>/dev/null) || return 1
  [[ -n "$node" ]] || return 1
  printf '%s' "$node"
}

# main — network path (only when executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  _ref="${1:-}"
  if [[ -z "$_ref" || "$_ref" == "-h" || "$_ref" == "--help" ]]; then
    _mrc_usage
    # No argument at all is a usage error; --help is a success.
    [[ -z "$_ref" ]] && exit 2
    exit 0
  fi

  _kind=$(mrc_ref_kind "$_ref") || {
    echo "[maintainer-resolve-comment] ERROR: unrecognised comment reference '$_ref'" >&2
    echo "  expected a PR comment URL (…/pull/N#issuecomment-M) or an IssueComment node id (IC_…)" >&2
    exit 2
  }

  _node=$(_mrc_resolve_node_id "$_ref" "$_kind") || {
    echo "[maintainer-resolve-comment] ERROR: could not resolve the comment node id for '$_ref'" >&2
    exit 2
  }

  # Read the comment's author + current minimize state, and the authenticated
  # viewer, in one GraphQL round-trip. Fail closed if either login is unreadable.
  _q='query($id:ID!){viewer{login} node(id:$id){... on IssueComment{author{login} isMinimized minimizedReason}}}'
  _snap=$(gh api graphql -f query="$_q" -f id="$_node" 2>/dev/null) || {
    echo "[maintainer-resolve-comment] ERROR: could not read comment $_node — failing closed" >&2
    exit 2
  }
  _viewer=$(printf '%s' "$_snap" | jq -r '.data.viewer.login // ""' 2>/dev/null || echo "")
  _author=$(printf '%s' "$_snap" | jq -r '.data.node.author.login // ""' 2>/dev/null || echo "")
  _is_min=$(printf '%s' "$_snap" | jq -r '.data.node.isMinimized // false | tostring' 2>/dev/null || echo "false")
  _reason=$(printf '%s' "$_snap" | jq -r '.data.node.minimizedReason // ""' 2>/dev/null || echo "")

  if mrc_is_resolved_minimized "$_is_min" "$_reason"; then
    echo "[maintainer-resolve-comment] comment $_node is already minimized RESOLVED — nothing to do."
    exit 0
  fi

  if ! mrc_authorize_self "$_viewer" "$_author"; then
    echo "[maintainer-resolve-comment] ERROR: refusing to resolve — this path only minimizes YOUR OWN comment." >&2
    echo "  authenticated as: '${_viewer:-<unreadable>}'; comment author: '${_author:-<unreadable>}'" >&2
    echo "  a finding you did not author must be dispositioned by dev-lead (verified fix) or by its author." >&2
    exit 3
  fi

  if gh api graphql -f query="$(mrc_minimize_mutation)" -f id="$_node" >/dev/null 2>&1; then
    echo "[maintainer-resolve-comment] minimized comment $_node RESOLVED — the maintainer-comment gate is now satisfied for it."
    exit 0
  fi
  echo "[maintainer-resolve-comment] ERROR: minimizeComment failed for $_node (check gh permissions)." >&2
  exit 1
fi
