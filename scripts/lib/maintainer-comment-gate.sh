#!/usr/bin/env bash
# Maintainer issue-comment gate (issue #1290)
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
# This gate closes the "does not block" half at the pr-review approval boundary:
# it withholds pr-review's automated approval while the LATEST maintainer issue
# comment postdates the last push. It is deliberately modeled on the advisory-bot
# gate (`advisory-review-gate.sh`, #457/#458), which likewise defers approval
# until a signal is incorporated.
#
# It FAILS CLOSED (the #1290 acceptance criterion): an inability to confirm that
# a maintainer comment was addressed must block, never read as "no findings" —
# that is precisely the bug that shipped the regression this issue tracks.
#
# check_maintainer_comments <pr_snapshot_json> <head_committer_date_iso> [bot_user]
#   <pr_snapshot_json>       — output of `gh pr view --json comments,reviews,...`
#   <head_committer_date_iso>— committer.date of the PR head commit (push time)
#   [bot_user]               — the agent's own login (default donpetry-bot)
# Returns:
#   0 = no unaddressed maintainer comment (none exist, OR the latest one is at/
#       older than the last push → a fix was pushed after it)
#   1 = the latest maintainer issue comment postdates the last push (unaddressed)
#       OR a maintainer comment exists but the push time is undeterminable
#       (fail closed) → withhold approval
#   2 = the snapshot could not be evaluated (malformed) → fail closed → block
#
# The check is pure: it makes no `gh`/network calls and reuses the snapshot the
# caller already fetched, so it adds no API round-trip and is trivially testable.
# maintainer_gate_head_committer_date() is the thin `gh` helper the caller uses
# to obtain <head_committer_date_iso> (mirrors the advisory gate's cherry-pick-safe
# committer.date fetch).

set -euo pipefail

# Comment authors that are never maintainers: advisory/review bots (already gated
# by advisory-review-gate.sh) and generic automation accounts. The agent's own
# login is excluded separately via the bot_user argument. Fail-closed principle:
# anything NOT on this list and NOT carrying one of our automation markers is
# treated as a human maintainer, so an unknown author blocks rather than slips.
# shellcheck disable=SC2034
declare -ar MAINTAINER_GATE_EXCLUDED_BOTS=(
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
# execution (and potential failures) happen inside check_maintainer_comments,
# where errors are caught and the gate can fail closed properly.
_MAINTAINER_GATE_EXCLUDED_BOTS_JSON=""

# Regex (case-sensitive) matching the HTML markers our own automation stamps into
# comment bodies — pr-review reviews/acks (`<!-- pr-review-agent ... -->`,
# `<!-- persona:pr-review -->`), the pr-review re-review claim marker
# (`<!-- pr-review-claim ... -->`, issue #1589), dev-lead notes
# (`<!-- dev-lead ... -->`), and the dependency-advisory pass
# (`<!-- dependency-advisory -->`). A comment carrying any of these is one of
# ours, never a maintainer finding. This marker-based exclusion is essential
# because these workflows post as the human owner (`don-petry`) — the same account
# a human maintainer would use — so login alone cannot separate the agent's
# comments from a person's.
readonly _MAINTAINER_GATE_AGENT_MARKERS='<!-- (pr-review-agent|pr-review-claim|persona:|dev-lead|dependency-advisory)[^>]*-->'

log_info() {
  echo "[maintainer-gate] $*" >&2
}

log_warn() {
  echo "[maintainer-gate] WARNING: $*" >&2
}

# _mcg_to_epoch <iso8601>
#   Echo the UTC epoch seconds for an ISO-8601 timestamp, or return non-zero when
#   it is empty/unparseable. Supports both GNU date (-d) and BSD date (-jf).
_mcg_to_epoch() {
  local iso="${1:-}" e
  [[ -z "$iso" ]] && return 1
  e=$(date -u -d "$iso" +%s 2>/dev/null) \
    || e=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) \
    || return 1
  printf '%s' "$e"
}

