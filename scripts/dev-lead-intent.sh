#!/usr/bin/env bash
set -euo pipefail
# dev-lead-intent.sh — Event classifier for the dev-lead agent.
#
# Reads GITHUB_EVENT_NAME and GITHUB_EVENT_PATH, classifies the event into
# an intent, and writes INTENT_TYPE / INTENT_REASON / INTENT_CONTEXT to
# GITHUB_ENV and GITHUB_OUTPUT.
#
# Intents:
#   fix-ci          — CI failure to auto-fix
#   fix-reviews     — Bot review comments to address
#   fix-bot-comment — Bot issue comment to address
#   on-mention       — Human-directed @mention task
#   review-changes   — Human review changes-requested
#   issue           — Issue labeled dev-lead
#   rebase          — Rebase conflict sentinel
#   enable-auto-merge — Bot approval: enable auto-merge if PR is APPROVED
#   ci-relay        — check_run relay (handled by ci-relay job, not this script)
#   skip            — Event should be ignored

# ── helpers ──────────────────────────────────────────────────────────────────

GITHUB_ENV="${GITHUB_ENV:-/dev/null}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

emit_intent() {
  local intent="$1" reason="${2:-}" context="${3:-}"
  echo "INTENT_TYPE=${intent}" >> "$GITHUB_ENV"
  echo "INTENT_REASON=${reason}" >> "$GITHUB_ENV"
  echo "intent_type=${intent}" >> "$GITHUB_OUTPUT"
  echo "intent_reason=${reason}" >> "$GITHUB_OUTPUT"

  # Use a random delimiter for context to handle multiline JSON safely
  local EOF_DELIMITER
  EOF_DELIMITER="EOF_$(dd if=/dev/urandom bs=15 count=1 2>/dev/null | base64 | tr -dc 'a-zA-Z0-9')"

  {
    echo "INTENT_CONTEXT<<$EOF_DELIMITER"
    echo "${context}"
    echo "$EOF_DELIMITER"
  } >> "$GITHUB_ENV"

  {
    echo "intent_context<<$EOF_DELIMITER"
    echo "${context}"
    echo "$EOF_DELIMITER"
  } >> "$GITHUB_OUTPUT"

  echo "  [intent] type=${intent} reason=${reason} context=${context}"
}

emit_skip() {
  local reason="${1:-not-implemented}"
  emit_intent "skip" "$reason" ""
}

# is_trusted_bot <actor>
# Returns 0 (true) if actor is in the TRUSTED_BOTS comma-delimited list.
is_trusted_bot() {
  local actor="$1"
  local bots
  bots=$(echo "${TRUSTED_BOTS:-}" | tr ',' '\n')
  echo "$bots" | grep -qxF "$actor"
}

# is_human_trusted <author_association>
# Returns 0 (true) for OWNER, MEMBER, or COLLABORATOR associations.
is_human_trusted() {
  local assoc="$1"
  case "$assoc" in
    OWNER|MEMBER|COLLABORATOR) return 0 ;;
    *) return 1 ;;
  esac
}

# has_trigger_phrase <body>
# Returns 0 (true) if body contains any phrase from TRIGGER_PHRASES.
has_trigger_phrase() {
  local body="$1"
  local phrases
  phrases=$(echo "${TRIGGER_PHRASES:-@dev-lead}" | tr ',' '\n')
  while IFS= read -r phrase; do
    [ -z "$phrase" ] && continue
    if echo "$body" | grep -qF "$phrase"; then
      return 0
    fi
  done <<< "$phrases"
  return 1
}

# has_label <name>
# Returns 0 (true) if the PR or issue in the event payload carries label <name>.
# Reads labels straight from the payload (.pull_request.labels / .issue.labels),
# so it stays a pure classifier with no API calls. repository_dispatch payloads
# carry no labels; those are handled via a separate API call in the dispatch
# branch of the routing section.
has_label() {
  local name="$1"
  [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ] || return 1
  jq -e --arg n "$name" '
    any(.pull_request.labels[]?, .issue.labels[]?; .name == $n)
  ' "$EVENT_PATH" >/dev/null 2>&1
}

