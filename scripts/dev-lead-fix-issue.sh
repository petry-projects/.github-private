#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-issue.sh — handles the issue intent
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"
source "$(dirname "$0")/lib/git-identity.sh"

ISSUE_NUMBER="${ISSUE_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"

# Machine-readable marker the retry cron (dev-lead-retry.sh) scans for to requeue
# a failed initial issue implementation. Mirrors the PR-side conventions in
# dev-lead-fix-ci.sh / dev-lead-fix-reviews.sh:
#   <!-- dev-lead-issue <N> status=<failed|rate-limited> attempt=<K> reason=<r> run=<id> [reset=ISO] -->
ISSUE_MARKER_PREFIX="<!-- dev-lead-issue "
# Total attempts (initial + retries) before escalating to a human. Matches the
# MAX_ATTEMPTS=3 convention used by auto-rebase-retry.sh.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
# Label applied when an issue can no longer be auto-retried; the retry cron
# skips issues carrying it.
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-dev-lead:needs-human}"

check_existing_pr() {
  local existing
  existing=$(gh api "repos/${REPO}/pulls?state=open" \
    --jq "[.[] | select(.head.ref | startswith(\"dev-lead/issue-${ISSUE_NUMBER}\"))] | length" 2>/dev/null || echo "0")
  [ "$existing" -gt 0 ]
}

# count_prior_attempts: highest attempt= recorded in any prior dev-lead-issue
# marker on this issue (0 if none). The next attempt is this value + 1.
# --paginate keeps the count accurate on issues with >30 comments.
count_prior_attempts() {
  local prefix="${ISSUE_MARKER_PREFIX}${ISSUE_NUMBER} "
  gh api --paginate "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -s -r --arg p "$prefix" '
        [ .[] | .[]? | .body // ""
          | select(contains($p))
          | capture("attempt=(?<a>[0-9]+)").a
          | tonumber
        ] | max // 0' 2>/dev/null \
    || echo 0
}

# html_escape: escape &, <, > so a redacted snippet cannot break the wrapping
# <pre>/<details> block in the issue comment (mirrors engine.sh:run_writer).
html_escape() {
  sed 's|&|\&amp;|g; s|<|\&lt;|g; s|>|\&gt;|g'
}

# session_snippet: redacted ~40-line tail of the engine session output, wrapped
# in a collapsible <details> block. The source file is already secret-scrubbed
# by engine.sh:run_writer, so no further redaction is needed here.
session_snippet() {
  [ -s /tmp/dev-lead-session-output.txt ] || return 0
  printf '<details><summary>Last 40 lines of engine output (redacted)</summary>\n\n<pre>\n'
  tail -n 40 /tmp/dev-lead-session-output.txt | html_escape
  printf '\n</pre>\n</details>'
}

# ensure_needs_human_label: idempotently create then apply the escalation label.
# gh issue edit --add-label fails if the label does not exist, so create first.
ensure_needs_human_label() {
  gh label create "$NEEDS_HUMAN_LABEL" --repo "$REPO" \
    --color B60205 --description "dev-lead could not complete this issue; needs human attention" \
    2>/dev/null || true
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$NEEDS_HUMAN_LABEL" 2>/dev/null || true
}

