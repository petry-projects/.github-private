#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-reviews.sh — handles review-related intents
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"

INTENT_TYPE="${INTENT_TYPE:-fix-reviews}"
PR_NUMBER="${PR_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
HEAD_SHA="${HEAD_SHA:-}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"

REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="

if [ -z "$PR_NUMBER" ] && [ "$INTENT_TYPE" != "rebase" ]; then
  echo "::error::PR_NUMBER is required"
  exit 1
fi

# Resolve HEAD_SHA from the PR API when not provided by the triggering event.
# issue_comment intents (on-mention, fix-bot-comment) only carry pr_number, not head_sha.
# A resolved SHA ensures rate-limited markers are scannable by the retry cron.
if [ -z "${HEAD_SHA:-}" ] && [ -n "${PR_NUMBER:-}" ] && [ "${DEV_LEAD_DRY_RUN:-false}" = "false" ]; then
  HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || true)
fi

# Checkout the PR branch for modification (Requirement 1)
if [ "${DEV_LEAD_DRY_RUN:-false}" = "false" ] && [ -n "${PR_NUMBER:-}" ]; then
  gh pr checkout "$PR_NUMBER" --repo "$REPO"
fi

build_and_run() {
  local template_name="$1"
  local prompt_file="/tmp/dev-lead-${template_name}-prompt-$$.md"
  local template_path="${PROMPTS_DIR}/${template_name}.md"
  # Scope envsubst to only the variables declared in the <!-- VARIABLES: --> header.
  # This prevents GraphQL $variables, $() subshells, and other $ patterns in the
  # prompt from being silently clobbered before the agent ever sees them.
  local vars_spec
  vars_spec=$(grep -m1 '<!-- VARIABLES:' "$template_path" 2>/dev/null \
    | sed 's/<!-- VARIABLES: //; s/ -->//' \
    | tr ',' '\n' \
    | awk '{gsub(/^ +| +$/, ""); if (length) printf "${%s}", $0}' || true)
  if [ -n "$vars_spec" ]; then
    envsubst "$vars_spec" < "$template_path" > "$prompt_file"
  else
    envsubst < "$template_path" > "$prompt_file"
  fi

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would run engine with prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"
    rm -f "$prompt_file"
    return 0
  fi

  local rc=0
  run_writer_with_fallback "$prompt_file" || rc=$?
  rm -f "$prompt_file"
  return "$rc"
}

# post_reviews_terminal: writes a terminal status marker after a retryable
# intent completes. This prevents the retry cron from re-dispatching the same
# intent on subsequent runs when the SHA hasn't changed.
post_reviews_terminal() {
  local intent="$1" status="${2:-applied}" summary="${3:-}"
  local sha_part=""
  [ -n "${HEAD_SHA:-}" ] && sha_part=" sha=${HEAD_SHA}"
  local marker="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}${sha_part} intent=${intent} status=${status} -->"

  local body="${marker}"
  if [ -n "$summary" ]; then
    body="${body}
## Dev-Lead — ${intent} (${status})
${summary}"
  fi

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post reviews terminal marker: intent=${intent} status=${status}"
    [ -n "$summary" ] && echo "$body"
    return 0
  fi
  # Best-effort: don't fail the overall script if the marker post fails
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body" 2>/dev/null || true
}

# redact_secrets: scrub common credential token formats from stdin → stdout.
# Defense-in-depth before publishing agent session output to a PR comment —
# Claude Code's session log can include curl/gh invocations whose stderr leaks
# tokens, or echoed environment variables. Patterns cover GitHub, OpenAI/
# Anthropic, AWS, Google OAuth, generic bearer tokens, and PEM private keys.
redact_secrets() {
  # The PEM range (-----BEGIN ... -----END ...) uses sed's c\ range-change
  # so the *entire* multiline block is replaced — header line alone leaves
  # the key body lines intact and still leakable.
  sed -E \
    -e 's/(gh[opsu]|ghr)_[A-Za-z0-9_]{20,}/***REDACTED-GH-TOKEN***/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/***REDACTED-GH-PAT***/g' \
    -e 's/sk-(ant-)?[A-Za-z0-9_-]{20,}/***REDACTED-API-KEY***/g' \
    -e 's/AKIA[A-Z0-9]{16}/***REDACTED-AWS-KEY***/g' \
    -e 's/AIza[A-Za-z0-9_-]{35}/***REDACTED-GOOGLE-KEY***/g' \
    -e 's|ya29\.[A-Za-z0-9_-]+|***REDACTED-GOOGLE-OAUTH***|g' \
    -e 's/[Bb]earer [A-Za-z0-9._-]{20,}/Bearer ***REDACTED***/g' \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\
***REDACTED-PRIVATE-KEY***'
}

