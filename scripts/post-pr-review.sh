#!/usr/bin/env bash
# Post a PR review based on a verdict JSON.
#
# Inputs:
#   $1 — PR URL
#   $2 — path to verdict JSON (contains decision, risk, summary, findings, body)
#   $3 — DRY_RUN (true/false)
#
# Verdict JSON format:
#   {
#     "decision": "approve|escalate",
#     "risk": "LOW|MEDIUM|HIGH",
#     "summary": "...",
#     "findings": [...],
#     "body": "full markdown review body",
#     "escalate_to_ai": false
#   }

set -euo pipefail

PR_URL="${1:?usage: post-pr-review.sh <pr-url> <verdict-json> <dry-run>}"
VERDICT_JSON="${2:?}"
DRY_RUN="${3:-false}"
PR_HEAD_SHA="${PR_HEAD_SHA:?PR_HEAD_SHA must be set}"

if [ ! -f "$VERDICT_JSON" ]; then
  echo "ERROR: verdict JSON not found at $VERDICT_JSON"
  exit 1
fi

# Extract fields from verdict
DECISION=$(jq -r '.decision' "$VERDICT_JSON")
RISK=$(jq -r '.risk' "$VERDICT_JSON")
BODY=$(jq -r '.body' "$VERDICT_JSON")

# mark_prior_agent_items_obsolete <pr_url>
# After successfully posting a new review/comment, dismiss prior agent reviews
# (state != DISMISSED) and collapse prior agent comments. Identifies agent
# items by the body marker `<!-- pr-review-agent v1 sha=<HEX> -->`. The newest
# agent item by timestamp (which is the just-posted one) is preserved.
# Idempotent: prior comments already wrapped in a `<!-- pr-review-agent
# superseded -->` sentinel are skipped to avoid recursive nesting.
#
# API failures here do NOT abort the workflow — the new post has already
# landed. They DO emit ::warning:: annotations so silent stack-up of
# duplicates becomes visible in the Actions UI rather than degrading
# unnoticed (e.g., a permissions change on the dismissal endpoint).
mark_prior_agent_items_obsolete() {
  local pr_url="$1"
  local owner_repo pr_num
  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  pr_num=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')

  # Stage the API responses to disk. Routing the JSON through shell vars
  # (or --argjson) breaks on rare unescaped control chars in user-authored
  # comment bodies — jq sees raw control characters and refuses to parse.
  # Reading from a file with `jq ... <file>` sidesteps this entirely.
  local reviews_file comments_file fetch_err
  reviews_file=$(mktemp)
  comments_file=$(mktemp)
  if ! gh api --paginate "repos/$owner_repo/pulls/$pr_num/reviews" >"$reviews_file" 2>/tmp/agent-cleanup-err.$$; then
    fetch_err=$(cat /tmp/agent-cleanup-err.$$ 2>/dev/null || true)
    rm -f /tmp/agent-cleanup-err.$$ "$reviews_file" "$comments_file"
    echo "::warning::cleanup: failed to list reviews for $pr_url — duplicates may stack until resolved. API said: $fetch_err"
    return 0
  fi
  rm -f /tmp/agent-cleanup-err.$$
  if ! gh api --paginate "repos/$owner_repo/issues/$pr_num/comments" >"$comments_file" 2>/tmp/agent-cleanup-err.$$; then
    fetch_err=$(cat /tmp/agent-cleanup-err.$$ 2>/dev/null || true)
    echo "::warning::cleanup: failed to list comments for $pr_url — stale comments may persist until resolved. API said: $fetch_err"
    echo '[]' > "$comments_file"
  fi
  rm -f /tmp/agent-cleanup-err.$$

  # Compute the timestamp of the just-posted item: the globally-latest agent
  # item across BOTH reviews and comments (whichever category we just posted
  # to). Items at this timestamp are preserved; everything else is stale.
  # An earlier version preserved "newest of each category" separately, which
  # incorrectly left a stale comment in place when the new post was a review
  # (or vice versa).
  local newest_when
  newest_when=$(jq -rn --slurpfile r "$reviews_file" --slurpfile c "$comments_file" '
    (($r[0] // []) | map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))) | .submitted_at)) +
    (($c[0] // []) | map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))) | .created_at))
    | max // ""
  ' 2>/dev/null || true)

  # Reviews: dismiss every prior agent review except the just-posted one.
  # State must be APPROVED, COMMENTED, or CHANGES_REQUESTED to be dismissable;
  # DISMISSED ones are already handled, and PENDING ones aren't ours.
  local stale_review_ids
  stale_review_ids=$(jq -r --arg keep "$newest_when" '
    map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))))
    | map(select(.submitted_at != $keep))
    | .[]
    | select(.state == "APPROVED" or .state == "COMMENTED" or .state == "CHANGES_REQUESTED")
    | .id
  ' "$reviews_file" 2>/dev/null || true)

  local dismiss_err current_state
  if [ -n "$stale_review_ids" ]; then
    while IFS= read -r review_id; do
      [ -z "$review_id" ] && continue
      # Re-check the review's current state to avoid 422s from race conditions
      # (state may have changed between enumeration and dismissal).
      current_state=$(gh api "repos/$owner_repo/pulls/$pr_num/reviews/$review_id" \
        --jq '.state' 2>/dev/null || echo "UNKNOWN")
      case "$current_state" in
        APPROVED|COMMENTED|CHANGES_REQUESTED)
          echo "  dismissing prior agent review $review_id (superseded by $PR_HEAD_SHA)"
          dismiss_err=$(gh api -X PUT "repos/$owner_repo/pulls/$pr_num/reviews/$review_id/dismissals" \
            -f message="Superseded by automated re-review at $PR_HEAD_SHA." \
            2>&1 >/dev/null) || {
            echo "::warning::cleanup: failed to dismiss prior agent review $review_id on $pr_url — duplicates will stack until resolved. API said: $(echo "$dismiss_err" | head -3 | tr '\n' ' ')"
          }
          ;;
        *)
          echo "  skipping review $review_id (state: $current_state — already dismissed or not dismissable)"
          ;;
      esac
    done <<< "$stale_review_ids"
  fi

  # Comments: edit each prior agent comment to wrap its body in a collapsed
  # <details> block. The sentinel `<!-- pr-review-agent superseded -->`
  # prevents re-wrapping on subsequent runs. Pull just the IDs here and
  # re-fetch each body individually — keeping the body off the shell pipeline
  # avoids the same control-char issue noted on the file-staging block above.
  local stale_comment_ids
  stale_comment_ids=$(jq -r --arg keep "$newest_when" '
    map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))))
    | map(select(.created_at != $keep))
    | .[]
    | select(.body | test("<!-- pr-review-agent superseded -->") | not)
    | .id
  ' "$comments_file" 2>/dev/null || true)

  local edit_err old_body new_body
  if [ -n "$stale_comment_ids" ]; then
    while IFS= read -r cid; do
      [ -z "$cid" ] && continue
      echo "  collapsing prior agent comment $cid (superseded by $PR_HEAD_SHA)"
      old_body=$(gh api "repos/$owner_repo/issues/comments/$cid" --jq '.body' 2>/dev/null) || {
        echo "::warning::cleanup: failed to fetch prior agent comment $cid on $pr_url — skipping collapse"
        continue
      }
      new_body=$(printf '<!-- pr-review-agent superseded -->\n<details><summary><em>Superseded by automated re-review at <code>%s</code> — click to expand prior review.</em></summary>\n\n%s\n\n</details>' \
        "$PR_HEAD_SHA" "$old_body")
      edit_err=$(jq -n --arg b "$new_body" '{body: $b}' \
        | gh api -X PATCH "repos/$owner_repo/issues/comments/$cid" --input - 2>&1 >/dev/null) || {
        echo "::warning::cleanup: failed to collapse prior agent comment $cid on $pr_url — stale comment will persist. API said: $(echo "$edit_err" | head -3 | tr '\n' ' ')"
      }
    done <<< "$stale_comment_ids"
  fi

  rm -f "$reviews_file" "$comments_file"
}

