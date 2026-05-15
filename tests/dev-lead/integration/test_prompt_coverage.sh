#!/usr/bin/env bash
set -euo pipefail
# Integration test: verify all dev-lead prompts have correct variable declarations.
#
# Checks:
#   1. All 7 expected prompt files exist
#   2. Each prompt has a <!-- VARIABLES: --> comment
#   3. All ${VAR} references in each prompt are declared in that comment

PROMPTS_DIR="$(dirname "$0")/../../../prompts/dev-lead"
FAILED=0

# ── 1. check all 7 prompts exist ─────────────────────────────────────────────

EXPECTED_PROMPTS=(
  "fix-ci.md"
  "fix-reviews.md"
  "fix-bot-comment.md"
  "human.md"
  "human-pr.md"
  "fix-issue.md"
  "rebase.md"
)

echo "Checking prompt files exist..."
for prompt in "${EXPECTED_PROMPTS[@]}"; do
  path="$PROMPTS_DIR/$prompt"
  if [ ! -f "$path" ]; then
    echo "  FAIL: missing prompt file: $path"
    FAILED=1
  else
    echo "  ok: $prompt"
  fi
done

# ── 2. check VARIABLES comment + 3. check variable coverage ──────────────────

echo ""
echo "Checking variable declarations..."
for prompt in "${EXPECTED_PROMPTS[@]}"; do
  path="$PROMPTS_DIR/$prompt"
  [ -f "$path" ] || continue

  # Extract declared variables from <!-- VARIABLES: VAR1, VAR2, ... --> comment
  declared_line=$(grep -oP '(?<=<!-- VARIABLES: )[^>]+(?= -->)' "$path" 2>/dev/null | head -1 || true)

  if [ -z "$declared_line" ]; then
    echo "  FAIL: $prompt — missing <!-- VARIABLES: ... --> comment"
    FAILED=1
    continue
  fi

  # Build declared vars as a space-delimited list
  declared_vars=$(echo "$declared_line" | tr ',' '\n' | tr -d ' ' | sort -u)

  # Extract ${VAR} style references used in file
  used_vars=$(grep -oP '\$\{[A-Z_]+\}' "$path" 2>/dev/null | sed 's/[${}]//g' | sort -u || true)

  if [ -z "$used_vars" ]; then
    echo "  ok: $prompt (no variables used)"
    continue
  fi

  prompt_failed=0
  while IFS= read -r var; do
    [ -z "$var" ] && continue
    if ! echo "$declared_vars" | grep -qx "$var"; then
      echo "  FAIL: $prompt — \${$var} used but not declared in VARIABLES comment"
      FAILED=1
      prompt_failed=1
    fi
  done <<< "$used_vars"

  if [ "$prompt_failed" -eq 0 ]; then
    echo "  ok: $prompt (declared: $(echo "$declared_vars" | tr '\n' ',' | sed 's/,$//') )"
  fi
done

# ── result ────────────────────────────────────────────────────────────────────

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "FAIL: prompt coverage check failed"
  exit 1
fi

echo "PASS: all prompts have correct variable declarations"