# read_session_summary: reads the last 10 non-blank lines of the agent session
# output and redacts any embedded credentials. Empty output if the file is
# missing (e.g. dry-run paths that never invoked the writer). Redaction runs
# over the full log *before* tailing, so PEM blocks that straddle the tail
# boundary are fully redacted (header in the discarded window, body in the
# kept window would otherwise leak as plaintext key material).
read_session_summary() {
  local log="/tmp/dev-lead-session-output.txt"
  [[ -f "$log" ]] || return 0
  redact_secrets < "$log" | tail -30 | sed '/^[[:space:]]*$/d' | tail -10
}

# pick_fence: emit a tilde fence longer than any tilde run in $1 (min 4).
# Ensures the wrapping ~~~~ code block cannot be terminated early by content
# that happens to contain a tilde sequence.
pick_fence() {
  local content="$1"
  local fence="~~~~"
  while printf '%s' "$content" | grep -qF "$fence"; do
    fence="${fence}~"
  done
  printf '%s' "$fence"
}

# post_no_changes: posts a terminal no-changes marker with redacted agent
# reasoning when available, or a plain fallback when the session log is
# absent. Picks a tilde fence that cannot be broken by the content, and
# neutralises any literal </details> so the wrapping <details> stays intact.
post_no_changes() {
  local intent="$1"
  local _summary
  _summary=$(read_session_summary || true)
  local msg="No actionable items found."
  if [[ -n "$_summary" ]]; then
    # Neutralise any </details> in summary so it cannot close the outer block.
    _summary=$(printf '%s' "$_summary" | sed 's|</details>|<\\/details>|g')
    local fence
    fence=$(pick_fence "$_summary")
    msg="<details><summary>Agent reasoning</summary>

${fence}
${_summary}
${fence}
</details>"
  fi
  post_reviews_terminal "$intent" "no-changes" "$msg"
}

# notify_coderabbit_resolve: posts @coderabbitai resolve if coderabbitai[bot]'s
# most recent review on the PR is CHANGES_REQUESTED. Uses --paginate so it sees
# all reviews even on long-lived PRs, and checks only the latest review state
# (not any historical one) to avoid noisy re-posts after a prior approval or dismissal.
notify_coderabbit_resolve() {
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would check for coderabbitai CHANGES_REQUESTED and post @coderabbitai resolve"
    return 0
  fi
  # Emit one state per CodeRabbit review in chronological order; tail -1 = latest.
  local latest_cr_state
  latest_cr_state=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
    --jq '.[] | select(.user.login == "coderabbitai[bot]") | .state' \
    2>/dev/null | tail -1)
  if [ "${latest_cr_state:-}" = "CHANGES_REQUESTED" ]; then
    echo "::notice::coderabbitai[bot] latest review is CHANGES_REQUESTED — posting @coderabbitai resolve"
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@coderabbitai resolve" 2>/dev/null || true
  fi
}

