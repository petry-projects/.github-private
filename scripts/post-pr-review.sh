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

# PR-metadata digest helper (issue #1551) — used to stamp `meta=<digest>` into a
# metadata-only fix-request marker so a later body/label/linked-issue edit can
# re-arm the review without a new commit.
POST_PR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pr-metadata-digest.sh
source "$POST_PR_SCRIPT_DIR/lib/pr-metadata-digest.sh"
# shellcheck source=lib/verify-approval-review.sh
source "$POST_PR_SCRIPT_DIR/lib/verify-approval-review.sh"

# The account this run acts as and the secret holding its PAT — named in the
# #1874 loud-failure diagnostic so a stranded approval points straight at the
# credential. BOT_USER is set by the workflow; POSTING_CREDENTIAL defaults to the
# pr-review posting secret and encodes the known classic-vs-fine-grained hazard.
BOT_USER="${BOT_USER:-donpetry-bot}"
POSTING_CREDENTIAL="${POSTING_CREDENTIAL:-DON_PETRY_BOT_GH_PAT_CLASSIC (classic PAT required for addPullRequestReview; the fine-grained DON_PETRY_BOT_GH_PAT fallback cannot create reviews)}"

# verify_approval_landed <pr_url>
#   Read back GET /pulls/<n>/reviews and decide whether the approval WRITE we just
#   issued actually produced a review object (issue #1874). Echoes one verdict:
#     PRESENT       — an APPROVED review by BOT_USER at PR_HEAD_SHA exists.
#     ABSENT        — the reviews list was read AND no such review exists: a
#                     DEFINITE negative (the write silently failed). Fail loud.
#     INDETERMINATE — the reviews API could not be read: fail OPEN (a transient
#                     blip must not turn a genuine approval into a red run — the
#                     same posture as the #1776 authorization preflight).
#   A short retry absorbs read-your-writes eventual consistency before concluding
#   ABSENT.
verify_approval_landed() {
  local pr_url="$1" owner_repo pr_num reviews rc
  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  pr_num=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')

  local attempt
  for attempt in 1 2 3; do
    rc=0
    # `gh api --paginate` streams one JSON array per page (`[...][...]`); `--slurp`
    # wraps the pages into a single array and `jq 'add'` concatenates them into one
    # flat reviews array, so an approval that landed on a later page is not missed
    # (#1875).
    reviews=$(
      gh api --paginate --slurp "repos/$owner_repo/pulls/$pr_num/reviews" 2>/dev/null |
        jq 'add'
    ) || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$reviews" ]; then
      if approval_review_present "$reviews" "$BOT_USER" "$PR_HEAD_SHA"; then
        echo "PRESENT"; return 0
      fi
      # Read succeeded but the review is not there yet — retry briefly for
      # eventual consistency, then conclude ABSENT.
      [ "$attempt" -lt 3 ] && sleep 2 && continue
      echo "ABSENT"; return 0
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  echo "INDETERMINATE"
}

# maybe_post_deferred_partial_evidence <pr_url>
#   Post the partial-evidence announcement (#1596) that the advisory gate DEFERRED
#   into PARTIAL_EVIDENCE_STATE_FILE — but only now, AFTER the approval has been
#   verified to exist (issue #1874 AC3). If the gate did not defer anything, this
#   is a no-op. The gate no longer posts this comment itself precisely so a
#   never-landed approval can never be announced.
maybe_post_deferred_partial_evidence() {
  local pr_url="$1"
  local statefile="${PARTIAL_EVIDENCE_STATE_FILE:-}"
  [ -n "$statefile" ] && [ -s "$statefile" ] || return 0

  local submitted required reason
  read -r submitted required reason < "$statefile" || return 0
  [ -n "$submitted" ] || return 0

  # Compose the marker + gate log helpers, then dedup against existing comments.
  # shellcheck source=lib/advisory-review-gate.sh
  source "$POST_PR_SCRIPT_DIR/lib/advisory-review-gate.sh" 2>/dev/null || true
  # shellcheck source=lib/partial-evidence-marker.sh
  source "$POST_PR_SCRIPT_DIR/lib/partial-evidence-marker.sh"
  local comments_json
  comments_json=$(gh pr view "$pr_url" --json comments 2>/dev/null || echo '{}')
  # Only discard the deferred facts once the marker has actually landed. If the
  # post fails, keep the state file so a later sweep can retry — deleting it here
  # would permanently lose the partial-evidence facts (#1875).
  if maybe_post_partial_evidence_marker "$pr_url" "$PR_HEAD_SHA" "$submitted" "$required" "$reason" "$comments_json"; then
    rm -f "$statefile"
  else
    echo "::warning::partial-evidence marker post failed on ${pr_url} — approval may be uncounted by the miss-rate metric (#1596); retaining $statefile for a later sweep"
  fi
}