# handle_engine_failure <engine_rc>
# Replaces the previous silent `exit 1` (and unifies the rate-limit branch).
# Classifies the cause via the /tmp/dev-lead-failure-reason sidecar written by
# engine.sh, surfaces it on the issue (marker + human-readable comment + run
# link + redacted snippet), and decides retry vs. human escalation. Never
# returns — exits 2 for rate-limit, 1 otherwise (exit semantics unchanged).
handle_engine_failure() {
  local engine_rc="$1"
  rm -f "$prompt_file"

  # Cause class from the engine layer; default to engine-error if the sidecar is
  # absent (e.g. an older engine.sh). exit 2 always means rate-limited.
  local reason="engine-error"
  if [ -s /tmp/dev-lead-failure-reason ]; then
    reason=$(tr -d '[:space:]' < /tmp/dev-lead-failure-reason)
  fi
  [ -n "$reason" ] || reason="engine-error"
  [ "$engine_rc" -eq 2 ] && reason="rate-limited"

  local reset=""
  [ -f /tmp/dev-lead-rate-limit-reset ] && reset=$(cat /tmp/dev-lead-rate-limit-reset)

  local attempt
  attempt=$(( $(count_prior_attempts) + 1 ))
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/${GITHUB_RUN_ID:-}"
  local snippet
  snippet=$(session_snippet)

  # Deterministic infra failure (missing engine binary): retrying cannot help —
  # escalate to a human immediately, no retry marker.
  if [ "$reason" = "missing-binary" ]; then
    echo "::error::Engine binary missing while implementing issue #${ISSUE_NUMBER} — escalating to human"
    ensure_needs_human_label
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "<!-- dev-lead-issue ${ISSUE_NUMBER} status=needs-human attempt=${attempt} reason=${reason} run=${GITHUB_RUN_ID:-} -->
## Dev-Lead: cannot implement issue #${ISSUE_NUMBER} — needs human attention

A required engine binary was missing in the runner environment while implementing this issue. This is an **infrastructure/configuration** problem, not a transient error, so automatic retry is disabled.

- **Cause:** \`${reason}\`
- **Run:** ${run_url}

${snippet}

Please check the runner/engine configuration, then re-apply the \`dev-lead\` label to retry." 2>/dev/null || true
    exit 1
  fi

  # Retries exhausted: escalate to a human, no further retry marker.
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "::error::Engine failed to implement issue #${ISSUE_NUMBER} (reason=${reason}); retries exhausted (attempt ${attempt}/${MAX_ATTEMPTS}) — escalating to human"
    ensure_needs_human_label
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "<!-- dev-lead-issue ${ISSUE_NUMBER} status=needs-human attempt=${attempt} reason=${reason} run=${GITHUB_RUN_ID:-} -->
## Dev-Lead: cannot implement issue #${ISSUE_NUMBER} — needs human attention

Automatic retries are exhausted (**attempt ${attempt} of ${MAX_ATTEMPTS}**). The most recent failure was \`${reason}\`.

- **Run:** ${run_url}

${snippet}

Please review the failures above. To retry anyway, remove the \`${NEEDS_HUMAN_LABEL}\` label and re-apply the \`dev-lead\` label." 2>/dev/null || true
    [ "$engine_rc" -eq 2 ] && exit 2
    exit 1
  fi

  # Retryable (rate-limited or engine-error, attempt < MAX): post the marker the
  # retry cron scans for, plus a human-readable comment with the cause.
  local status="failed"
  [ "$reason" = "rate-limited" ] && status="rate-limited"
  local reset_attr=""
  [ -n "$reset" ] && reset_attr=" reset=${reset}"
  local marker="${ISSUE_MARKER_PREFIX}${ISSUE_NUMBER} status=${status} attempt=${attempt} reason=${reason} run=${GITHUB_RUN_ID:-}${reset_attr} -->"

  local cause_line reset_line=""
  if [ "$reason" = "rate-limited" ]; then
    echo "::warning::All engines rate-limited while implementing issue #${ISSUE_NUMBER} (attempt ${attempt}/${MAX_ATTEMPTS}) — will retry automatically"
    cause_line="All engines were **rate-limited**."
    [ -n "$reset" ] && reset_line="
- **Limit resets:** ${reset}"
  else
    echo "::error::Engine failed to implement issue #${ISSUE_NUMBER} (reason=${reason}, attempt ${attempt}/${MAX_ATTEMPTS}) — will retry automatically"
    cause_line="The engine failed (\`${reason}\` — e.g. a timeout or transient engine error)."
  fi

  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "${marker}
## Dev-Lead: issue #${ISSUE_NUMBER} implementation failed — will retry

${cause_line} This was **attempt ${attempt} of ${MAX_ATTEMPTS}**; dev-lead will retry automatically. You can also re-apply the \`dev-lead\` label to retry now.

- **Cause:** \`${reason}\`
- **Run:** ${run_url}${reset_line}

${snippet}" 2>/dev/null || true

  [ "$engine_rc" -eq 2 ] && exit 2
  exit 1
}

main() {
  if [ -z "$ISSUE_NUMBER" ]; then
    echo "::error::ISSUE_NUMBER is required"
    exit 1
  fi

  if check_existing_pr; then
    echo "::notice::Existing open PR found for issue #${ISSUE_NUMBER} — skipping (dedup)"
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "<!-- dev-lead-issue-dedup -->Already working on this: an open PR exists for issue #${ISSUE_NUMBER}." 2>/dev/null || true
    exit 0
  fi

  # Gather issue context
  export ISSUE_NUMBER ISSUE_URL="https://github.com/${REPO}/issues/${ISSUE_NUMBER}"
  export REPO
  ISSUE_TITLE=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.title' 2>/dev/null || echo "Unknown")
  ISSUE_BODY=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.body // ""' 2>/dev/null || echo "")
  ORG_STANDARDS_HINT="See AGENTS.md and docs/ for coding standards."
  export ISSUE_TITLE ISSUE_BODY ORG_STANDARDS_HINT
  # Export lint script path so it is substituted into the rendered prompt.
  # dirname "$0" resolves correctly in both direct (scripts/) and reusable (.dev-lead/scripts/) runs.
  export LINT_SCRIPT="${LINT_SCRIPT:-"$(dirname "$0")/dev-lead-lint.sh"}"

  local prompt_file="/tmp/dev-lead-fix-issue-prompt-$$.md"
  local template_path="${PROMPTS_DIR}/fix-issue.md"
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
    echo "[dry-run] fix-issue: would implement issue #${ISSUE_NUMBER} using prompt: $prompt_file"
    rm -f "$prompt_file"
    exit 0
  fi

  # Configure git identity so the post-engine commit does not fail.
  # BOT_USER is set as a job-level env var in dev-lead-reusable.yml.
  setup_git_identity

  # Create feature branch
  local branch
  branch="dev-lead/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M)"
  git checkout -b "$branch"
  local pre_engine_sha
  pre_engine_sha=$(git rev-parse HEAD)

  local engine_rc=0
  run_writer_with_fallback "$prompt_file" "fix-issue" || engine_rc=$?
  if [ "$engine_rc" -ne 0 ]; then
    # Unified failure handler: classifies the cause, surfaces it on the issue
    # (marker + comment + run link + redacted snippet), and decides retry vs.
    # human escalation. Never returns — exits 2 (rate-limit) or 1 (otherwise).
    handle_engine_failure "$engine_rc"
  fi

  # git status --porcelain catches untracked files that git diff misses.
  # Compare HEAD to pre-engine SHA to detect commits the engine made via Bash.
  local has_uncommitted=false has_unpushed=false
  [ -n "$(git status --porcelain)" ] && has_uncommitted=true
  [ "$(git rev-parse HEAD)" != "$pre_engine_sha" ] && has_unpushed=true

  if ! $has_uncommitted && ! $has_unpushed; then
    echo "::notice::No changes made for issue #${ISSUE_NUMBER}"
    rm -f "$prompt_file"
    exit 0
  fi

  # Run lint before committing to prevent avoidable CI failures.
  # LINT_SCRIPT was exported above (resolves to the correct path in both direct and reusable runs).
  local lint_rc=0
  local lint_output=""
  if [ -f "$LINT_SCRIPT" ]; then
    lint_output=$(bash "$LINT_SCRIPT" 2>&1) || lint_rc=$?
  fi

  if [ "$lint_rc" -ne 0 ]; then
    echo "::error::Lint check failed — aborting commit to prevent CI failure. Re-apply the dev-lead label after fixing lint errors."
    echo "$lint_output"
    local _lint_body
    _lint_body="<!-- dev-lead-lint-failed -->
## Dev-Lead: Lint Check Failed

The implementation for issue #${ISSUE_NUMBER} contained lint errors. The commit was **aborted** to prevent a CI failure.

\`\`\`
${lint_output}
\`\`\`

**To retry:** fix the lint errors locally (or re-apply the \`dev-lead\` label — the agent will try again)."
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$_lint_body" 2>/dev/null || true
    rm -f "$prompt_file"
    exit 1
  fi

  if $has_uncommitted; then
    git add -A
    git commit -m "feat: implement issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}"
  fi
  git push --set-upstream origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --title "feat: implement issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}" \
    --body "Closes #${ISSUE_NUMBER}

Implemented by dev-lead agent. Please review." \
    --head "$branch"

  rm -f "$prompt_file"
}

main "$@"