# try_enable_auto_merge: enables auto-merge (squash) on the PR if reviewDecision is
# APPROVED and auto-merge is not already set. Safe to call speculatively — checks
# eligibility first and is idempotent if auto-merge is already on.
# Pass "true" as first arg for strict mode: API errors propagate and a merge failure
# exits non-zero rather than emitting a warning (use for the enable-auto-merge intent).
try_enable_auto_merge() {
  local strict="${1:-false}"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would enable auto-merge if PR #${PR_NUMBER} is APPROVED"
    return 0
  fi
  # Refresh HEAD_SHA to the commit that is now the PR head. commit_and_push may
  # have created a new commit after HEAD_SHA was resolved at script startup, so
  # --match-head-commit would fail with the stale value.
  local current_head
  current_head=$(git rev-parse HEAD 2>/dev/null || true)
  [ -n "$current_head" ] && HEAD_SHA="$current_head"

  local auto_merge_state review_decision

  if [ "$strict" = "true" ]; then
    auto_merge_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge // empty')
    if [ -n "$auto_merge_state" ]; then
      echo "::notice::PR #${PR_NUMBER} auto-merge already enabled"
      return 0
    fi
    review_decision=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!){
        repository(owner:$owner,name:$repo){
          pullRequest(number:$pr){reviewDecision}
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewDecision')
  else
    auto_merge_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" \
      --jq '.auto_merge // empty' 2>/dev/null || true)
    if [ -n "$auto_merge_state" ]; then
      echo "::notice::PR #${PR_NUMBER} auto-merge already enabled"
      return 0
    fi
    review_decision=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!){
        repository(owner:$owner,name:$repo){
          pullRequest(number:$pr){reviewDecision}
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewDecision' 2>/dev/null || true)
  fi

  if [ "${review_decision:-}" = "APPROVED" ]; then
    echo "::notice::PR #${PR_NUMBER} is APPROVED — enabling auto-merge (squash)"
    set -- --auto --squash
    [ -n "${HEAD_SHA:-}" ] && set -- "$@" --match-head-commit "$HEAD_SHA"
    if [ "$strict" = "true" ]; then
      gh pr merge "$PR_NUMBER" --repo "$REPO" "$@"
    else
      gh pr merge "$PR_NUMBER" --repo "$REPO" "$@" 2>/dev/null || \
        echo "::warning::auto-merge could not be enabled on PR #${PR_NUMBER} — check repository settings and token permissions"
    fi
  else
    echo "::notice::PR #${PR_NUMBER} reviewDecision=${review_decision:-unknown} — not yet eligible for auto-merge"
  fi
}

# commit_and_push: stages any uncommitted changes (including untracked files),
# commits if needed, and pushes. Returns 0 if changes were pushed, 1 if nothing to push.
# Handles two cases:
#   (a) Engine left uncommitted/untracked working-tree changes — stage, commit, push.
#   (b) Engine committed via Bash but didn't push — detected via upstream comparison
#       so changes are not silently dropped when the ephemeral runner exits.
commit_and_push() {
  local intent="$1"
  local has_uncommitted=false has_unpushed=false

  # git status --porcelain covers untracked files that git diff misses
  [ -n "$(git status --porcelain)" ] && has_uncommitted=true

  # Detect engine-committed but not pushed: prefer @{u} if upstream is configured,
  # fall back to HEAD_SHA (resolved from PR API at script startup) for fork checkouts.
  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    git log "${upstream}..HEAD" --oneline 2>/dev/null | grep -q . && has_unpushed=true
  elif [ -n "${HEAD_SHA:-}" ]; then
    git log "${HEAD_SHA}..HEAD" --oneline 2>/dev/null | grep -q . && has_unpushed=true
  fi

  if ! $has_uncommitted && ! $has_unpushed; then
    echo "::notice::No changes to commit for intent=${intent}"
    return 1
  fi

  local commit_msg
  case "$intent" in
    fix-reviews)     commit_msg="fix(reviews): address review comments [skip ci-relay]" ;;
    fix-bot-comment) commit_msg="fix(bot): address bot feedback [skip ci-relay]" ;;
    on-mention|review-changes)  commit_msg="chore: apply manual instructions [skip ci-relay]" ;;
    rebase)          commit_msg="chore: resolve rebase conflicts [skip ci-relay]" ;;
    *)               commit_msg="chore: dev-lead update (${intent}) [skip ci-relay]" ;;
  esac

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    if $has_uncommitted; then
      echo "[dry-run] would git add -A, commit '${commit_msg}', and push"
    else
      echo "[dry-run] engine already committed — would push existing commit(s) without re-committing"
    fi
  else
    if $has_uncommitted; then
      git add -A
      # Explicit exit on failure: set -e is suspended when commit_and_push is called from
      # an if-statement condition, so git commit failures would be silently swallowed
      # otherwise. Using exit (not return) ensures CI fails visibly instead of posting a
      # false "Changes committed and pushed" comment.
      git commit -m "$commit_msg" || { echo "::error::git commit failed — check git identity configuration on the runner" >&2; exit 1; }
    fi
    git push || {
      echo "::error::git push failed — check remote access and branch permissions" >&2
      exit 1
    }
  fi
  return 0
}