# is_fork_pr <event_path>
# Returns 0 (true) if the PR head repo differs from GITHUB_REPOSITORY.
is_fork_pr() {
  local event_path="$1"
  local head_repo base_repo
  head_repo=$(jq -r '.pull_request.head.repo.full_name // .head.repo.full_name // empty' "$event_path" 2>/dev/null || true)
  base_repo="${GITHUB_REPOSITORY:-}"
  [ -n "$head_repo" ] && [ "$head_repo" != "$base_repo" ]
}

# is_dev_lead_authored
# Returns 0 (true) iff the PR in the event payload was authored by the dev-lead
# identity: its head branch matches `dev-lead/issue-*` OR the PR/issue author
# login equals BOT_USER. dev-lead's fix/push/merge intents must only ever act on
# PRs it authored — a review or bot comment on a human's in-flight PR must be
# left to the human (issue #1311: dev-lead drove a human PR to merge and dropped
# an unseen commit). FAILS CLOSED: any indeterminate state (no payload, or no
# head ref AND no author) returns 1, so callers skip rather than seize a PR whose
# ownership cannot be established.
is_dev_lead_authored() {
  [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ] || return 1
  local head_ref author
  head_ref=$(jq -r '(.pull_request?.head?.ref // "" | tostring)' "$EVENT_PATH" 2>/dev/null || true)
  author=$(jq -r '(.pull_request?.user?.login // .issue?.user?.login // "" | tostring)' "$EVENT_PATH" 2>/dev/null || true)
  case "$head_ref" in
    dev-lead/issue-*) return 0 ;;
  esac
  [ -n "$author" ] && [ "$author" = "$BOT_USER" ] && return 0
  return 1
}

# ── read event ───────────────────────────────────────────────────────────────

EVENT_NAME="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
BOT_USER="${BOT_USER:-donpetry-bot}"
TRUSTED_BOTS="${TRUSTED_BOTS:-copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot],chatgpt-codex-connector[bot]}"
TRIGGER_PHRASES="${TRIGGER_PHRASES:-@dev-lead}"

if [ -z "$EVENT_NAME" ]; then
  echo "::error::GITHUB_EVENT_NAME is not set"
  exit 1
fi

echo "dev-lead-intent: processing event=$EVENT_NAME"

# ── check_run: not handled here (ci-relay job) ───────────────────────────────

if [ "$EVENT_NAME" = "check_run" ]; then
  emit_skip "check-run-handled-by-ci-relay"
  exit 0
fi

# ── hands-off guard ───────────────────────────────────────────────────────────
# A PR or issue labeled `dev-lead:hands-off` is intentionally excluded from the
# agent — e.g. PRs that modify the dev-lead workflow itself, so the agent does
# not pile commits onto its own infrastructure changes. Runs before the anti-loop
# guard so a hands-off sync from BOT_USER emits `hands-off-label` rather than
# `dev-lead-own-commit`, keeping the skip reason stable whenever the label is
# present. Applies to every label-bearing event (PR opens/syncs, reviews, review
# comments, issue comments on PRs, issue labeling). repository_dispatch payloads
# carry no labels; those are checked via the API in the dispatch branch below.
if has_label "dev-lead:hands-off"; then
  emit_skip "hands-off-label"
  exit 0
fi

# ── anti-loop guard: pull_request synchronize ────────────────────────────────
# If the synchronize event was triggered by BOT_USER's own commit, skip to
# prevent an infinite fix → push → trigger → fix loop.

