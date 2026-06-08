#!/usr/bin/env bash
# tests/aw/issue-triage/test_aw_run.sh
#
# Unit tests for aw.sh paths that do not require a live Claude call.
# Covers: skip guard, safe-output label validation, safe-output skip no-op.
#
# Run: bash tests/aw/issue-triage/test_aw_run.sh
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}FAIL  $1: $2\n"; printf 'FAIL  %s: %s\n' "$1" "$2"; }

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURES="$(dirname "$0")/fixtures"

# ---------------------------------------------------------------------------
# Test 1: Scenario 4 — issue already has 2 labels → aw run emits {"skip":true}
# ---------------------------------------------------------------------------
result=$(bash "$REPO_ROOT/scripts/aw.sh" run issue-triage \
  --fixture "$FIXTURES/scenario-4-skip.json" --staged)
skip=$(AW_RESULT="$result" python3 - <<'PYEOF'
import json, os
print(json.loads(os.environ['AW_RESULT']).get('skip', False))
PYEOF
)
if [[ "$skip" == "True" ]]; then
  ok "scenario-4: 2 existing labels → skip=true"
else
  fail "scenario-4: 2 existing labels → skip=true" "got skip=$skip, result=$result"
fi

# ---------------------------------------------------------------------------
# Test 2: safe-output rejects result with more labels than max-labels (3)
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["bug","needs-triage","question","enhancement"],"comment":"Hello!"}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1 || true)
if echo "$output" | grep -q "rejected"; then
  ok "safe-output: 4 labels exceeds max-labels:3 → rejected"
else
  fail "safe-output: 4 labels exceeds max-labels:3 → rejected" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 3: safe-output rejects a label not in the allowed set
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["not-a-real-label"],"comment":"Hello!"}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1 || true)
if echo "$output" | grep -q "rejected"; then
  ok "safe-output: disallowed label → rejected"
else
  fail "safe-output: disallowed label → rejected" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 4: safe-output with skip flag → no-op, prints skip message
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"skip":true}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1)
if echo "$output" | grep -q "skip flag set"; then
  ok "safe-output: skip flag → no writes"
else
  fail "safe-output: skip flag → no writes" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 5: safe-output rejects result with empty comment
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["bug"],"comment":""}' > "$tmp"
output=$(ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1 || true)
if echo "$output" | grep -q "rejected"; then
  ok "safe-output: empty comment → rejected"
else
  fail "safe-output: empty comment → rejected" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Test 6: safe-output accepts valid labels + comment → validation passed
# ---------------------------------------------------------------------------
tmp=$(mktemp)
printf '{"labels":["bug","needs-triage"],"comment":"Thank you for the report!"}' > "$tmp"
mock_dir=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "$mock_dir/gh"
chmod +x "$mock_dir/gh"
output=$(PATH="$mock_dir:$PATH" ISSUE_NUMBER=1 GITHUB_REPOSITORY=example/repo \
  bash "$REPO_ROOT/scripts/aw.sh" safe-output apply issue-triage "$tmp" 2>&1)
rm -rf "$mock_dir"
if echo "$output" | grep -q "validation passed"; then
  ok "safe-output: valid allowed labels → validation passed"
else
  fail "safe-output: valid allowed labels → validation passed" "got: $output"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%b' "$ERRORS"
  exit 1
fi