# Extract fields from verdict
DECISION=$(jq -r '.decision' "$VERDICT_JSON")
RISK=$(jq -r '.risk' "$VERDICT_JSON")
BODY=$(jq -r '.body // ""' "$VERDICT_JSON")
# metadata_only (#1551): the reviewer sets this true when EVERY blocking finding
# is fixable by editing PR metadata alone (body / labels / linked issues) with no
# code change. Absent/false ⇒ current behavior (no digest stamp, commit-only
# re-arm), so an un-flagged or code-change fix-request cannot be re-armed by a
# body edit (AC3).
METADATA_ONLY=$(jq -r '.metadata_only // false' "$VERDICT_JSON")

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

# Mechanical enforcement of decision gate 4 (#1766). Gate 4 — "No unresolved
# review threads requesting changes" (prompts/shared.md) — was prompt-advisory
# only, and the cascade posted APPROVED on PR #1742 over 15 unresolved threads.
# Here an APPROVE verdict is IMPOSSIBLE while any review thread is unresolved, or
# while the thread set cannot be enumerated (API failure / pagination /
# permissions) — an unknown count must never read as zero. In either case the
# decision is rewritten to escalate BEFORE any approval is posted. This runs at
# the single point both the tier-2 and tier-3 cascade paths funnel through, and
# ahead of the DRY_RUN branch so the downgrade is visible in dry runs too.
if [ "$DECISION" = "approve" ]; then
  # shellcheck source=lib/unresolved-review-thread-gate.sh
  source "$POST_PR_SCRIPT_DIR/lib/unresolved-review-thread-gate.sh"
  URT_SNAPSHOT=$(urtg_fetch_review_threads "$PR_URL")
  URT_RC=0
  check_unresolved_review_threads "$URT_SNAPSHOT" || URT_RC=$?
  if [ "$URT_RC" -eq 1 ]; then
    URT_COUNT=$(printf '%s' "$URT_SNAPSHOT" | jq -r '[ (.reviewThreads // [])[] | select(.isResolved != true) ] | length' 2>/dev/null || echo "One or more")
    echo "    gate4: $URT_COUNT unresolved review thread(s) — downgrading approve → escalate (#1766)"
    DECISION="escalate"
    # Prepend the gate blocker to the original review body so the escalation
    # carries the full review summary and findings, not just the gate note.
    BODY=$(printf -- '- **blocker (decision gate 4)**: %s unresolved review thread(s) request changes and must be resolved before this PR can be approved. Resolve each open thread (or push a commit that addresses it and mark the thread resolved); the cascade will then re-review.\n\n---\n\n%s' "$URT_COUNT" "$BODY")
  elif [ "$URT_RC" -ne 0 ]; then
    echo "    gate4: review threads could not be enumerated (rc=$URT_RC) — failing closed, downgrading approve → escalate (#1766)"
    DECISION="escalate"
    # Prepend the gate blocker to the original review body so the escalation
    # carries the full review summary and findings, not just the gate note.
    BODY=$(printf -- '- **blocker (decision gate 4)**: the PR review-thread state could not be enumerated (API failure, pagination beyond one page, or permissions), so approval is withheld (fail-closed). An unknown thread count must not be treated as zero. The cascade will re-review once the thread set is readable.\n\n---\n\n%s' "$BODY")
  fi
