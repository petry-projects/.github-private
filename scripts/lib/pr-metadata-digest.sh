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
  # Portable hash: macOS/BSD ships `shasum -a 256`, not GNU `sha256sum`. Under the
  # callers' `set -o pipefail`, a missing `sha256sum` would fail the whole pipeline,
  # so probe a fallback chain before hashing.
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$canonical" | sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$canonical" | shasum -a 256 | cut -c1-16
  elif command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$canonical" | md5sum | cut -c1-16
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$canonical" | md5 | cut -c1-16
  else
    # Fallback: use cksum (POSIX checksum) converted to hex to ensure valid output.
    # cksum computes a CRC; convert to hex and pad to 16 chars.
    printf '%s' "$canonical" | cksum 2>/dev/null | awk '{printf "%016x\n", $1}' || printf '%016x\n' 0
  fi
}

# marker_meta_digest <marker_body>
#   Echo the `meta=<hex>` digest stamped in a fix-request marker body, or nothing
#   when absent (approval markers and code-change fix-requests carry no `meta=`).
#   The match is scoped to the `decision=fix-requested … meta=<hex>` marker header
#   (`[^>]*` keeps it inside the same HTML comment) so a stray `meta=deadbeef` in
#   review findings or an approval explanation can never opt a non-fix-request
#   marker into metadata re-arming. Uses Bash parameter expansion instead of a
#   `head -1` pipe, which can raise SIGPIPE (exit 141) under the callers' pipefail.
marker_meta_digest() {
  local body="${1:-}"
  local match
  match=$(printf '%s' "$body" | grep -oE 'decision=fix-requested[^>]*meta=[a-f0-9]+' || true)
  match="${match%%$'\n'*}"
  printf '%s' "${match##*meta=}"
}
