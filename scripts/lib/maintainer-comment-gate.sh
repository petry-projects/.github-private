#!/usr/bin/env bash
# Maintainer issue-comment gate (issues #1290, #1813)
#
# A maintainer finding posted as a PR *issue comment* — what `gh pr comment` and
# the GitHub main comment box produce — creates NO review thread. So unlike an
# inline review comment it:
#   1. does not trip `required_review_thread_resolution` → does not block merge, and
#   2. is never enumerated by dev-lead's fix-reviews prompt (it walks reviewThreads),
# and pr-review approves → the PR auto-merges with the defect intact. The same
# words, posted two ways, have opposite force; the easy path (`gh pr comment`) is
# the silent one.
#
# This gate closes the "does not block" half at the pr-review approval boundary.
#
# #1813 REDESIGN — "addressed" means a VERIFIED DISPOSITION, not a timestamp.
#   The original gate (#1290) judged a comment addressed by comparing timestamps:
#   a push at/after the comment cleared it. That was wrong twice over:
#     • it depended on the head-push timestamp, which GitHub now always returns
#       as null, so the gate failed closed on every open PR (the #1813 outage); and
#     • a push is only a proxy — it says nothing about whether a comment's finding
#       was read, checked, and acted on.
#   The redesign removes the push-timestamp model entirely. dev-lead
#   researches each undispositioned comment and posts exactly one evidence-backed
#   reply carrying `<!-- dev-lead:comment-disposition id=<id> disposition=<...> -->`;
#   the harness verifies that disposition and then minimizes the ORIGINAL comment
#   with classifier RESOLVED (GraphQL minimizeComment). This gate treats a
#   RESOLVED-minimized comment as addressed and withholds approval while ANY
#   non-agent issue comment lacks that signal.
#
#   Scope: EVERY PR issue comment, from human maintainers and bots alike
#   (codeant-ai, qodo-code-review, auto-rebase-conflict, and so on). No author is
#   exempt for being a bot — a conflict report is a finding, a trial-ended notice
#   has an operational consequence. The ONLY exclusion is our own automation's
#   disposition/ack/note replies (so the agent never has to answer itself): our
#   bot login, or a body carrying one of our automation markers (which includes
#   the `<!-- dev-lead:comment-disposition ... -->` reply itself).
#
# It FAILS CLOSED: an inability to evaluate the snapshot must block, and is
# reported DISTINCTLY (return 2 → a distinct verdict reason) so an undeterminable
# gate state can never recur disguised as a legitimate hold (#1813 AC8).
#
# check_maintainer_comments <pr_snapshot_json> [bot_user]
#   <pr_snapshot_json> — output of `gh pr view --json comments,...`; each comment
#                        must carry {author.login, body, isMinimized, minimizedReason}.
#   [bot_user]         — the agent's own login (default donpetry-bot)
# Returns:
#   0 = every non-agent issue comment is minimized RESOLVED (or none exist)
#   1 = at least one non-agent issue comment lacks a verified disposition → block
#   2 = the snapshot could not be evaluated (malformed) → fail closed → block
#
# The check is pure: it makes no `gh`/network calls and reuses the snapshot the
# caller already fetched, so it adds no API round-trip and is trivially testable.
# maintainer_gate_head_committer_date() is a thin `gh` helper retained for the
# sibling review-thread gate's push-time needs; it uses committer.date and reads
# NO push-timestamp field (#1813 AC1 / matching advisory-review-gate.sh, #577).

set -euo pipefail

# Regex (case-sensitive) matching the HTML markers our own automation stamps into
# comment bodies — pr-review reviews/acks (`<!-- pr-review-agent ... -->`,
# `<!-- persona:pr-review -->`), the pr-review re-review claim marker
# (`<!-- pr-review-claim ... -->`, issue #1589), dev-lead notes AND dev-lead
# comment-dispositions (`<!-- dev-lead ... -->` / `<!-- dev-lead:comment-disposition ... -->`),
# and the dependency-advisory pass (`<!-- dependency-advisory -->`). A comment
# carrying any of these is one of ours, never a finding we must disposition.
# This marker-based exclusion is essential because these workflows post as the
# human owner (`don-petry`) — the same account a human maintainer would use — so
# login alone cannot separate the agent's comments from a person's. It is also
# the loop-safety guard (#860 / #1813 AC7): our own disposition reply carries the
# `dev-lead` marker, so it is never itself counted as a comment needing a response.
# `maintainer-resolve` is the marker on the reply maintainer-resolve-comment.sh
# posts when it dispositions a registered reviewer bot's comment (#1918) — that
# reply must not itself become a fresh undispositioned blocker.
readonly _MAINTAINER_GATE_AGENT_MARKERS='<!-- (pr-review-agent|pr-review-claim|persona:|dev-lead|dependency-advisory|maintainer-resolve)[^>]*-->'

log_info() {
  echo "[maintainer-gate] $*" >&2
}

