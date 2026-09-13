#!/usr/bin/env bash
set -euo pipefail
# standing-approval.sh — the authoritative "does an approving review STAND at
# head?" primitive shared by the sweep (scripts/sweep-stuck-reviews.sh) and the
# stall/stranded-approval detector (scripts/lib/pr-stall-detect.sh). Issue #1665.
#
# The bug it fixes: a `decision=approved` MARKER STRING is NOT proof of a standing
# approval. The pr-review cascade stamps its verdict into a review body, but that
# same marker can outlive the approval it recorded:
#   • a DISMISSED review (state != APPROVED) still carries the marker, yet the
#     approval no longer stands, and
#   • an approval marker can be posted as a plain issue COMMENT, which is not a
#     review at all.
# In both cases GitHub still wants a review (reviewDecision stays REVIEW_REQUIRED)
# and the PR must be re-dispatched, not stranded. So the count here binds the
# approval to a NON-DISMISSED, state==APPROVED REVIEW that carries the approval
# marker for the CURRENT head — the same authority GitHub itself uses.

# pr_standing_approval_count <snapshot_json> <head_sha>
#   Echo the number of reviews that STAND as an approval at <head_sha>: a review
#   whose state is exactly "APPROVED" (so a DISMISSED review never counts) AND
#   whose body carries the cascade's approval marker for this head
#   (`<!-- pr-review-agent v1 sha=<HEAD> decision=approved ... -->`). Comments are
#   ignored — an approval marker in an issue comment is not a review.
#
#   Match the sha followed by whitespace so one sha is never a prefix of another
#   (abc12 must not be satisfied by a marker for abc123), and require the
#   `decision=approved` token so a bare/orphan marker in an APPROVED review does
#   not masquerade as a verdict.
#
#   Fails OPEN to 0 (#1665 AC5): malformed JSON, a missing state, or any jq error
#   yields 0 so an indeterminate approval never suppresses a re-dispatch.
pr_standing_approval_count() {
  local snapshot="${1:-}" sha="${2:-}"
  jq -r --arg sha "$sha" '
    [ (.reviews // [])[]
      | select(((.state // "") == "APPROVED")
               and ((.body // "")
                    | test("<!-- pr-review-agent v1 sha=" + $sha + "\\s+decision=approved\\b"))) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0
}