fi

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
  review_err=""
  body_content=$(cat "$BODY_FILE")
  # Use an explicit else branch (no `!`) so `rc=$?` captures the REAL exit code of
  # `gh pr review`. With `if ! gh …; then rc=$?` the `!` inverts the status, so the
  # failure branch always saw rc=0 and the #1874 diagnostic misreported a success.
  if gh pr review "$PR_URL" --approve --body "$body_content" 2>"$REVIEW_ERR_FILE"; then
    rm -f "$BODY_FILE" "$REVIEW_ERR_FILE"
  else
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
    # The approval write FAILED (issue #1874). Fail loud and name every fact a
    # human needs — the PR, the account we acted as, the credential secret, and
    # the raw API error — then exit non-zero. Never treat a failed write as
    # success: doing so is exactly how a PR stranded behind an approval that
    # existed only in a comment (PRs #1788/#1858/#1860).
    echo "::error::pr-review approval WRITE FAILED on $PR_URL as '$BOT_USER' (credential $POSTING_CREDENTIAL): gh pr review --approve exited $rc and created NO review object. API said: $(echo "$review_err" | head -3 | tr '\n' ' '). The PR is stranded at REVIEW_REQUIRED — do NOT announce an approval that did not land (#1874)."
    exit 1
  fi

  # #1874: `gh pr review --approve` can exit 0 while NO review object is created
  # (a fine-grained PAT authenticates and returns success but cannot
  # addPullRequestReview). Trusting the exit code is what let the strand go
  # unreported. Verify the post-condition by reading the reviews back.
  APPROVAL_STATE=$(verify_approval_landed "$PR_URL")
  APPROVAL_VERIFIED=false
  case "$APPROVAL_STATE" in
    PRESENT)
      APPROVAL_VERIFIED=true # verified — the review object exists at head
      ;;
    ABSENT)
      echo "::error::pr-review approval WRITE reported success but NO review object exists on $PR_URL for '$BOT_USER' (credential $POSTING_CREDENTIAL). GET /pulls/.../reviews contains no APPROVED review by that account at $PR_HEAD_SHA — the write silently failed (a fine-grained PAT can comment but cannot addPullRequestReview). The PR is stranded at REVIEW_REQUIRED; failing the run rather than announcing a phantom approval (#1874)."
      exit 1
      ;;
    *)
      # INDETERMINATE — the reviews API could not be read. Fail OPEN: a transient
      # blip must not turn a genuine approval into a red run (#1776 posture).
      echo "::warning::could not read back reviews on $PR_URL to confirm the approval landed (transient API error) — proceeding without gating; a later sweep re-verifies (#1874)"
      ;;
  esac

  # Dismiss prior agent reviews / collapse prior agent comments now that the
  # newest review has landed. Best-effort: failures here don't break the run.
  mark_prior_agent_items_obsolete "$PR_URL"

  # Only a VERIFIED-present approval may trigger the deferred partial-evidence
  # announcement (#1874 AC3). On INDETERMINATE we could not confirm the review
  # object exists, so announcing would claim approval evidence that was never
  # verified — leave the deferred state intact for a later sweep to re-verify (#1875).
  if [ "$APPROVAL_VERIFIED" = "true" ]; then
    maybe_post_deferred_partial_evidence "$PR_URL"
  else
    echo "::warning::approval unverified on $PR_URL — NOT posting the deferred partial-evidence announcement; the state file is retained for a later sweep to re-verify (#1874 AC3 / #1875)"
  fi

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

  # Clean up label
  gh pr edit "$PR_URL" --remove-label needs-human-review 2>/dev/null || true

  echo "Review posted"

