#!/usr/bin/env bash
# Validates dev-lead's concurrency model: per-PR and per-issue lanes with
# cancel-in-progress:false, which serialize runs WITHIN a PR/issue (one active
# run at a time, the rest queued) while letting unrelated PRs/issues proceed in
# their own lanes.
#
# Same-PR serialization matters: two dev-lead runs editing one PR's branch in
# parallel would push over each other (and, with auto-merge on, race a merge).
# A per-PR group + cancel-in-progress:false is what guarantees one-at-a-time.
#
# Regression note: this previously asserted a single repo-wide 'dev-lead' group
# (#278). #450 replaced that with per-PR/per-issue lanes so issue pickups are no
# longer cancelled by unrelated PR traffic — this test was updated to match.
set -euo pipefail

FAIL=0

# check_concurrency_field: grep within the concurrency: YAML block only.
# Extracts lines from '^concurrency:' to the next top-level key, then strips
# comment-only lines so the assertion cannot be satisfied by comment text
# (dev-lead-reusable.yml has the routing strings in comments at lines 33-39;
# without this isolation, deleting the actual concurrency.group entries would
# leave the test green).
check_concurrency_field() {
  local file="$1" pattern="$2" label="$3"
  local block
  block=$(awk '/^concurrency:/{found=1} found && /^[a-z]/ && !/^concurrency:/{found=0} found{print}' "$file" \
    | grep -v '^\s*#')
  if printf '%s\n' "$block" | grep -qF "$pattern"; then
    echo "PASS [$label]: '$pattern' present in concurrency YAML of $(basename "$file")"
  else
    echo "FAIL [$label]: '$pattern' not found in concurrency YAML of $file"
    FAIL=$((FAIL + 1))
  fi
}

# Both the inline caller workflow and the reusable workflow must carry the same
# routing, so external callers get identical per-PR serialization.
WORKFLOWS=(
  ".github/workflows/dev-lead.yml"
  ".github/workflows/dev-lead-reusable.yml"
)

for wf in "${WORKFLOWS[@]}"; do
  # Per-PR lane → serializes all runs touching one PR (PR, review, review
  # comment, issue_comment-on-PR, and repository_dispatch all map here).
  check_concurrency_field "$wf" "dev-lead-pr-" "per-PR serialization lane"
  # Per-issue lane → serializes runs working a single issue.
  check_concurrency_field "$wf" "dev-lead-issue-" "per-issue serialization lane"
  # ci-relay keeps its own ephemeral per-SHA slot so it fires without blocking
  # or being blocked by the dispatch queue.
  check_concurrency_field "$wf" "dev-lead-ci-relay-" "ci-relay per-SHA group"
  # cancel-in-progress:false is what makes same-lane runs QUEUE (serialize)
  # rather than cancel — dropping queued runs would lose pickups.
  check_concurrency_field "$wf" "cancel-in-progress: false" "cancel-in-progress is false"
done

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All concurrency config checks passed."
else
  echo "$FAIL check(s) failed."
  exit 1
fi