# has_reviews_rate_limited_marker: returns 0 if a rate-limited marker for this
# intent+SHA already exists on the PR (dedup check).
has_reviews_rate_limited_marker() {
  local intent="$1"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 1  # no SHA means no dedup possible
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=rate-limited"
  local count
  count=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq "[.[] | select(.body | test(\"${pattern}\"))] | length" 2>/dev/null \
    || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# post_reviews_rate_limited: posts a rate-limited marker for fix-reviews intents.
# For retryable intents (fix-reviews, review-changes, rebase), the cron will re-dispatch.
# For non-retryable intents (on-mention, fix-bot-comment), asks the user to re-trigger
# since USER_INSTRUCTION/COMMENT_BODY cannot be reconstructed at retry time.
post_reviews_rate_limited() {
  local intent="$1"

  # Dedup: don't accumulate multiple rate-limited markers for the same SHA+intent
  if has_reviews_rate_limited_marker "$intent"; then
    echo "::notice::rate-limited marker already posted for intent=${intent} SHA=${HEAD_SHA:-none} — skipping duplicate"
    return 0
  fi

  local reset_time
  reset_time=$(cat /tmp/dev-lead-rate-limit-reset 2>/dev/null || true)
  local reset_detail=""
  if [ -n "$reset_time" ]; then
    reset_detail=" reset=${reset_time}"
  fi

  local sha_detail=""
  if [ -n "${HEAD_SHA:-}" ]; then
    sha_detail=" sha=${HEAD_SHA}"
  fi

  local marker="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}${sha_detail} intent=${intent} status=rate-limited${reset_detail} -->"

  # Retry message depends on whether the intent can be re-dispatched automatically
  local retry_msg
  case "$intent" in
    fix-reviews|review-changes|rebase)
      retry_msg="The retry cron will re-attempt automatically."
      ;;
    on-mention|fix-bot-comment)
      retry_msg="Please re-trigger manually (re-mention \`@dev-lead\`) when the rate limit clears — the original request cannot be reconstructed automatically."
      ;;
    *)
      retry_msg="Manual re-trigger may be required."
      ;;
  esac
  if [ -n "$reset_time" ]; then
    retry_msg="${retry_msg} Rate limit resets at: \`${reset_time}\`"
  fi

  local marker_body="${marker}
## Dev-Lead — rate-limited (intent: ${intent})
**PR:** #${PR_NUMBER}
${retry_msg}"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post rate-limited marker for intent=${intent}"
    echo "$marker_body"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$marker_body"
  fi

  # For user-triggered intents, post a separate visible acknowledgment.
  # review-changes is retried automatically; human/fix-bot-comment require manual re-trigger.
  case "$intent" in
    review-changes)
      local actor_mention=""
      [ -n "${ACTOR:-}" ] && actor_mention="@${ACTOR} "
      local reset_display="${reset_time:-unknown}"
      local ack_body="> [!NOTE]