if [ "$EVENT_NAME" = "pull_request" ] && [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ]; then
  pr_action=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
  if [ "$pr_action" = "synchronize" ]; then
    sender_login=$(jq -r '.sender.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [ "$sender_login" = "$BOT_USER" ]; then
      emit_skip "dev-lead-own-commit"
      exit 0
    fi
  fi
fi

# ── routing ───────────────────────────────────────────────────────────────────

case "$EVENT_NAME" in

  # ── pull_request ─────────────────────────────────────────────────────────
  pull_request)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    pr_action=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
    sender_login=$(jq -r '.sender.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.pull_request.number // .number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)

    case "$pr_action" in
      opened|reopened)
        # Skip forks and bot PRs
        if is_fork_pr "$EVENT_PATH"; then
          emit_skip "fork-pr"
          exit 0
        fi
        if [[ "$sender_login" == *"[bot]"* ]] || [[ "$sender_login" == "dependabot"* ]]; then
          emit_skip "bot-pr"
          exit 0
        fi
        # Authorship gate (#1311): only act on PRs dev-lead authored. A human's
        # own PR is theirs to finish — dev-lead must not seize and drive it.
        if ! is_dev_lead_authored; then
          emit_skip "not-dev-lead-authored"
          exit 0
        fi
        context=$(jq -nc \
          --argjson pr_number "${pr_number:-0}" \
          --arg head_sha "${head_sha:-}" \
          --arg actor "${sender_login:-}" \
          '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor}')
        emit_intent "review-changes" "pr-${pr_action}" "$context"
        ;;
      synchronize)
        # Anti-loop already handled above; now route human syncs
        if [[ "$sender_login" == *"[bot]"* ]]; then
          emit_skip "bot-sync"
          exit 0
        fi
        # Authorship gate (#1311): a human pushing to their own PR keeps it.
        if ! is_dev_lead_authored; then
          emit_skip "not-dev-lead-authored"
          exit 0
        fi
        context=$(jq -nc \
          --argjson pr_number "${pr_number:-0}" \
          --arg head_sha "${head_sha:-}" \
          --arg actor "${sender_login:-}" \
          '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor}')
        emit_intent "review-changes" "pr-synchronize" "$context"
        ;;
      *)
        emit_skip "pr-action-not-routed"
        ;;
    esac
    ;;

  # ── pull_request_review ───────────────────────────────────────────────────
  pull_request_review)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    reviewer=$(jq -r '.review.user.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    review_body=$(jq -r '.review.body // empty' "$EVENT_PATH" 2>/dev/null || true)
    review_state=$(jq -r '.review.state // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.pull_request.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)
    author_assoc=$(jq -r '.pull_request.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)

    # Skip if actor is BOT_USER (self-review)
    if [ "$reviewer" = "$BOT_USER" ]; then
      pr_number=$(jq -r '.pull_request.number // empty' "$EVENT_PATH" 2>/dev/null || true)
      context=$(jq -nc --argjson pr_number "${pr_number:-0}" '{"pr_number":$pr_number}')
      emit_intent "skip" "self-review" "$context"
      exit 0
    fi

    # Skip fork PRs
    if is_fork_pr "$EVENT_PATH"; then
      emit_skip "fork-pr"
      exit 0
    fi

    # Authorship gate (#1311): a review — from a trusted bot OR a trusted human —
    # only drives dev-lead's fix/push/merge path on a PR dev-lead authored. On a
    # human's in-flight PR, dev-lead stays out (it may still advise, but never
    # pushes or merges). Fails closed on indeterminate authorship.
    if ! is_dev_lead_authored; then
      emit_skip "not-dev-lead-authored"
      exit 0
    fi

    context=$(jq -nc \
      --argjson pr_number "${pr_number:-0}" \
      --arg head_sha "${head_sha:-}" \
      --arg actor "${reviewer:-}" \
      --arg body "${review_body:-}" \
      '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor,"body":$body}')

    if is_trusted_bot "$reviewer"; then
      if [ "$review_state" = "APPROVED" ]; then
        emit_intent "enable-auto-merge" "bot-approved" "$context"
      else
        emit_intent "fix-reviews" "bot-review-${review_state}" "$context"
      fi
    elif is_human_trusted "$author_assoc"; then
      emit_intent "review-changes" "human-review-${review_state}" "$context"
    else
      emit_skip "untrusted-reviewer"
    fi
    ;;

  # ── pull_request_review_comment ───────────────────────────────────────────
  pull_request_review_comment)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    commenter=$(jq -r '.comment.user.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    comment_body=$(jq -r '.comment.body // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.pull_request.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)
    author_assoc=$(jq -r '.comment.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)

    context=$(jq -nc \
      --argjson pr_number "${pr_number:-0}" \
      --arg head_sha "${head_sha:-}" \
      --arg actor "${commenter:-}" \
      --arg body "${comment_body:-}" \
      '{"pr_number":$pr_number,"head_sha":$head_sha,"actor":$actor,"body":$body}')

    if is_trusted_bot "$commenter"; then
      # Authorship gate (#1311): a bot review comment only drives dev-lead's
      # auto-fix/push on a PR dev-lead authored. On a human's PR it is advisory.
      if ! is_dev_lead_authored; then
        emit_skip "not-dev-lead-authored"
        exit 0
      fi
      emit_intent "fix-reviews" "bot-review-comment" "$context"
    elif is_human_trusted "$author_assoc" && has_trigger_phrase "$comment_body"; then
      # on-mention is an explicit human request (@dev-lead) — direct
      # authorization — so it is exempt from the authorship gate.
      emit_intent "on-mention" "human-review-comment-trigger" "$context"
    else
      emit_skip "no-trigger-or-untrusted"
    fi
    ;;

  # ── issue_comment ─────────────────────────────────────────────────────────
  issue_comment)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    # Only handle comments on PRs (issues with pull_request field)
    is_pr=$(jq -r '.issue.pull_request // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [ -z "$is_pr" ]; then
      emit_skip "not-a-pr-comment"
      exit 0
    fi

    # Skip comments on closed/merged PRs — nothing to modify on a merged branch.
    # This is a fast-path guard; checkout_pr_in_worktree provides a deeper safety
    # net, but failing early here avoids spending tokens on a no-op run (issue #405).
    pr_state=$(jq -r '.issue.state // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [[ "${pr_state:-}" == "closed" ]]; then
      emit_skip "pr-already-closed"
      exit 0
    fi

    commenter=$(jq -r '.comment.user.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    comment_body=$(jq -r '.comment.body // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.issue.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    author_assoc=$(jq -r '.comment.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)

    # Rebase sentinel check (highest priority, before bot-skip)
    if echo "$comment_body" | grep -qF "<!-- auto-rebase-conflict:"; then
      context=$(printf '{"pr_number":%s}' "${pr_number:-0}")
      emit_intent "rebase" "rebase-conflict-sentinel" "$context"
      exit 0
    fi

    # Skip self (BOT_USER) unless it's the rebase sentinel
    if [ "$commenter" = "$BOT_USER" ]; then
      emit_skip "self-comment"
      exit 0
    fi

    context=$(jq -nc \
      --argjson pr_number "${pr_number:-0}" \
      --arg actor "${commenter:-}" \
      --arg body "${comment_body:-}" \
      '{"pr_number":$pr_number,"actor":$actor,"body":$body}')

    if is_trusted_bot "$commenter"; then
      # Authorship gate (#1311): a bot comment only drives dev-lead's auto-fix/
      # push on a PR dev-lead authored (author == BOT_USER; issue_comment
      # payloads carry no head ref). On a human's PR it is advisory. The rebase
      # sentinel above and the on-mention branch below are intentionally exempt.
      if ! is_dev_lead_authored; then
        emit_skip "not-dev-lead-authored"
        exit 0
      fi
      emit_intent "fix-bot-comment" "trusted-bot-comment" "$context"
    elif is_human_trusted "$author_assoc" && has_trigger_phrase "$comment_body"; then
      emit_intent "on-mention" "human-comment-trigger" "$context"
    else
      emit_skip "no-trigger-or-untrusted"
    fi
    ;;

  # ── issues ────────────────────────────────────────────────────────────────
  issues)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    issues_action=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [ "$issues_action" != "labeled" ]; then
      emit_skip "issues-not-labeled"
      exit 0
    fi
    label_name=$(jq -r '.label.name // empty' "$EVENT_PATH" 2>/dev/null || true)
    issue_number=$(jq -r '.issue.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    case "$label_name" in
      dev-lead)
        context=$(printf '{"issue_number":%s}' "${issue_number:-0}")
        emit_intent "issue" "issue-labeled-${label_name}" "$context"
        ;;
      *)
        emit_skip "label-not-dev-lead"
        ;;
    esac
    ;;

  # ── repository_dispatch ───────────────────────────────────────────────────
  repository_dispatch)
    if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
      emit_skip "no-event-path"
      exit 0
    fi
    dispatch_type=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.client_payload.pr_number // empty' "$EVENT_PATH" 2>/dev/null || true)
    issue_number=$(jq -r '.client_payload.issue_number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.client_payload.head_sha // empty' "$EVENT_PATH" 2>/dev/null || true)

    # The subject whose labels gate hands-off. PR-based dispatch types carry
    # pr_number; the issue-retry type (#781) carries issue_number instead. Both
    # resolve under repos/<repo>/issues/<n>/labels (PRs are issues for labels),
    # so an issue-only payload is no longer dropped before routing.
    subject_number="${pr_number:-$issue_number}"
    if [ -z "$subject_number" ]; then
      emit_skip "no-subject-number-in-payload"
      exit 0
    fi

    # Honour hands-off for dispatch events: the event payload carries no labels,
    # so fetch them via the API before routing. Fail closed: if the API call
    # fails (auth error, transient failure, token without label read access),
    # skip rather than route with unknown label state.
    _dispatch_labels=""
    if ! _dispatch_labels=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${subject_number}/labels" \
        --paginate --jq '.[].name' 2>/dev/null); then
      emit_skip "label-lookup-error"
      exit 0
    fi
    if echo "$_dispatch_labels" | grep -qxF "dev-lead:hands-off"; then
      emit_skip "hands-off-label"
      exit 0
    fi
    unset _dispatch_labels

    case "$dispatch_type" in
      dev-lead-ci-failure)
        if [ -z "$pr_number" ]; then
          emit_skip "no-pr-number-in-payload"
          exit 0
        fi
        checks=$(jq -c '.client_payload.checks // []' "$EVENT_PATH" 2>/dev/null || echo "[]")
        context=$(jq -nc \
          --argjson pr_number "$pr_number" \
          --arg head_sha "${head_sha:-}" \
          --argjson checks "$checks" \
          '{"pr_number":$pr_number,"head_sha":$head_sha,"checks":$checks}')
        emit_intent "fix-ci" "ci-failure-dispatch" "$context"
        ;;
      dev-lead-reviews-retry)
        if [ -z "$pr_number" ]; then
          emit_skip "no-pr-number-in-payload"
          exit 0
        fi
        intent_type=$(jq -r '.client_payload.intent_type // empty' "$EVENT_PATH" 2>/dev/null || true)
        case "$intent_type" in
          fix-reviews|fix-bot-comment|on-mention|review-changes|rebase)
            context=$(jq -nc \
              --argjson pr_number "$pr_number" \
              --arg head_sha "${head_sha:-}" \
              '{"pr_number":$pr_number,"head_sha":$head_sha}')
            emit_intent "$intent_type" "reviews-retry-dispatch" "$context"
            ;;
          human-pr)
            # Legacy alias: human-pr was renamed to review-changes.
            context=$(jq -nc \
              --argjson pr_number "$pr_number" \
              --arg head_sha "${head_sha:-}" \
              '{"pr_number":$pr_number,"head_sha":$head_sha}')
            emit_intent "review-changes" "reviews-retry-dispatch" "$context"
            ;;
          *)
            emit_skip "unknown-reviews-retry-intent-type"
            ;;
        esac
        ;;
      dev-lead-issue-retry)
        # Bounded auto-retry of a failed initial issue implementation (#781). The
        # payload is issue-only (no PR exists yet); route to the existing `issue`
        # intent so the same handler re-runs the implementation. The issue
        # handler re-derives all context fresh from the issue, so a re-dispatch
        # has full fidelity (like the PR-side retryable intents).
        if [ -z "$issue_number" ]; then
          emit_skip "no-issue-number-in-payload"
          exit 0
        fi
        context=$(printf '{"issue_number":%s}' "$issue_number")
        emit_intent "issue" "issue-retry-dispatch" "$context"
        ;;
      *)
        emit_skip "unknown-dispatch-type"
        ;;
    esac
    ;;

  # ── everything else ───────────────────────────────────────────────────────
  *)
    emit_skip "not-implemented"
    ;;

esac