# _maintainer_gate_info_patterns_json
#   Echo a JSON object mapping each reviewer-source login to its known clean
#   *informational* status-comment pattern (#1918), read from the reviewer-source
#   registry (scripts/lib/reviewer-sources.tsv, column info_status_pattern). A
#   comment authored by such a login whose body matches the pattern is a clean
#   status report (e.g. SonarCloud's "Quality Gate passed") that carries no finding.
#   FAILS OPEN TO "{}" — an unreadable registry yields an empty map, so the gate
#   degrades to blocking EVERY undispositioned bot comment (fail closed on the gate
#   verdict: an info comment we can't classify simply stays a blocker), never to
#   clearing something it cannot classify.
_maintainer_gate_info_patterns_json() {
  local lib_dir patterns
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ ! -f "$lib_dir/reviewer-sources.sh" ]]; then
    printf '%s' '{}'
    return 0
  fi
  # Source in a subshell so the registry helper's vars/functions never leak into
  # the gate's caller; capture only the login\tpattern lines.
  patterns="$(
    # shellcheck source=reviewer-sources.sh
    source "$lib_dir/reviewer-sources.sh" 2>/dev/null \
      && reviewer_sources_info_status_patterns 2>/dev/null
  )" || { printf '%s' '{}'; return 0; }
  [[ -n "$patterns" ]] || { printf '%s' '{}'; return 0; }
  printf '%s\n' "$patterns" \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
                | map(select(length == 2) | {(.[0]): .[1]}) | add // {}' 2>/dev/null \
    || printf '%s' '{}'
}

log_warn() {
  echo "[maintainer-gate] WARNING: $*" >&2
}

# maintainer_gate_head_committer_date <pr_url>
#   Echo the committer.date of the PR's head commit via a single GraphQL query.
#   Uses committer.date (not the deprecated, now-null push timestamp) so a cherry-pick
#   or rebase reflects when it was applied rather than the original author date —
#   the same cherry-pick-safe semantics advisory-review-gate.sh uses (#577). This
#   gate no longer decides "addressed" from push time; the helper is retained only
#   for the sibling review-thread gate, which sources this file for it. Echoes
#   empty on any API failure.
maintainer_gate_head_committer_date() {
  local pr_url="${1:-}"
  [[ -z "$pr_url" ]] && return 0
  # shellcheck disable=SC2016  # $url is a GraphQL variable placeholder, not shell
  local _gql='query($url:URI!){resource(url:$url){...on PullRequest{commits(last:1){nodes{commit{committer{date}}}}}}}'
  gh api graphql -f query="$_gql" -f url="$pr_url" \
    --jq '.data.resource.commits.nodes[0].commit.committer.date // empty' 2>/dev/null || true
}

# check_maintainer_comments <pr_snapshot_json> [bot_user]
check_maintainer_comments() {
  local json="${1:-}"
  local bot_user="${2:-donpetry-bot}"

  # Count non-agent issue comments that are NOT yet resolved. A comment is
  # "cleared" when it is authored by our own account, carries one of our
  # automation markers (our disposition/ack/note replies), OR has been minimized
  # with classifier RESOLVED (the harness's verified-disposition signal). Anything
  # else — a bot or human comment without a verified disposition — blocks.
  # A jq failure (malformed snapshot, or a value that can't be indexed with
  # .comments) exits non-zero → return 2 so undeterminable input fails closed
  # rather than silently reading as "no findings".
  # Data-driven info-status classifier (#1918): {login: pattern} of KNOWN CLEAN
  # informational status comments (e.g. sonarqubecloud → "Quality Gate passed"),
  # read from the reviewer-source registry. A comment authored by a listed login
  # whose body matches its pattern carries no finding and is treated as addressed.
  # An unreadable registry yields "{}" → no comment is auto-cleared (fail closed).
  local info_patterns
  info_patterns="$(_maintainer_gate_info_patterns_json)"

  local blockers
  blockers=$(printf '%s' "$json" | jq -r \
    --arg markers "$_MAINTAINER_GATE_AGENT_MARKERS" \
    --arg botuser "$bot_user" \
    --argjson infopatterns "$info_patterns" '
      def bot_stripped: ($botuser | if endswith("[bot]") then .[0:-5] else . end);
      [ (.comments // [])[] | objects
        | (.author?.login // "" | tostring) as $l
        | ($l | if endswith("[bot]") then .[0:-5] else . end) as $lbare
        | select($l != $botuser and $l != bot_stripped)
        | select(((.body // "") | test($markers)) | not)
        # Drop KNOWN CLEAN info-status comments: author is a registered source and
        # its body matches that source pattern. Anything else — a failing status,
        # an unrecognised body, a bot with no pattern, a human — is still evaluated.
        | select(
            ($infopatterns[$lbare] // null) as $p
            | ($p == null) or (((.body // "") | test($p)) | not)
          )
        | select(
            ((.isMinimized // false) == true)
            and (((.minimizedReason // "") | ascii_downcase) == "resolved")
            | not
          )
      ]
      | length
    ' 2>/dev/null) || {
    log_warn "could not parse PR snapshot — failing closed (blocking approval)"
    return 2
  }

  # Empty output (jq produced nothing at all) is undeterminable → fail closed.
  if [[ -z "$blockers" ]]; then
    log_warn "PR snapshot produced no verdict — failing closed (blocking approval)"
    return 2
  fi

  if [[ "$blockers" -eq 0 ]]; then
    log_info "no undispositioned PR issue comments"
    return 0
  fi

  log_warn "$blockers PR issue comment(s) lack a verified disposition (not minimized RESOLVED) — withholding approval (#1813)"
  return 1
}

# Run standalone against a PR URL (only if executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  _pr_url="${1:-}"
  if [[ -z "$_pr_url" ]]; then
    echo "usage: maintainer-comment-gate.sh <pr-url>" >&2
    exit 2
  fi
  _snap=$(gh pr view "$_pr_url" --json comments,reviews,headRefOid 2>/dev/null) || {
    echo "[maintainer-gate] ERROR: gh pr view failed for $_pr_url" >&2
    exit 2
  }
  check_maintainer_comments "$_snap" "${BOT_USER:-donpetry-bot}"
  exit $?
fi