if [ "$DRY_RUN" = "true" ]; then
  echo "=== DRY RUN: Would post review ==="
  echo "Decision: $DECISION"
  echo "Risk: $RISK"
  echo "Body:"
  echo "$BODY"
  exit 0
fi

if [ "$DECISION" = "skip" ]; then
  REASON=$(jq -r '.reason // "unspecified"' "$VERDICT_JSON")
  echo "    reviewer returned skip ($REASON) — treating as no-op"
  exit 100
fi
if [ "$DECISION" != "approve" ] && [ "$DECISION" != "escalate" ]; then
  echo "ERROR: invalid decision '$DECISION'"
  exit 1
fi

# Post the review/comment based on decision
if [ "$DECISION" = "approve" ]; then
  # Post an APPROVED review
  BODY_FILE="/tmp/pr-review-body-$$.txt"
  echo "$BODY" > "$BODY_FILE"

  echo "Posting APPROVED review..."
  REVIEW_ERR_FILE="/tmp/pr-review-err-$$.txt"
  gh pr review "$PR_URL" --approve --body "$(cat "$BODY_FILE")" 2>"$REVIEW_ERR_FILE" || {
    rc=$?
    review_err=$(cat "$REVIEW_ERR_FILE" 2>/dev/null || true)
    cat "$REVIEW_ERR_FILE" >&2 2>/dev/null || true
    rm -f "$BODY_FILE" "$REVIEW_ERR_FILE"
    # Self-approval is a permanent, PR-specific constraint — never the runner's
    # fault and never recoverable on retry. Exit 100 (no-op sentinel) so the
    # workflow loop skips this PR without aborting the rest of the session.
    # See issue #96: a single self-authored PR at the top of the queue
    # previously starved every batch.
    if echo "$review_err" | grep -qiE 'Can not approve your own pull request'; then
      echo "::warning::Cannot self-approve $PR_URL — skipping (exit 100)"
      exit 100
    fi
    echo "ERROR: gh pr review failed with exit code $rc"
    exit 1
  }
  rm -f "$BODY_FILE" "$REVIEW_ERR_FILE"

  # Dismiss prior agent reviews / collapse prior agent comments now that the
  # newest review has landed. Best-effort: failures here don't break the run.
  mark_prior_agent_items_obsolete "$PR_URL"

  # Check merge state and rebase if needed.
  # This entire section is best-effort — the review is already posted, so a
  # rebase failure (403 permission, 504 timeout, etc.) must never abort the
  # batch session. Every command uses || to suppress set -e.
  MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo "UNKNOWN")
  if [ "$MERGE_STATE" = "BEHIND" ]; then
    OWNER_REPO=$(echo "$PR_URL" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
    PR_NUM=$(echo "$PR_URL" | sed -E 's|.*/([0-9]+)$|\1|')

    echo "Branch is BEHIND, requesting rebase..."
    REBASE_OK=false
    for attempt in 1 2 3; do
      rebase_output=$(gh api -X PUT "repos/$OWNER_REPO/pulls/$PR_NUM/update-branch" \
        -f expected_head_sha="$PR_HEAD_SHA" 2>&1) && { REBASE_OK=true; break; }
      rebase_rc=$?
      if echo "$rebase_output" | grep -qE '"status":\s*"4[0-9][0-9]"'; then
        echo "::warning::rebase request rejected (client error) — $rebase_output"
        break
      fi
      if [ "$attempt" -lt 3 ]; then
        delay=$(( 5 * attempt ))
        echo "  rebase attempt $attempt failed (exit $rebase_rc), retrying in ${delay}s..."
        sleep "$delay"
      else
        echo "::warning::rebase request failed after $attempt attempts — $rebase_output"
      fi
    done

    if [ "$REBASE_OK" = "true" ]; then
      # Poll for rebase completion (up to 30s)
      for _i in 1 2 3 4 5 6; do
        MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo "UNKNOWN")
        [ "$MERGE_STATE" != "BEHIND" ] && break
        sleep 5
      done
    fi

    if [ "$MERGE_STATE" = "BEHIND" ]; then
      echo "::warning::still BEHIND after rebase — skipping auto-merge for $PR_URL"
    fi
  fi

  # Enable auto-merge (skip if branch is still behind — GitHub would block it anyway)
  if [ "$MERGE_STATE" != "BEHIND" ]; then
    echo "Enabling auto-merge..."
    gh pr merge "$PR_URL" --auto --squash 2>/dev/null || true
  fi

  # Clean up label
  gh pr edit "$PR_URL" --remove-label needs-human-review 2>/dev/null || true

  echo "Review posted and auto-merge enabled"

