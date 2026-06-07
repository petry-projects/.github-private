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
  "on-mention.md"
  "review-changes.md"
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

# ── 4. review prompts must reply-with-specifics, then resolve ────────────────
# Regression for issue #452: dev-lead resolved (or silently left) review threads
# without replying what it fixed, and bot threads fixed during another
# reviewer's run stayed unresolved. Each review prompt must instruct the engine
# to post a thread reply (addPullRequestReviewThreadReply) describing the
# specific change, then resolve the thread (resolveReviewThread).

echo ""
echo "Checking review prompts reply-with-specifics then resolve..."
REVIEW_PROMPTS=("fix-reviews.md" "review-changes.md" "fix-bot-comment.md")
for prompt in "${REVIEW_PROMPTS[@]}"; do
  path="$PROMPTS_DIR/$prompt"
  [ -f "$path" ] || { echo "  FAIL: $prompt — missing"; FAILED=1; continue; }
  missing=""
  grep -q "addPullRequestReviewThreadReply" "$path" || missing="$missing reply-mutation"
  grep -q "resolveReviewThread"             "$path" || missing="$missing resolve-mutation"
  grep -qiE "specific(ally)?" "$path"               || missing="$missing specific-details"
  if [ -n "$missing" ]; then
    echo "  FAIL: $prompt — missing:$missing"
    FAILED=1
  else
    echo "  ok: $prompt (replies with specifics, then resolves)"
  fi
done

# ── 5. every OPEN_THREADS_JSON build must expose author.__typename ────────────
# Regression for issue #452: GraphQL omits the "[bot]" suffix from bot logins,
# so the prompts identify bots by author.__typename == "Bot". Every reviewThreads
# query that feeds OPEN_THREADS_JSON must therefore select __typename — both the
# fix-reviews build AND the review-changes build (the latter was missed).

echo ""
echo "Checking OPEN_THREADS_JSON queries expose author.__typename..."
DRIVER="$(dirname "$0")/../../../scripts/dev-lead-fix-reviews.sh"
author_sel_total=$(grep -c 'comments(first:5) { nodes { body author {' "$DRIVER" 2>/dev/null || echo 0)
author_sel_typename=$(grep -c 'comments(first:5) { nodes { body author { login __typename } }' "$DRIVER" 2>/dev/null || echo 0)
if [ "$author_sel_total" -eq 0 ]; then
  echo "  FAIL: no OPEN_THREADS_JSON author selection found in $(basename "$DRIVER")"
  FAILED=1
elif [ "$author_sel_total" -ne "$author_sel_typename" ]; then
  echo "  FAIL: $((author_sel_total - author_sel_typename)) of $author_sel_total OPEN_THREADS_JSON build(s) omit author.__typename"
  FAILED=1
else
  echo "  ok: all $author_sel_total OPEN_THREADS_JSON build(s) select author.__typename"
fi

# ── result ────────────────────────────────────────────────────────────────────

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "FAIL: prompt coverage check failed"
  exit 1
fi

echo "PASS: all prompts have correct variable declarations"
