#!/usr/bin/env bash
# partial-evidence-marker.sh — record advisory-gate timeout approvals (issue #1596).
#
# When the advisory-review gate proceeds via a timeout fallback (head-age /
# quiescence), the approval is issued on PARTIAL advisory evidence: fewer than all
# registered bots reported. The timeout is a liveness protection, but it silently
# converts "all reviewers agreed" into "the ones that answered agreed". Stamping a
# marker on the PR makes that fact machine-detectable so the deterministic miss-rate
# metric (scripts/lib/pr-review-miss-rate.sh) can count partial_evidence_approvals,
# and so a standing approval is never read as stronger evidence than it is.
#
# Sourced by scripts/lib/advisory-review-gate.sh. The posting helper uses the gate's
# log_info/log_warn (resolved at call time) and `gh`; the pure builder needs neither.

# advisory_partial_evidence_marker <head_sha> <submitted> <required> <reason>
#   PURE: returns the marker string. The prefix ("partial-evidence" before v1)
#   deliberately never matches the idempotency marker regex nor the rate-limited
#   marker regex.
advisory_partial_evidence_marker() {
  local head_sha="${1:-}" submitted="${2:-0}" required="${3:-0}" reason="${4:-timeout}"
  printf '<!-- pr-review-agent partial-evidence v1 sha=%s submitted=%s required=%s reason=%s -->' \
    "$head_sha" "$submitted" "$required" "$reason"
}

# maybe_post_partial_evidence_marker <pr_url> <head_sha> <submitted> <required> <reason> <comments_json>
#   Posts a deduplicated partial-evidence marker recording that this approval was
#   issued before all advisory bots reported. <comments_json> is the already-fetched
#   PR snapshot (.comments[]) used for the dedup check, so no extra API call is
#   needed to decide whether to post. Guarded: without pr_url + head_sha it is a
#   silent no-op (so unit tests that never set a head SHA make no network call).
maybe_post_partial_evidence_marker() {
  local pr_url="${1:-}" head_sha="${2:-}" submitted="${3:-0}" required="${4:-0}" reason="${5:-timeout}" comments_json="${6:-}"
  if [[ -z "$pr_url" || -z "$head_sha" ]]; then
    log_info "partial-evidence marker skipped (pr_url/head_sha unavailable)"
    return 0
  fi

  local marker
  marker="$(advisory_partial_evidence_marker "$head_sha" "$submitted" "$required" "$reason")"

  # Dedup: skip if a partial-evidence marker already exists at this exact head.
  local cj="$comments_json"
  [[ -z "$cj" ]] && cj='{}'
  local already
  already=$(jq -r --arg sha "$head_sha" '
    [ (.comments // [])[]
      | (.body // "")
      | select(contains("<!-- pr-review-agent partial-evidence v1 sha=" + $sha)) ]
    | length' <<< "$cj" 2>/dev/null || echo 0)
  if [[ "${already:-0}" -gt 0 ]]; then
    log_info "Partial-evidence marker already present at head ${head_sha:0:8} — not re-posting"
    return 0
  fi

  local body="${marker}
pr-review approved on PARTIAL advisory evidence: ${submitted}/${required} registered advisory bots reported before the gate's ${reason} fallback proceeded. Recorded for the miss-rate metric (#1596)."

  if gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
    log_info "Posted partial-evidence marker on $pr_url (head ${head_sha:0:8}, ${submitted}/${required}, ${reason})"
  else
    log_warn "Failed to post partial-evidence marker on $pr_url"
    return 1
  fi
}
