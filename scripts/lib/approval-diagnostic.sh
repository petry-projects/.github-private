#!/usr/bin/env bash
# approval-diagnostic.sh — the single "why is this PR not approved?" diagnostic (#1894).
#
# Ten of eleven open PRs in this repo had never received an approving review, yet
# every component reported healthy: the advisory gate logged "ready to approve",
# the disposition gate logged a dismissal, and the PR's own surface showed only
# `REVIEW_REQUIRED` with no reason. No component owned the END-TO-END question, so
# diagnosing one PR meant reading three scripts and correlating timeline events by
# hand. This library owns that question.
#
# diagnose_approval evaluates the approval gate chain in the SAME ORDER
# review-one-pr.sh applies it and emits ONE structured verdict naming:
#   * blocking_gate  — the gate that withholds approval (or "none" when approved),
#   * condition      — the specific unmet condition, and
#   * satisfied_by   — exactly what would satisfy it.
# It also always reports the advisory denominator RECONCILED with the registry
# (#1894 AC #2): `advisory.required` is the count of advisory_gate=yes logins in
# reviewer-sources.tsv and `advisory.missing` names the bots that have not
# participated, so a partial denominator (the "6 != 7" silent drop) is observable
# rather than hidden inside an effective-total subtraction.
#
# It is PURE — it reads a PR snapshot JSON (the exact object review-one-pr.sh
# already fetches: reviewDecision, headRefOid, reviews, comments, labels) and
# writes JSON / Markdown, doing NO network I/O — so it is unit-tested in
# tests/test_approval_diagnostic.bats and adds no API round-trip on the hot path.
#
# It FAILS CLOSED (mirrors the gates it summarizes): an unparseable snapshot
# returns non-zero and never emits `approved:true`, so an undeterminable state can
# never be read as "nothing wrong" (the AGENTS.md "cannot check ≠ nothing to
# check" rule).

set -euo pipefail

# Agent-comment markers — IDENTICAL to maintainer-comment-gate.sh's
# _MAINTAINER_GATE_AGENT_MARKERS so the diagnostic's undispositioned-comment count
# can never diverge from the gate that actually withholds approval. A comment
# carrying any of these is one of our own automation's replies, never a finding.
readonly _APPROVAL_DIAG_AGENT_MARKERS='<!-- (pr-review-agent|pr-review-claim|persona:|dev-lead|dependency-advisory)[^>]*-->'

# _approval_diag_default_advisory_json
#   The advisory-gate denominator as a JSON array of logins, derived from the
#   reviewer-source registry (advisory_gate=yes) so the diagnostic and the gate
#   share one source of truth. Falls back to the built-in advisory set when the
#   registry is absent/unreadable — never `exit`, matching advisory-review-gate.sh
#   (#1538): this file is sourced into the review process and the test suite.
_approval_diag_default_advisory_json() {
  local reg_sh logins json=""
  reg_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewer-sources.sh"
  if [ -f "$reg_sh" ]; then
    # shellcheck source=scripts/lib/reviewer-sources.sh
    # shellcheck disable=SC1091
    if source "$reg_sh" 2>/dev/null && logins="$(reviewer_sources_advisory_gate_logins 2>/dev/null)" && [ -n "$logins" ]; then
      json="$(printf '%s\n' "$logins" | jq -R . | jq -sc 'map(select(. != ""))')" || json=""
    fi
  fi
  if [ -z "$json" ] || [ "$json" = "[]" ]; then
    json='["copilot-pull-request-reviewer","gemini-code-assist","chatgpt-codex-connector","sonarqubecloud","qodo-code-review","codeant-ai","graphite-app"]'
  fi
  printf '%s' "$json"
}

