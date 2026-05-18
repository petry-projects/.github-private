#!/usr/bin/env bash
# Validates that dev-lead workflow files use per-repo serialized concurrency
# (a single 'dev-lead' group) rather than per-PR or per-issue groups.
set -euo pipefail

FAIL=0

check_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file"; then
    echo "FAIL [$label]: '$pattern' found in $file (should have been removed)"
    FAIL=$((FAIL + 1))
  else
    echo "PASS [$label]: '$pattern' absent"
  fi
}

check_present() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file"; then
    echo "PASS [$label]: '$pattern' present"
  else
    echo "FAIL [$label]: '$pattern' not found in $file"
    FAIL=$((FAIL + 1))
  fi
}

WORKFLOW=".github/workflows/dev-lead.yml"

# Must not have per-PR or per-issue group keys (those allowed parallel runs)
check_absent "$WORKFLOW" "dev-lead-pr-"    "no per-PR group"
check_absent "$WORKFLOW" "dev-lead-issue-" "no per-issue group"

# ci-relay must still get its own ephemeral per-SHA slot
check_present "$WORKFLOW" "dev-lead-ci-relay-" "ci-relay per-SHA group preserved"

# The fallback group must be the bare repo-scoped key
check_present "$WORKFLOW" "'dev-lead'" "per-repo 'dev-lead' fallback group"

# cancel-in-progress must be false so queued runs aren't dropped
check_present "$WORKFLOW" "cancel-in-progress: false" "cancel-in-progress is false"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All concurrency config checks passed."
else
  echo "$FAIL check(s) failed."
  exit 1
fi
