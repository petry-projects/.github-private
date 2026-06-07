#!/usr/bin/env bash
# Shared helpers for the PR-review cascade's cycle cap (issue #467).
#
# The cycle cap exists to break non-converging fix-request ping-pong loops
# (review requests fixes → dev-lead applies → review requests more fixes).
# It must NOT fire on PRs that are converging: approvals and history that
# predates a human escalation do not count toward the cap.
#
# All functions take a JSON array of `{when, body}` items — every review and
# comment on the PR, tagged with its timestamp (reviews' submittedAt,
# comments' createdAt). ISO-8601 timestamps compare correctly as strings.
#
# Marker formats found in the wild (see prompts/single-review.md,
# prompts/synthesize.md, scripts/post-pr-review.sh, scripts/backfill-review-markers.sh):
#   approval review:   <!-- pr-review-agent v1 sha=<SHA> decision=approved risk=... -->
#   escalated review:  <!-- pr-review-agent v1 sha=<SHA> decision=escalated risk=... -->
#   fix-request:       <!-- pr-review-agent v1 sha=<SHA> --> <!-- decision=fix-requested risk=... -->
#   human escalation:  <!-- pr-review-agent escalation -->
#
# Superseded comments are edited in place (createdAt preserved) and keep the
# original markers inside a <details> block, so markers and timestamps remain
# meaningful for counting.

# Shared jq predicate definitions, prepended to every program below.
_REVIEW_CYCLE_JQ_DEFS='
  def has_marker: (.body // "") | test("<!-- pr-review-agent v1 sha=[a-f0-9]+");
  def is_approval: (.body // "") | test("<!-- pr-review-agent v1 sha=[a-f0-9]+\\s+decision=approved");
  def is_escalation: (.body // "") | test("<!-- pr-review-agent escalation -->");
'

# compute_review_cycle <items_json>
#   Prints the number of NON-CONVERGING review cycles: v1 markers that are not
#   approvals, posted after the most recent reset event. Reset events:
#     - the latest approval marker (the cascade converged; later cycles are a
#       fresh attempt on an evolved PR, not a continuation of an old loop)
#     - the latest `<!-- pr-review-agent escalation -->` comment (a human was
#       brought in; re-engagement starts with a fresh budget)
#   With no reset event present, all non-approval markers count.
compute_review_cycle() {
  local items_json="${1:-[]}"
  local count
  count=$(jq -r "$_REVIEW_CYCLE_JQ_DEFS"'
    map(select(.when != null and .when != ""))
    | ([.[] | select(is_approval)   | .when] | max // "") as $last_approval
    | ([.[] | select(is_escalation) | .when] | max // "") as $last_escalation
    | (if $last_approval > $last_escalation then $last_approval else $last_escalation end) as $reset
    | [.[] | select(has_marker and (is_approval | not) and (.when > $reset))]
    | length
  ' <<<"$items_json" 2>/dev/null) || count=0
  # Defensive: malformed input must degrade to 0, not break the integer
  # comparison at the cycle cap ("integer expression expected").
  case "$count" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$count" ;;
  esac
}

# has_escalation_marker <items_json>
#   Exit 0 if any review/comment carries the human-escalation marker.
has_escalation_marker() {
  local items_json="${1:-[]}"
  jq -e "$_REVIEW_CYCLE_JQ_DEFS"'
    any(.[]; is_escalation)
  ' <<<"$items_json" >/dev/null 2>&1
}
