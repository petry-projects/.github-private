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
#   human           — Human-directed @mention task
#   human-pr        — Human review changes-requested
#   issue           — Issue labeled dev-lead/claude
#   rebase          — Rebase conflict sentinel
#   ci-relay        — check_run relay (handled by ci-relay job, not this script)
#   skip            — Event should be ignored

# ── helpers ──────────────────────────────────────────────────────────────────

GITHUB_ENV="${GITHUB_ENV:-/dev/null}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

emit_intent() {
  local intent="$1" reason="${2:-}" context="${3:-}"
  echo "INTENT_TYPE=${intent}" >> "$GITHUB_ENV"
  echo "INTENT_REASON=${reason}" >> "$GITHUB_ENV"
  echo "INTENT_CONTEXT=${context}" >> "$GITHUB_ENV"
  echo "intent_type=${intent}" >> "$GITHUB_OUTPUT"
  echo "intent_reason=${reason}" >> "$GITHUB_OUTPUT"
  echo "intent_context=${context}" >> "$GITHUB_OUTPUT"
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

# is_fork_pr <event_path>
# Returns 0 (true) if the PR head repo differs from GITHUB_REPOSITORY.
is_fork_pr() {
  local event_path="$1"
  local head_repo base_repo
  head_repo=$(jq -r '.pull_request.head.repo.full_name // .head.repo.full_name // empty' "$event_path" 2>/dev/null || true)
  base_repo="${GITHUB_REPOSITORY:-}"
  [ -n "$head_repo" ] && [ "$head_repo" != "$base_repo" ]
}

# ── read event ───────────────────────────────────────────────────────────────

EVENT_NAME="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
BOT_USER="${BOT_USER:-donpetry-bot}"
TRUSTED_BOTS="${TRUSTED_BOTS:-copilot-pull-request-reviewer[bot],gemini-code-assist[bot],sonarqubecloud[bot],coderabbitai[bot]}"
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
        context=$(printf '{"pr_number":%s,"head_sha":"%s"}' "${pr_number:-0}" "${head_sha:-}")
        emit_intent "human-pr" "pr-${pr_action}" "$context"
        ;;
      synchronize)
        # Anti-loop already handled above; now route human syncs
        if [[ "$sender_login" == *"[bot]"* ]]; then
          emit_skip "bot-sync"
          exit 0
        fi
        context=$(printf '{"pr_number":%s,"head_sha":"%s"}' "${pr_number:-0}" "${head_sha:-}")
        emit_intent "human-pr" "pr-synchronize" "$context"
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
    review_state=$(jq -r '.review.state // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.pull_request.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)
    author_assoc=$(jq -r '.pull_request.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)

    # Skip if actor is BOT_USER (self-review)
    if [ "$reviewer" = "$BOT_USER" ]; then
      emit_skip "self-review"
      exit 0
    fi

    # Skip fork PRs
    if is_fork_pr "$EVENT_PATH"; then
      emit_skip "fork-pr"
      exit 0
    fi

    context=$(printf '{"pr_number":%s,"head_sha":"%s"}' "${pr_number:-0}" "${head_sha:-}")

    if is_trusted_bot "$reviewer"; then
      # Bot review: only route non-APPROVED states
      if [ "$review_state" = "APPROVED" ]; then
        emit_skip "bot-approved"
      else
        emit_intent "fix-reviews" "bot-review-${review_state}" "$context"
      fi
    elif is_human_trusted "$author_assoc"; then
      emit_intent "human-pr" "human-review-${review_state}" "$context"
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
    author_assoc=$(jq -r '.pull_request.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)

    context=$(printf '{"pr_number":%s,"head_sha":"%s"}' "${pr_number:-0}" "${head_sha:-}")

    if is_trusted_bot "$commenter"; then
      emit_intent "fix-reviews" "bot-review-comment" "$context"
    elif is_human_trusted "$author_assoc" && has_trigger_phrase "$comment_body"; then
      emit_intent "human" "human-review-comment-trigger" "$context"
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

    commenter=$(jq -r '.comment.user.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    comment_body=$(jq -r '.comment.body // empty' "$EVENT_PATH" 2>/dev/null || true)
    pr_number=$(jq -r '.issue.number // empty' "$EVENT_PATH" 2>/dev/null || true)
    author_assoc=$(jq -r '.issue.author_association // empty' "$EVENT_PATH" 2>/dev/null || true)

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

    context=$(printf '{"pr_number":%s}' "${pr_number:-0}")

    if is_trusted_bot "$commenter"; then
      emit_intent "fix-bot-comment" "trusted-bot-comment" "$context"
    elif is_human_trusted "$author_assoc" && has_trigger_phrase "$comment_body"; then
      emit_intent "human" "human-comment-trigger" "$context"
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
      dev-lead|claude)
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
    if [ "$dispatch_type" != "dev-lead-ci-failure" ]; then
      emit_skip "unknown-dispatch-type"
      exit 0
    fi
    pr_number=$(jq -r '.client_payload.pr_number // empty' "$EVENT_PATH" 2>/dev/null || true)
    head_sha=$(jq -r '.client_payload.head_sha // empty' "$EVENT_PATH" 2>/dev/null || true)
    checks=$(jq -c '.client_payload.checks // []' "$EVENT_PATH" 2>/dev/null || echo "[]")
    if [ -z "$pr_number" ]; then
      emit_skip "no-pr-number-in-payload"
      exit 0
    fi
    context=$(printf '{"pr_number":%s,"head_sha":"%s","checks":%s}' "${pr_number}" "${head_sha:-}" "${checks}")
    emit_intent "fix-ci" "ci-failure-dispatch" "$context"
    ;;

  # ── everything else ───────────────────────────────────────────────────────
  *)
    emit_skip "not-implemented"
    ;;

esac