# maintainer_gate_head_committer_date <pr_url>
#   Echo the server-recorded push timestamp for the PR's head commit via a single
#   GraphQL query. Prefers pushedDate (a server-recorded field GitHub writes on
#   receipt of the push — not settable by the committer) over committer.date so
#   a future-dated no-op commit cannot make an old finding appear addressed. Fails
#   closed (empty string) when pushedDate is unavailable; the caller treats empty
#   as fail-closed (finding unresolved). Echoes empty on any API failure.
maintainer_gate_head_committer_date() {
  local pr_url="${1:-}"
  [[ -z "$pr_url" ]] && return 0
  # shellcheck disable=SC2016  # $url is a GraphQL variable placeholder, not shell
  local _gql='query($url:URI!){resource(url:$url){...on PullRequest{commits(last:1){nodes{commit{pushedDate committer{date}}}}}}}'
  local _raw
  _raw=$(gh api graphql -f query="$_gql" -f url="$pr_url" 2>/dev/null) || return 0
  # Use pushedDate (server-recorded) if available; fail closed if not.
  local _pushed
  _pushed=$(printf '%s' "$_raw" | jq -r '.data?.resource?.commits?.nodes[0]?.commit?.pushedDate // empty' 2>/dev/null) || true
  if [[ -n "$_pushed" ]]; then
    printf '%s' "$_pushed"
    return 0
  fi
  # pushedDate unavailable — return empty so the caller fails closed.
  return 0
}

# check_maintainer_comments <pr_snapshot_json> <head_committer_date_iso> [bot_user]
check_maintainer_comments() {
  local json="${1:-}"
  local head_date="${2:-}"
  local bot_user="${3:-donpetry-bot}"

  # Build excluded-bots JSON lazily on first use. This keeps jq execution inside
  # the function so errors are caught properly and the gate can fail closed.
  if [[ -z "$_MAINTAINER_GATE_EXCLUDED_BOTS_JSON" ]]; then
    _MAINTAINER_GATE_EXCLUDED_BOTS_JSON=$(printf '%s\n' "${MAINTAINER_GATE_EXCLUDED_BOTS[@]}" | jq -R . | jq -sc .) \
      || {
        log_warn "could not build excluded-bots list — failing closed (blocking approval)"
        return 2
      }
  fi

  # Latest maintainer (human, non-agent, non-bot) issue-comment timestamp. A jq
  # failure here (malformed snapshot, or a JSON value that can't be indexed with
  # .comments) exits non-zero → return 2 so undeterminable input fails closed
  # rather than silently reading as "no findings".
  local latest
  latest=$(printf '%s' "$json" | jq -r \
    --arg markers "$_MAINTAINER_GATE_AGENT_MARKERS" \
    --arg botuser "$bot_user" \
    --argjson bots "$_MAINTAINER_GATE_EXCLUDED_BOTS_JSON" '
      [ (.comments // [])[] | objects
        | (.author?.login // "" | tostring) as $l
        | select($l != $botuser and ($bots | index($l)) == null)
        | select(((.body // "") | test($markers)) | not)
        | .createdAt? ]
      | map(select(. != null))
      | sort
      | last // ""
    ' 2>/dev/null) || {
    log_warn "could not parse PR snapshot — failing closed (blocking approval)"
    return 2
  }

  if [[ -z "$latest" ]]; then
    log_info "no unaddressed maintainer issue comments"
    return 0
  fi

  # A maintainer issue comment exists. It is addressed only if a push landed at or
  # after it. When the push time is undeterminable we cannot confirm that, so we
  # fail closed and block (issue #1290).
  if [[ -z "$head_date" ]]; then
    log_warn "maintainer issue comment present but head-commit push time is unknown — failing closed (blocking approval)"
    return 1
  fi

  local latest_epoch head_epoch
  latest_epoch=$(_mcg_to_epoch "$latest") || latest_epoch=""
  head_epoch=$(_mcg_to_epoch "$head_date") || head_epoch=""
  if [[ -z "$latest_epoch" || -z "$head_epoch" ]]; then
    log_warn "could not compare comment/push timestamps — failing closed (blocking approval)"
    return 1
  fi

  if [[ "$latest_epoch" -gt "$head_epoch" ]]; then
    log_warn "latest maintainer issue comment ($latest) postdates the last push ($head_date) — unaddressed, withholding approval (#1290)"
    return 1
  fi

  log_info "latest maintainer issue comment ($latest) predates the last push ($head_date) — treated as addressed"
  return 0
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
  _hd=$(maintainer_gate_head_committer_date "$_pr_url")
  check_maintainer_comments "$_snap" "$_hd" "${BOT_USER:-donpetry-bot}"
  exit $?
fi