elif [ "$DECISION" = "escalate" ]; then
  # Check if AI delegation should be used
  if [ "${AI_DELEGATION_ENABLED:-false}" = "true" ] && [ "${REVIEW_CYCLE:-0}" -lt "${MAX_REVIEW_CYCLES:-3}" ] && [ "$RISK" != "HIGH" ]; then
    # Post fix-request comment
    COMMENT_FILE="/tmp/pr-comment-$$.txt"
    NEXT_CYCLE=$((REVIEW_CYCLE + 1))
    cat > "$COMMENT_FILE" <<COMMENT_END
## Review — fix requested (cycle $NEXT_CYCLE/$MAX_REVIEW_CYCLES)

The automated review identified the following issues. Please address each one:

### Findings to fix
[Findings would be inserted here]

### Additional tasks
1. Resolve all unresolved review thread comments from other reviewers
2. Ensure all CI checks pass after your changes
3. Rebase on the target branch if behind
4. Do NOT modify files unrelated to the findings above

_The review cascade will automatically re-review after new commits are pushed._
COMMENT_END

    echo "Posting fix-request comment..."
    gh pr comment "$PR_URL" --body "$(cat "$COMMENT_FILE")" || true
    rm -f "$COMMENT_FILE"

    # Supersede prior agent reviews/comments now that the newest fix-request
    # has landed. A new fix-request also invalidates any prior approval.
    mark_prior_agent_items_obsolete "$PR_URL"
  else
    # Escalate to human via CODEOWNERS — avoid hard-coding a single reviewer.
    echo "Escalating to human review..."
    gh pr edit "$PR_URL" --add-label needs-human-review 2>/dev/null || true
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$SCRIPT_DIR/request-codeowners-review.sh" "$PR_URL" || true
  fi
fi

echo "Review action completed"
