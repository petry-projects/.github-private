#!/usr/bin/env bash
# PR-metadata digest for the reviewed-state fingerprint (issue #1551).
#
# The already-reviewed-at-head fingerprint is the head SHA alone. A metadata-only
# fix-requested verdict demands a fix (PR body / labels / linked-issue edit) that
# produces NO new commit, so the head SHA never changes and every re-review
# no-ops with `already-reviewed-at-head` — a guaranteed deadlock (PR #1531).
#
# This lib adds the second half of the fingerprint for *metadata-only*
# fix-requests: a digest over the three metadata surfaces AC2 names — the PR
# body, its closing-issue references, and its labels. The writer
# (post-pr-review.sh) stamps `meta=<digest>` into the fix-request marker; the
# reader (review-one-pr.sh) recomputes the digest at re-review time and re-arms
# when it differs. Approval markers and code-change fix-requests carry no `meta=`
# and keep the exact same-SHA no-op behavior (AC3) — the digest is scoped to
# markers that opt in, so it can never create a re-review churn vector.

# compute_pr_metadata_digest <snapshot_json>
#   Echo a stable 16-hex digest of the PR's metadata surface. <snapshot_json> is
#   any object carrying `body`, `closingIssuesReferences`, and `labels` (a `gh pr
#   view --json body,closingIssuesReferences,labels` payload, or the fuller review
#   snapshot). Closing refs and labels are sorted so their order does not perturb
#   the digest; fields outside the metadata surface are ignored. Missing fields
#   degrade to empty/[], never an error — a stray input must not break the caller.
compute_pr_metadata_digest() {
  local snapshot_json="${1:-}"
  [ -n "$snapshot_json" ] || snapshot_json='{}'
  local canonical
  canonical=$(jq -cS -n --argjson s "$snapshot_json" '{
    body: ($s.body // ""),
    closes: ([$s.closingIssuesReferences[]?.number] | sort),
    labels: ([$s.labels[]?.name] | sort)
  }' 2>/dev/null) || canonical=""
  printf '%s' "$canonical" | sha256sum | cut -c1-16
}

# marker_meta_digest <marker_body>
#   Echo the `meta=<hex>` digest stamped in a fix-request marker body, or nothing
#   when absent (approval markers and code-change fix-requests carry no `meta=`).
marker_meta_digest() {
  local body="${1:-}"
  printf '%s' "$body" | grep -oE 'meta=[a-f0-9]+' | head -1 | cut -d= -f2 || true
}