> ${actor_mention}I received your request but all AI engines are currently rate-limited. I'll retry automatically once the rate limit clears.
> Rate limit resets at: \`${reset_display}\`"
      if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
        echo "[dry-run] would post user-visible rate-limit acknowledgment"
        echo "$ack_body"
      else
        gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$ack_body"
      fi
      ;;
    on-mention)
      local actor_mention=""
      [ -n "${ACTOR:-}" ] && actor_mention="@${ACTOR} "
      local reset_display="${reset_time:-unknown}"
      local ack_body="> [!NOTE]
> ${actor_mention}I received your request but all AI engines are currently rate-limited. Please re-mention \`@dev-lead\` when the rate limit clears (estimated: \`${reset_display}\`) — I cannot reconstruct the original instruction automatically."
      if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
        echo "[dry-run] would post user-visible rate-limit acknowledgment"
        echo "$ack_body"
      else
        gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$ack_body"
      fi
      ;;
  esac
}

handle_rate_limit() {
  local intent="$1"
  echo "::warning::All engines rate-limited for intent=${intent} — posting rate-limited marker"
  post_reviews_rate_limited "$intent"
  exit 2
}

case "$INTENT_TYPE" in
  fix-reviews)
    # Get open review threads
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO HEAD_SHA
    export BASE_REF="${BASE_REF:-main}"
    # Normalise to GraphQL's author.login form: the GitHub Actions event login
    # includes a "[bot]" suffix for bots, but GraphQL author.login omits it.
    # Without this, the prompt's `author.login == ${TRIGGERING_REVIEWER}` check
    # never matches threads from coderabbitai/chatgpt-codex/etc.
    export TRIGGERING_REVIEWER="${TRIGGERING_REVIEWER:-}"
    TRIGGERING_REVIEWER="${TRIGGERING_REVIEWER%\[bot\]}"
    OPEN_THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:50) {
              nodes { id isResolved isOutdated line path comments(first:5) { nodes { body author { login } } } }
            }
          }
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved == false))' 2>/dev/null || echo "[]")
    export OPEN_THREADS_JSON
    rc=0
    build_and_run "fix-reviews" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-reviews"
    if [ "$rc" -eq 0 ]; then
      if commit_and_push "fix-reviews"; then
        notify_coderabbit_resolve
        post_reviews_terminal "fix-reviews" "applied" "Changes committed and pushed."
      else
        notify_coderabbit_resolve
        post_no_changes "fix-reviews"
      fi
      try_enable_auto_merge
    fi
    exit "$rc"
    ;;
  fix-bot-comment)
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO ACTOR="${ACTOR:-}" COMMENT_BODY="${COMMENT_BODY:-}" HEAD_SHA
    rc=0
    build_and_run "fix-bot-comment" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-bot-comment"
    if [ "$rc" -eq 0 ]; then
      if commit_and_push "fix-bot-comment"; then
        notify_coderabbit_resolve
        post_reviews_terminal "fix-bot-comment" "applied" "Changes committed and pushed."
      else
        notify_coderabbit_resolve
        post_no_changes "fix-bot-comment"
      fi
      try_enable_auto_merge
    fi
    exit "$rc"
    ;;
  on-mention)
    export PR_NUMBER="${PR_NUMBER:-}"
    export PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO ACTOR="${ACTOR:-}" USER_INSTRUCTION="${USER_INSTRUCTION:-}" PR_DESCRIPTION="${PR_DESCRIPTION:-}"
    rc=0
    build_and_run "on-mention" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "on-mention"
    if [ "$rc" -eq 0 ]; then
      if commit_and_push "on-mention"; then
        post_reviews_terminal "on-mention" "applied" "Changes committed and pushed."
      else
        post_reviews_terminal "on-mention" "no-changes" "Engine ran but made no changes."
      fi
    fi
    exit "$rc"
    ;;
  review-changes)
    export PR_NUMBER="${PR_NUMBER:-}"
    export PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO PR_TITLE="${PR_TITLE:-}" PR_DESCRIPTION="${PR_DESCRIPTION:-}"
    OPEN_THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:50) {
              nodes { id isResolved isOutdated line path comments(first:5) { nodes { body author { login } } } }
            }
          }
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved == false))' 2>/dev/null || echo "[]")
    export OPEN_THREADS_JSON BASE_REF="${BASE_REF:-main}"
    rc=0
    build_and_run "review-changes" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "review-changes"
    if [ "$rc" -eq 0 ]; then
      if commit_and_push "review-changes"; then
        notify_coderabbit_resolve
        post_reviews_terminal "review-changes" "applied" "Changes committed and pushed."
      else
        notify_coderabbit_resolve
        post_reviews_terminal "review-changes" "no-changes" "No changes were needed for this PR."
      fi
      try_enable_auto_merge
    fi
    exit "$rc"
    ;;
  rebase)
    export PR_NUMBER="${PR_NUMBER:-}"
    export PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO BASE_REF="${BASE_REF:-main}" HEAD_REF="${HEAD_REF:-}" CONFLICTING_FILES="${CONFLICTING_FILES:-}"
    if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
      echo "[dry-run] would run rebase for PR $PR_NUMBER"
      exit 0
    fi
    if [ -z "$PR_NUMBER" ]; then
      echo "::error::PR_NUMBER is required for rebase"
      exit 1
    fi
    git fetch origin "$BASE_REF"
    CONFLICTING_FILES=$(git merge-tree "$(git merge-base HEAD "origin/${BASE_REF}")" HEAD "origin/${BASE_REF}" 2>/dev/null | grep "^changed in both" | awk '{print $NF}' || true)
    export CONFLICTING_FILES
    rc=0
    build_and_run "rebase" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "rebase"
    if [ "$rc" -eq 0 ]; then
      if commit_and_push "rebase"; then
        post_reviews_terminal "rebase" "applied" "Rebase completed and pushed."
      else
        post_no_changes "rebase"
      fi
    fi
    exit "$rc"
    ;;
  enable-auto-merge)
    if [ -z "$PR_NUMBER" ]; then
      echo "::error::PR_NUMBER is required for enable-auto-merge"
      exit 1
    fi
    try_enable_auto_merge "true"
    ;;
  *)
    echo "::error::Unknown intent type: $INTENT_TYPE"
    exit 1
    ;;
esac