elif [ "$DECISION" = "escalate" ]; then
  # Check if AI delegation should be used
  if [ "${AI_DELEGATION_ENABLED:-false}" = "true" ] && [ "${REVIEW_CYCLE:-0}" -lt "${MAX_REVIEW_CYCLES:-3}" ] && [ "$RISK" != "HIGH" ]; then
    # Post fix-request comment
    COMMENT_FILE="/tmp/pr-comment-$$.txt"
    NEXT_CYCLE=$((REVIEW_CYCLE + 1))
    # Strip any embedded marker from BODY before inserting — the cascade-action body
    # already carries its own marker, and a second copy would cause review-one-pr.sh
    # to count this cycle as 2 (grep -c counts matching lines), prematurely hitting
    # the max-cycle escalation cap.
    BODY_FOR_COMMENT=$(printf '%s' "$BODY" | sed 's/<!-- pr-review-agent v1 sha=[a-f0-9][^>]*-->//g')
    # For a metadata-only fix-request, stamp a metadata digest into the marker so a
    # PR body/label/linked-issue edit (which mints no new commit) re-arms the review
    # (#1551). The re-arm condition stated in the footer must match the marker: a
    # metadata-only marker re-arms on a metadata change too; every other marker
    # re-arms only on a new commit (AC3/AC4).
    META_ATTR=""
    REARM_FOOTER="_The review cascade will automatically re-review after new commits are pushed._"
    if [ "$METADATA_ONLY" = "true" ]; then
      # Only stamp `meta=` when the metadata snapshot fetch actually succeeds. A
      # transient `gh pr view` failure that fell back to `{}` would record the
      # digest of EMPTY metadata; the next re-review would compare real metadata
      # against it, spuriously conclude "metadata changed", and launch an
      # unnecessary same-SHA cascade. On fetch failure, omit `meta=` and keep the
      # commit-only footer — the metadata-only deadlock persists (safe, prior
      # behavior) rather than manufacturing false re-arm churn.
      META_SNAPSHOT=$(gh pr view "$PR_URL" --json body,closingIssuesReferences,labels 2>/dev/null || true)
      if [ -n "$META_SNAPSHOT" ] && printf '%s' "$META_SNAPSHOT" | jq -e . >/dev/null 2>&1; then
        META_DIGEST=$(compute_pr_metadata_digest "$META_SNAPSHOT")
        META_ATTR=" meta=$META_DIGEST"
        REARM_FOOTER="_The review cascade will automatically re-review after new commits are pushed, or after a change to the PR body, labels, or linked issues._"
      else
        echo "::warning::metadata snapshot fetch failed for $PR_URL — stamping a commit-only marker (no meta=)"
      fi
    fi
    cat > "$COMMENT_FILE" <<COMMENT_END
<!-- pr-review-agent v1 sha=$PR_HEAD_SHA --> <!-- decision=fix-requested risk=$RISK$META_ATTR -->

## Review — fix requested (cycle $NEXT_CYCLE/$MAX_REVIEW_CYCLES)

The automated review identified the following issues. Please address each one:

### Findings to fix
$BODY_FOR_COMMENT

### Additional tasks
1. Resolve all unresolved review thread comments from other reviewers
2. Ensure all CI checks pass after your changes
3. Rebase on the target branch if behind
4. Do NOT modify files unrelated to the findings above

$REARM_FOOTER
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
    # Post the gate blocker message if present (e.g., gate 4 downgrade reason) so
    # the author knows why approval was withheld. Match the exact deterministic
    # prefix the gate prepends (line 275/281) rather than substring matching
    # natural-language text; "blocker" is common in review language.
    if [[ "$BODY" == *"- **blocker (decision gate"* ]]; then
      # Re-stamp as an escalation verdict instead of posting markerless: the
      # same-SHA idempotency no-op in review-one-pr.sh keys on a bot marker at
      # head (decision=(approved|escalated)), and a markerless comment lets the
      # next trigger re-run the cascade and post a duplicate blocker at the
      # same SHA. decision=escalated does not match standing-approval/
      # carry-forward/miss-rate scans, which all require decision=approved.
      BODY_WITHOUT_OLD_MARKER=$(printf '%s' "$BODY" | sed 's/<!-- pr-review-agent v1 sha=[a-f0-9][^>]*-->//g')
      BODY_FOR_COMMENT="<!-- pr-review-agent v1 sha=$PR_HEAD_SHA decision=escalated risk=$RISK -->
$BODY_WITHOUT_OLD_MARKER"
      gh pr comment "$PR_URL" --body "$BODY_FOR_COMMENT" 2>/dev/null || true
    fi
    gh pr edit "$PR_URL" --add-label needs-human-review 2>/dev/null || true
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$SCRIPT_DIR/request-codeowners-review.sh" "$PR_URL" || true
  fi
fi

echo "Review action completed"