# diagnose_approval <pr_snapshot_json> [advisory_json] [approver]
#   <pr_snapshot_json> — output of `gh pr view --json reviewDecision,headRefOid,reviews,comments,labels`.
#   [advisory_json]    — JSON array of advisory-gate logins (default: registry projection).
#   [approver]         — the login pr-review approves as (default: donpetry-bot).
#
#   Prints ONE verdict JSON object to stdout:
#     { pr, approved, head_sha, blocking_gate, condition, satisfied_by,
#       advisory: { required, submitted, missing, via_timeout } }
#   Returns 0 on a determinable verdict, 2 when the snapshot cannot be parsed
#   (fail-closed — never emits approved:true in that case).
diagnose_approval() {
  local snap="${1:-}"
  local advisory="${2:-}"
  local approver="${3:-donpetry-bot}"
  [ -n "$advisory" ] || advisory="$(_approval_diag_default_advisory_json)"

  # Extract the raw facts in a single jq pass. A parse failure (malformed snapshot,
  # or a value that can't be indexed) exits non-zero → fail closed.
  local facts
  facts=$(printf '%s' "$snap" | jq -c \
    --argjson advisory "$advisory" \
    --arg approver "$approver" \
    --arg markers "$_APPROVAL_DIAG_AGENT_MARKERS" '
      def approver_logins: [$approver, ($approver | if endswith("[bot]") then .[0:-5] else . end)];
      ($advisory | map(ascii_downcase)) as $adv
      | (.headRefOid // "") as $sha
      | (.reviewDecision // "") as $decision
      # Advisory participants: any advisory login appearing in a review OR a comment.
      | ([ (.reviews // [])[]  | .author.login // "" ]
         + [ (.comments // [])[] | .author.login // "" ]
         | map(ascii_downcase) | unique) as $seen
      | ([ $adv[] | select(. as $b | $seen | index($b)) ] | unique) as $participated
      | ([ $adv[] | select(. as $b | $seen | index($b) | not) ] | sort) as $missing
      # Undispositioned non-agent issue comments (maintainer-comment-gate logic).
      | ([ (.comments // [])[] | objects
           | (.author.login // "" | ascii_downcase) as $l
           | select((approver_logins | map(ascii_downcase) | index($l)) | not)
           | select(((.body // "") | test($markers)) | not)
           | select(((.isMinimized // false) == true)
                    and (((.minimizedReason // "") | ascii_downcase) == "resolved") | not)
         ] | length) as $undispositioned
      | ([ (.reviews // [])[]
           | select((.state // "") == "CHANGES_REQUESTED" and (.commit.oid // "") == $sha) ] | length) as $cr_at_head
      | ([ (.reviews // [])[]
           | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
           | select((.state // "") == "APPROVED" and (.commit.oid // "") == $sha) ] | length) as $appr_at_head
      | { head_sha: $sha,
          decision: $decision,
          required: ($adv | length),
          submitted: ($participated | length),
          missing: $missing,
          undispositioned: $undispositioned,
          cr_at_head: $cr_at_head,
          appr_at_head: $appr_at_head }
    ' 2>/dev/null) || {
    echo "[approval-diagnostic] ERROR: could not parse PR snapshot — failing closed" >&2
    return 2
  }
  if [ -z "$facts" ]; then
    echo "[approval-diagnostic] ERROR: PR snapshot produced no verdict — failing closed" >&2
    return 2
  fi

  local head_sha decision required submitted cr_at_head appr_at_head undispositioned
  head_sha=$(jq -r '.head_sha' <<<"$facts")
  decision=$(jq -r '.decision' <<<"$facts")
  required=$(jq -r '.required' <<<"$facts")
  submitted=$(jq -r '.submitted' <<<"$facts")
  cr_at_head=$(jq -r '.cr_at_head' <<<"$facts")
  appr_at_head=$(jq -r '.appr_at_head' <<<"$facts")
  undispositioned=$(jq -r '.undispositioned' <<<"$facts")

  local approved="false" gate condition satisfied_by via_timeout
  via_timeout=$([ "$submitted" -lt "$required" ] && echo true || echo false)

  # Gate chain, in review-one-pr.sh order. The advisory gate itself never blocks
  # (it always proceeds via a timeout fallback), so it is recorded for
  # observability but is never the blocking_gate. The first gate that WITHHOLDS
  # approval is reported. The blocking gates are checked BEFORE the "an approval
  # already exists at head" fallback, because the maintainer-comment gate DISMISSES
  # a standing approval (the #1813 revocation this issue centers on) — so an
  # undispositioned comment must win over an approval that is about to be revoked.
  if [ "$decision" = "APPROVED" ]; then
    approved="true"
    gate="none"
    condition="the PR has an approving review at head ${head_sha:0:8}"
    satisfied_by=""
  elif [ "$undispositioned" -gt 0 ]; then
    gate="maintainer-comment-gate"
    condition="${undispositioned} PR issue comment(s) lack a verified disposition (not minimized RESOLVED) — #1290/#1813"
    satisfied_by="dev-lead posts a verified disposition reply and the harness minimizes the comment RESOLVED, or an @mention (FORCE_REVIEW) overrides the gate"
  elif [ "$decision" = "CHANGES_REQUESTED" ] && [ "$cr_at_head" -gt 0 ]; then
    gate="changes-requested"
    condition="a CHANGES_REQUESTED review targets the current head commit ${head_sha:0:8}"
    satisfied_by="the reviewer approves, the author pushes a new commit making the review stale, or @mentions the bot for a re-review"
  elif [ "$appr_at_head" -gt 0 ]; then
    # An approving review exists at head and nothing blocks — the reviewDecision is
    # merely lagging (or the ruleset needs more approvers than are present here).
    approved="true"
    gate="none"
    condition="an approving review from ${approver} exists at head ${head_sha:0:8}"
    satisfied_by=""
  else
    gate="approval-not-yet-issued"
    condition="no approving review from ${approver} exists at head ${head_sha:0:8}; approval would issue on ${submitted}/${required} advisory evidence via the gate timeout fallback"
    satisfied_by="pr-review re-runs and issues its approving review — an advisory bot's pull_request_review event or the scheduled pr-review sweep re-triggers it"
  fi

  local pr_ref="${PR_URL:-}"
  jq -cn \
    --arg pr "$pr_ref" \
    --argjson approved "$approved" \
    --arg head_sha "$head_sha" \
    --arg gate "$gate" \
    --arg condition "$condition" \
    --arg satisfied_by "$satisfied_by" \
    --argjson required "$required" \
    --argjson submitted "$submitted" \
    --argjson missing "$(jq -c '.missing' <<<"$facts")" \
    --argjson via_timeout "$via_timeout" '
    { pr: $pr, approved: $approved, head_sha: $head_sha,
      blocking_gate: $gate, condition: $condition, satisfied_by: $satisfied_by,
      advisory: { required: $required, submitted: $submitted, missing: $missing, via_timeout: $via_timeout } }'
}

# render_approval_diagnostic <verdict_json>
#   PURE Markdown renderer for the step summary / a PR marker. Turns the verdict
#   into the block an operator reads instead of correlating three scripts by hand.
render_approval_diagnostic() {
  local verdict="${1:-}"
  local approved gate condition satisfied_by required submitted missing via_timeout
  approved=$(jq -r '.approved' <<<"$verdict" 2>/dev/null) || { echo "_approval diagnostic unavailable (unparseable verdict)_"; return 0; }
  gate=$(jq -r '.blocking_gate' <<<"$verdict")
  condition=$(jq -r '.condition' <<<"$verdict")
  satisfied_by=$(jq -r '.satisfied_by' <<<"$verdict")
  required=$(jq -r '.advisory.required' <<<"$verdict")
  submitted=$(jq -r '.advisory.submitted' <<<"$verdict")
  missing=$(jq -r '.advisory.missing | join(", ")' <<<"$verdict")
  via_timeout=$(jq -r '.advisory.via_timeout' <<<"$verdict")

  printf '### Approval diagnostic\n\n'
  if [ "$approved" = "true" ]; then
    printf -- '- **Status:** APPROVED — %s.\n' "$condition"
  else
    # shellcheck disable=SC2016  # backticks are literal Markdown code spans, not command substitution
    printf -- '- **Not approved.** Blocking gate: `%s`.\n' "$gate"
    printf -- '- **Condition:** %s\n' "$condition"
    printf -- '- **Satisfied by:** %s\n' "$satisfied_by"
  fi
  printf -- '- **Advisory evidence:** %s/%s registered advisory bots participated' "$submitted" "$required"
  if [ "$via_timeout" = "true" ]; then
    printf ' (approval issues via the timeout fallback — partial evidence)'
  fi
  printf '.\n'
  if [ -n "$missing" ]; then
    printf -- '- **Advisory bots not participating:** %s.\n' "$missing"
  fi
  printf '\n'
}

# Run standalone against a PR URL (only if executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  _pr_url="${1:-}"
  if [[ -z "$_pr_url" ]]; then
    echo "usage: approval-diagnostic.sh <pr-url>" >&2
    exit 2
  fi
  export PR_URL="$_pr_url"
  _snap=$(gh pr view "$_pr_url" --json reviewDecision,headRefOid,reviews,comments,labels 2>/dev/null) || {
    echo "[approval-diagnostic] ERROR: gh pr view failed for $_pr_url" >&2
    exit 2
  }
  _verdict=$(diagnose_approval "$_snap" "" "${BOT_USER:-donpetry-bot}") || exit $?
  printf '%s\n' "$_verdict"
  render_approval_diagnostic "$_verdict" >&2
fi
