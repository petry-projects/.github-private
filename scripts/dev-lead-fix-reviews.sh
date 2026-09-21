#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-reviews.sh — handles review-related intents
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"
source "$(dirname "$0")/lib/git-identity.sh"
source "$(dirname "$0")/lib/pr-worktree.sh"
source "$(dirname "$0")/lib/auto-merge.sh"
source "$(dirname "$0")/lib/git-push-guard.sh"
source "$(dirname "$0")/lib/pr-automation-budget.sh"
source "$(dirname "$0")/lib/maintainer-review-thread-gate.sh"
source "$(dirname "$0")/lib/conflict-integrity.sh"
source "$(dirname "$0")/lib/review-change-evidence.sh"
source "$(dirname "$0")/lib/resolution-integrity.sh"
source "$(dirname "$0")/lib/addressed-claim-verify.sh"
# PR issue-comment disposition verifier (#1813): the issue-comment sibling of
# addressed-claim-verify.sh. Turns a dev-lead comment-disposition reply into a
# machine-checkable claim the harness verifies before minimizing the original
# comment RESOLVED.
source "$(dirname "$0")/lib/comment-disposition-verify.sh"
# The issue-comment gate — sourced for its agent-marker regex
# ($_MAINTAINER_GATE_AGENT_MARKERS), so resolve_dispositioned_comments excludes
# our own disposition/ack/note replies with the SAME discriminator the gate uses
# (single source of truth; #1813 loop safety AC7).
source "$(dirname "$0")/lib/maintainer-comment-gate.sh"
# Structured PR-body backfill (#1805): heal an existing PR whose body is still
# missing 3+ required description sections, once, marker-keyed.
source "$(dirname "$0")/lib/dev-lead-pr-body.sh"
source "$(dirname "$0")/lib/redact.sh"
# Rebase exhaustion handling (#865): abort cleanly on hard conflicts instead of
# timing out (exit 124), and dampen sentinel bursts.
source "$(dirname "$0")/lib/rebase-exhaustion.sh"
# CI gate status (#1859, completes #1795): the blocker check delegates to
# compute_ci_status so a failing NON-required check never stops the
# fix/disposition pass — the same library review-one-pr.sh and the sweeps use.
source "$(dirname "$0")/lib/ci-status.sh"

INTENT_TYPE="${INTENT_TYPE:-fix-reviews}"
PR_NUMBER="${PR_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
HEAD_SHA="${HEAD_SHA:-}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"
# Pin PROMPTS_DIR to an absolute path now, while CWD still points at the agent
# checkout — checkout_pr_in_worktree cds into the PR worktree, after which a
# relative PROMPTS_DIR would resolve against the PR branch (issue #448).
PROMPTS_DIR="$(resolve_abs "$PROMPTS_DIR")"
export PROMPTS_DIR

REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="
INTEGRITY_MARKER_PREFIX="<!-- dev-lead-conflict-integrity pr="
NONCONVERGE_MARKER_PREFIX="<!-- dev-lead-review-nonconverge pr="
# Consecutive not-applied passes against the same review before escalating to a
# human (#1567 AC #4). A pass "does not converge" when it commits something but
# addresses none of the regions the review named.
REVIEW_NONCONVERGENCE_LIMIT="${REVIEW_NONCONVERGENCE_LIMIT:-3}"

if [ -z "$PR_NUMBER" ] && [ "$INTENT_TYPE" != "rebase" ]; then
  echo "::error::PR_NUMBER is required"
  exit 1
fi

# Per-PR automation budget (#926): if this PR has exhausted its lifetime
# automation budget since the last human interaction, stop before any writes.
# Checked before holding auto-merge so the escalation's auto-merge disable is not
# undone by the restore_auto_merge EXIT trap. Only a human interaction resets it.
if [ -n "${PR_NUMBER:-}" ] && [ "${DEV_LEAD_DRY_RUN:-false}" != "true" ] \
   && enforce_pr_budget "$PR_NUMBER" "$REPO"; then
  echo "::warning::PR #${PR_NUMBER} automation budget exhausted — skipping ${INTENT_TYPE}"
  exit 0
fi

# Checkout the PR branch for modification (Requirement 1).
# Use an isolated worktree so switching to the PR branch never overwrites the
# agent's own prompts/scripts in the working tree (issue #448).
if [ "${DEV_LEAD_DRY_RUN:-false}" = "false" ] && [ -n "${PR_NUMBER:-}" ]; then
  # Hold auto-merge OFF while we work so a review approval landing mid-run can't
  # merge (and delete) the branch out from under us. restore_auto_merge (EXIT
  # trap) puts it back however we exit; checkout_pr_in_worktree chains its own
  # cleanup onto this trap.
  trap restore_auto_merge EXIT
  hold_auto_merge
  # Resolve HEAD_SHA after holding auto-merge: for issue_comment intents
  # (on-mention, fix-bot-comment) only pr_number is provided, not head_sha.
  # Resolving here rather than before the hold closes the window where an
  # approval could satisfy branch protection during the API call and let
  # GitHub auto-merge the branch before the hold is installed.
  if [ -z "${HEAD_SHA:-}" ]; then
    HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || true)
  fi
  checkout_pr_in_worktree "$PR_NUMBER" "$REPO"
  # Immutable snapshot of the head this pass starts from — captured at the one
  # moment that actually means "before this pass did any work" (#1617). The
  # resolution gate compares against THIS, not HEAD_SHA: HEAD_SHA is the
  # event-time SHA (only re-resolved when empty, line 67) and is reassigned by
  # try_enable_auto_merge, so a commit landing between the event and this
  # checkout would make HEAD_SHA differ from the checked-out head and open the
  # gate on a no-commit pass. RESOLUTION_BASE_SHA is set once here and never
  # reassigned, so the gate measures only whether THIS pass advanced the head.
  RESOLUTION_BASE_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
  setup_git_identity
  # Backfill the five required description sections into a pre-existing PR whose
  # body still lacks them (#1805). Idempotent + marker-keyed, so open PRs heal on
  # their next dev-lead pass without churning on every run.
  dlpb_backfill_pr_body "$PR_NUMBER" "$REPO" || true
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
    rm -f "${prompt_file:-}"
    return 0
  fi

  local rc=0
  run_writer_with_fallback "$prompt_file" "${INTENT_TYPE:-}" || rc=$?
  rm -f "${prompt_file:-}"
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

# redact_secrets lives in scripts/lib/redact.sh (sourced above) so this script
# and the persona runtime share one definition (#1775 AC #4).

# read_session_summary: extracts the agent's structured summary from the session
# log and redacts any embedded credentials. Empty output if the file is missing
# (e.g. dry-run paths that never invoked the writer).
#
# Strategy: scan the redacted stream for the *last* occurrence of a known summary
# header (`Bot:`, `PR: #`, `Addressed N threads:`, `Human review threads
# addressed:`, `Issues addressed:` — see prompts/dev-lead/*.md "Output Format")
# and emit from that line to EOF, capped at 30 non-blank lines. Falls back to
# the last 30 non-blank lines when no marker is present, preserving the prior
# tail behaviour for unstructured output. grep -n + sed avoids loading the log
# into an awk array (gemini medium finding).
#
# Redaction runs over the full log *before* the marker search, so PEM blocks
# that straddle the marker window are fully redacted (header outside the kept
# window, body inside the kept window would otherwise leak plaintext key
# material).
read_session_summary() {
  local log="/tmp/dev-lead-session-output.txt"
  [[ -f "$log" ]] || return 0
  local redacted
  redacted="$(redact_secrets < "$log")"
  local mark
  mark=$(printf '%s\n' "$redacted" | grep -nE \
    '^(Bot:|PR: #|Addressed [0-9]+ threads?:|Human review threads addressed:|Issues addressed:)' \
    | tail -1 | cut -d: -f1)
  if [ -n "$mark" ]; then
    printf '%s\n' "$redacted" | sed -n "${mark},\$p" | sed '/^[[:space:]]*$/d' | head -30
  else
    printf '%s\n' "$redacted" | tail -30 | sed '/^[[:space:]]*$/d' | tail -10
  fi
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

# post_integrity_warning: posts a single advisory PR comment when the
# post-resolution integrity check finds duplicate top-level declarations the
# resolution introduced. Signal-only (#1482 AC #4) — it never blocks, reverts,
# or changes the caller's exit code; a maintainer decides what to do. The
# marker keeps it idempotent so a re-dispatched rebase does not stack comments.
post_integrity_warning() {
  local report="$1"
  local marker="${INTEGRITY_MARKER_PREFIX}${PR_NUMBER} -->"
  local body="${marker}
> [!WARNING]
> **Post-conflict-resolution integrity check flagged this resolution.**
> The automated rebase introduced **duplicate top-level declarations** — the
> #1449 corruption pattern, where a botched merge silently doubled functions and
> the damage was only found hours later by an unrelated failing test. This is
> **advisory**: the resolution is not blocked or reverted. Please verify the
> file(s) below before trusting this branch.

${report}
_Detected by \`scripts/lib/conflict-integrity.sh\` (#1482). If this repetition is intentional, disregard._"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post conflict-integrity warning for PR ${PR_NUMBER}"
    echo "$body"
    return 0
  fi
  # Idempotent: skip if an integrity marker for this PR already exists.
  if gh pr view "$PR_NUMBER" --repo "$REPO" --json comments \
       --jq '.comments[].body' 2>/dev/null | grep -F "$marker" > /dev/null; then
    echo "conflict-integrity marker already present on PR ${PR_NUMBER} — skipping"
    return 0
  fi
  # Best-effort: don't fail the overall rebase if the advisory post fails.
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body" 2>/dev/null || true
}

# run_post_resolution_integrity_check: after an automated conflict resolution
# lands, scan the shell files it touched for duplicate top-level declarations
# the resolution *introduced* (#1449 corruption class). Parents are the base ref
# (origin/<base>) and the branch tip before the resolution (<pre_ref>); a symbol
# whose declaration count exceeds both parents is flagged. Runs on the
# conflict-resolution path itself (#1482 AC #2) rather than waiting for an
# unrelated downstream test to trip over the corruption.
run_post_resolution_integrity_check() {
  local base_ref="$1" pre_ref="$2"
  [ -n "$pre_ref" ] || return 0

  local changed
  # Compare pre_ref to the working tree (not just HEAD) so that uncommitted
  # worktree edits left by the agent are also included in the scan (#1496).
  changed="$(git diff --name-only "$pre_ref" -- '*.sh' 2>/dev/null || true)"
  [ -n "$changed" ] || return 0

  local report="" file findings pa pb
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue   # deleted by the resolution — nothing to check
    pa="$(mktemp)"; pb="$(mktemp)"
    git show "origin/${base_ref}:${file}" >"$pa" 2>/dev/null || : >"$pa"
    git show "${pre_ref}:${file}" >"$pb" 2>/dev/null || : >"$pb"
    findings="$(new_duplicate_symbols "$file" "$pa" "$pb")"
    rm -f "$pa" "$pb"
    if [ -n "$findings" ]; then
      report="${report}$(format_integrity_findings "$file" "$findings")
"
    fi
  done <<EOF
${changed}
EOF

  [ -n "$report" ] || return 0
  post_integrity_warning "$report"
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
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@coderabbitai resolve <!-- dev-lead -->" 2>/dev/null || true
  fi
}

# resolve_actor_outdated_threads: best-effort safety net for the no-changes path.
# Resolves any open review threads on this PR that are isOutdated AND authored by ACTOR
# (matched against both the raw ACTOR string and ACTOR with any "[bot]" suffix stripped,
# since GitHub Actions includes the suffix but GraphQL author.login does not).
# Outdated threads reference code that no longer exists, so resolution is unambiguously
# safe. Independent of whether the agent decided to resolve them.
#
# RESOLVE-GUARD (#1415). dev-lead acts as the owner `don-petry` — the SAME account a
# human maintainer uses — so ACTOR-authored is NOT sufficient to prove a thread is
# ours: a maintainer's inline review left as `don-petry` matches the ACTOR filter
# exactly (this is the PR #1413 shape). Login cannot discriminate a maintainer from
# the agent here, so when the author is maintainer-capable — NOT one of the advisory/
# automation bots (review_thread_login_is_excluded_bot) and NOT our own bot login —
# each candidate is additionally gated on the automation MARKER in its originating
# comment via review_thread_is_agent_authored(): a marker-less thread is a maintainer
# finding and is SKIPPED with a visible ::warning:: rather than silently resolved.
# The guard uses the SAME maintainer definition as check_maintainer_review_threads
# (marker-less AND non-excluded-bot AND non-bot_user), so an outdated advisory-bot
# thread (e.g. codex/coderabbit) stays freely resolvable — only a genuine maintainer
# finding is held back. This is the review-path application of #860 rule 2 — "a gate
# whose reset is reachable by the agent is not a gate" — to review/merge gates
# (docs/agentic-interaction-model.md).
#
# ACTOR is passed to jq via --arg (not shell interpolation) so a hostile actor value
# can't escape the filter. reviewThreads(first:100) is the GraphQL max for a single
# page — PRs with >100 review threads will still leave some outdated ones unresolved,
# but full cursor pagination is overkill for a best-effort safety net.
resolve_actor_outdated_threads() {
  local intent="$1"
  if [ -z "${ACTOR:-}" ]; then
    echo "::notice::resolve_actor_outdated_threads: ACTOR not set for intent=${intent} — skipping"
    return 0
  fi
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve outdated review threads authored by ${ACTOR} on PR #${PR_NUMBER}"
    return 0
  fi

  local actor_stripped="${ACTOR%\[bot\]}"
  local pairs
  # Emit "<thread_id>\t<base64(originating comment body)>" per candidate so the
  # resolve-guard can inspect the marker without the body's quotes/newlines
  # breaking the read loop. gh api's --jq does not accept --arg, so pipe to jq
  # directly to bind the actor values as data (not shell-interpolated).
  pairs=$(gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes { id isResolved isOutdated comments(first:1) { nodes { author { login } body } } }
          }
        }
      }
    }' \
    -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" 2>/dev/null \
    | jq -r --arg actor "$ACTOR" --arg actor_stripped "$actor_stripped" \
        '.data.repository.pullRequest.reviewThreads.nodes
          | map(select(.isResolved == false
                       and .isOutdated == true
                       and (.comments.nodes[0]?.author?.login == $actor
                            or .comments.nodes[0]?.author?.login == $actor_stripped)))
          | .[] | .id + "\t" + ((.comments.nodes[0]?.body // "") | @base64)' 2>/dev/null || true)

  if [ -z "$pairs" ]; then
    echo "::notice::no outdated unresolved threads from ${ACTOR} on PR #${PR_NUMBER}"
    return 0
  fi

  # The jq filter binds every candidate's originating author.login to ACTOR (raw or
  # [bot]-stripped), so a single up-front check decides whether the marker guard
  # applies: it fires only for a maintainer-capable ACTOR — one that is NOT an
  # advisory/automation bot and NOT our own bot login. An advisory-bot ACTOR (e.g.
  # codex/coderabbit) leaves its outdated threads freely resolvable, preserving the
  # pre-#1415 safety-net behavior.
  local actor_is_maintainer_capable=true
  if review_thread_login_is_excluded_bot "$actor_stripped" \
     || [ "$actor_stripped" = "${BOT_USER:-donpetry-bot}" ]; then
    actor_is_maintainer_capable=false
  fi

  local resolved_count=0
  local id body_b64 body
  while IFS=$'\t' read -r id body_b64; do
    [ -z "$id" ] && continue
    body=$(printf '%s' "$body_b64" | base64 --decode 2>/dev/null || printf '%s' "$body_b64" | base64 -d 2>/dev/null || echo "")
    # Resolve-guard (#1415): for a maintainer-capable ACTOR, only resolve a thread
    # whose originating comment carries one of our automation markers. A marker-less
    # thread authored as `don-petry` is a maintainer finding the agent must NOT clear
    # — fail closed and log the skip.
    if [ "$actor_is_maintainer_capable" = true ] && ! review_thread_is_agent_authored "$body"; then
      echo "::warning::resolve-guard: skipping thread ${id} — originating comment carries no automation marker, treated as a maintainer finding (must not be agent-resolved, #1415)"
      continue
    fi
    if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
        -f id="$id" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::resolved outdated thread ${id} (author=${ACTOR})"
    else
      echo "::warning::failed to resolve outdated thread ${id}"
    fi
  done <<< "$pairs"
  echo "::notice::resolve_actor_outdated_threads: resolved ${resolved_count} outdated thread(s) on PR #${PR_NUMBER}"
}

# fetch_pr_context: exports CI_STATUS_JSON and ALL_REVIEWS_JSON for holistic assessment.
# Called before engine invocation in fix-reviews, fix-bot-comment, and review-changes
# so the agent can identify Tier-1 blockers (failing CI + CHANGES_REQUESTED reviews)
# and never wrongly declare "no-changes" while the PR is still blocked.
fetch_pr_context() {
  # Base branch: _ci_required_checks reads the ruleset for the PR's ACTUAL target
  # branch. Some intents (fix-bot-comment, review-changes) do not receive BASE_REF
  # from the workflow, so derive it from the PR here rather than falling back to
  # `main` — otherwise the ruleset lookup applies the wrong required-check rules to
  # a PR targeting another branch. Intents that already export BASE_REF are left
  # untouched (guarded on empty), and `main` remains the final fallback.
  if [ -z "${BASE_REF:-}" ] && [ -n "${PR_NUMBER:-}" ] && [ -n "${REPO:-}" ]; then
    BASE_REF="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.base.ref // empty' 2>/dev/null || true)"
    export BASE_REF="${BASE_REF:-main}"
  fi

  # CI check results: requires HEAD_SHA. Gracefully degrade to empty array when not set
  # (e.g., review-changes in dry-run where the PR API call is skipped).
  CI_STATUS_JSON="[]"
  if [ -n "${HEAD_SHA:-}" ]; then
    # Two-stage check-run dedup:
    # Stage 1: group by (name, app.id, check_suite.id) and keep the highest-id
    #   run per suite. check_suite discriminates distinct workflow runs, so two
    #   workflows that happen to share a job name are kept as separate entries.
    #   id is always present and monotonically increasing, so it reliably picks
    #   the newest run even when started_at is absent (e.g. queued runs).
    # Stage 2: drop cancelled/timed_out runs when a newer run (higher id, same
    #   name+app) has a terminal non-cancelled conclusion. This collapses a
    #   concurrency-cancelled run from an earlier suite once its replacement
    #   succeeds, without hiding a genuinely failing check from a distinct
    #   workflow. A lone cancelled/timed_out run (no newer replacement) still
    #   counts as a Tier-1 blocker (issue #461).
    #
    # Stage 2 deliberately matches on (name, app) ACROSS suites — wider than
    # Stage 1's key. The asymmetry is load-bearing: a concurrency-cancelled
    # run is superseded by a run from a *different* event, which always lives
    # in a *different* check suite (the PR #453 incident shape), so requiring
    # suite equality here would never drop anything and would reintroduce the
    # endless 30-minute retry loop. The check-runs API exposes no workflow
    # identity, so a cancelled check from a sibling workflow sharing a
    # name+app with a newer success is also dropped — accepted trade-off:
    # GitHub's own required-check gate keys on the latest same-named run
    # (PR #453 merged with stale cancelled `review` runs still on its head
    # SHA), so such a PR is not actually merge-blocked. Failures are exempt
    # from Stage 2 (conservative: a real failure from a sibling workflow
    # stays visible to the agent even when GitHub would let the merge pass).
    if ! CI_STATUS_JSON=$(gh api --paginate "repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100" \
      2>/dev/null \
      | jq -s '[.[].check_runs[]?]
               | group_by([.name, (.app.id // null), (.check_suite.id // null)])
               | map(sort_by([.id // 0]) | last)
               | . as $runs
               | map(select(
                   (.conclusion != "cancelled" and .conclusion != "timed_out")
                   or (. as $r | ($runs | any(
                         .name == $r.name
                         and (.app.id // null) == ($r.app.id // null)
                         and (.id // 0) > ($r.id // 0)
                         and .conclusion != null
                         and .conclusion != "cancelled"
                         and .conclusion != "timed_out"
                       )) | not)
                 ))
               | map({name:.name, status:.status, conclusion:.conclusion, details_url:.details_url})' \
      2>/dev/null); then
      echo "::error::fetch_pr_context: failed to fetch CI check-runs for ${HEAD_SHA} — cannot assess PR state" >&2
      return 1
    fi
    # Also include legacy commit statuses (Jenkins, external CI, etc.) that use
    # the separate statuses API rather than check-runs. Merge into CI_STATUS_JSON
    # so the agent sees a unified picture of all required status checks.
    local statuses_json
    # The statuses API returns the full history per context (newest first).
    # Dedupe by context so a stale failure overwritten by a later success does not
    # appear as a Tier-1 blocker: group_by preserves input order within each group,
    # so `first` picks the newest entry for each context.
    if statuses_json=$(gh api --paginate "repos/${REPO}/commits/${HEAD_SHA}/statuses?per_page=100" \
      2>/dev/null \
      | jq -s '[ [.[].[] | select(.context != null)] | group_by(.context)[] | first | {name:.context, status:(if .state == "pending" then "in_progress" else "completed" end), conclusion:(if .state == "success" then "success" elif .state == "failure" or .state == "error" then "failure" else "pending" end), details_url:.target_url} ]' \
      2>/dev/null); then
      CI_STATUS_JSON=$(printf '%s\n%s' "$CI_STATUS_JSON" "$statuses_json" \
        | jq -s 'add // []' 2>/dev/null || echo "$CI_STATUS_JSON")
    else
      echo "::error::fetch_pr_context: failed to fetch legacy commit statuses for ${HEAD_SHA} — cannot assess PR state" >&2
      return 1
    fi
  fi
  export CI_STATUS_JSON

  # All PR reviews with state — deduplicated per reviewer (latest review per user only).
  # Uses --paginate so PRs with more than 100 reviews are fully covered.
  # COMMENTED reviews do not supersede a prior CHANGES_REQUESTED or APPROVED — only
  # non-COMMENTED reviews determine the effective blocking state per user.
  if ! ALL_REVIEWS_JSON=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100" \
    2>/dev/null \
    | jq -s '[ [.[].[] | select(.user != null)] | group_by(.user.login)[] | . as $g | (($g | map(select(.state != "COMMENTED")) | sort_by(.id) | last) // ($g | sort_by(.id) | last)) | {id:.id, user:.user.login, state:.state, submitted_at:.submitted_at, body:.body, all_change_request_bodies:($g | map(select(.state == "CHANGES_REQUESTED")) | sort_by(.id) | map(.body))} ]' \
    2>/dev/null); then
    echo "::error::fetch_pr_context: failed to fetch PR reviews for #${PR_NUMBER} — cannot assess PR state" >&2
    return 1
  fi
  export ALL_REVIEWS_JSON
}

# resolve_bot_outdated_threads: resolves all outdated review threads from bot reviewers.
# This is a cleanup function for the no-changes path: when no code changes are needed,
# we still want to mark outdated bot comments as resolved so they don't clutter the PR.
# Outdated threads reference code that no longer exists, so resolution is unambiguous.
#
# Paginated: fetches all threads via cursor pagination so PRs with >100 threads are
# fully covered. Unlike resolve_actor_outdated_threads, this resolves threads from ANY
# bot author (__typename == "Bot", or login ends with [bot]).
resolve_bot_outdated_threads() {
  local intent="$1"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve outdated review threads from bot reviewers on PR #${PR_NUMBER}"
    return 0
  fi

  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::notice::resolve_bot_outdated_threads: PR_NUMBER not set for intent=${intent} — skipping"
    return 0
  fi

  # Collect IDs of all outdated unresolved bot threads via cursor pagination.
  # __typename == "Bot" covers bots whose GraphQL login omits the [bot] suffix;
  # endswith("[bot]") covers bots that include it — both checks together are belt-and-suspenders.
  local ids=""
  local cursor="" has_next_page="true" page_response page_ids
  local cursor_args=()
  local bot_outdated_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{id isResolved isOutdated comments(first:1){nodes{author{login __typename}}}}
        }
      }
    }
  }'
  while [ "$has_next_page" = "true" ]; do
    page_response=$(gh api graphql -f query="$bot_outdated_query" \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      "${cursor_args[@]}" 2>/dev/null || echo "{}")
    page_ids=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.nodes // []
       | map(select(.isResolved == false
                    and .isOutdated == true
                    and (((.comments.nodes?[0]?.author?.login // "") | endswith("[bot]"))
                         or ((.comments.nodes?[0]?.author?.__typename // "") == "Bot"))))
       | .[].id' 2>/dev/null || true)
    [ -n "$page_ids" ] && ids=$(printf '%s\n%s' "$ids" "$page_ids")
    has_next_page=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.hasNextPage // false' \
      2>/dev/null || echo "false")
    cursor=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.endCursor // ""' \
      2>/dev/null || echo "")
    [ -z "$cursor" ] && has_next_page="false"
    cursor_args=("-f" "cursor=${cursor}")
  done
  # Strip leading/trailing blank lines from accumulated ids
  ids=$(printf '%s' "$ids" | sed '/^[[:space:]]*$/d')

  if [ -z "$ids" ]; then
    echo "::notice::no outdated unresolved threads from bot reviewers on PR #${PR_NUMBER}"
    return 0
  fi

  local resolved_count=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
        -f id="$id" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::resolved outdated bot thread ${id}"
    else
      echo "::warning::failed to resolve outdated bot thread ${id}"
    fi
  done <<< "$ids"
  echo "::notice::resolve_bot_outdated_threads: resolved ${resolved_count} outdated bot thread(s) on PR #${PR_NUMBER}"
}

# resolve_addressed_bot_threads: resolves bot-originated review threads that dev-lead
# has already ADDRESSED in-thread but left unresolved (#1547). Every pr-quality ruleset
# sets required_review_thread_resolution:true, so such a thread — replied-to with
# "Applied in …" / "Verified and confirmed …" yet never resolved — leaves a fully green +
# approved PR silently unmergeable (the 2026-08-18 sweep hand-resolved 20 of these).
#
# Complements resolve_bot_outdated_threads: that net only covers isOutdated threads,
# but an addressed-at-head finding is frequently NOT marked outdated by GitHub. This
# net keys on the addressed-marker (`<!-- dev-lead:addressed -->`) in the thread's LAST
# reply instead of on outdated status, so a non-outdated but already-addressed thread is
# resolved. A *skip* reply carries no marker, so it is never auto-resolved.
#
# Scope guard (#1415): only BOT-originated threads are touched (originating comment
# author is a Bot). A marker-less human/maintainer finding is never resolved here — the
# #1415 resolve-guard applies to the owner-account ambiguity on human threads, and this
# net deliberately stays clear of them.
#
# Paginated via cursor (GraphQL 100/page max). The addressed-marker decision is delegated
# to review_reply_is_addressed_marker (maintainer-review-thread-gate.sh) so the marker is
# defined in exactly one place.
#
# The enumeration pass yields only candidate ids; the authorizing state (isResolved, the
# latest reply's author, and the marker) is re-read per candidate via a fresh node(id)
# fetch taken immediately before the mutation. This closes two gaps in the earlier
# snapshot-trusting design: (a) the marker only authorizes resolution when OUR account
# (BOT_USER, [bot]-suffix-stripped) posted it, so a marker-bearing reply from any other
# human or bot cannot resolve a bot thread; and (b) a reply that landed after enumeration
# is re-checked, so concurrent maintainer feedback can't be resolved against a stale
# snapshot. isResolved is branched on null explicitly so a failed fetch fails closed.
resolve_addressed_bot_threads() {
  local intent="$1"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve addressed review threads from bot reviewers on PR #${PR_NUMBER}"
    return 0
  fi

  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::notice::resolve_addressed_bot_threads: PR_NUMBER not set for intent=${intent} — skipping"
    return 0
  fi

  # Our own account: the addressed-marker reply must have been posted by us before
  # it can authorize resolution. The acv_* thread helpers below derive the
  # [bot]-stripped form internally (GraphQL author.login omits the "[bot]" suffix),
  # so they match both the raw BOT_USER and its stripped form.
  local bot_user="${BOT_USER:-donpetry-bot}"

  # The enumeration pass ONLY collects candidate thread ids (unresolved,
  # bot-originated). It deliberately does NOT capture the last reply's body or
  # author: that snapshot goes stale the moment a new reply lands, and trusting it
  # would (a) let a marker-bearing reply from any other account authorize
  # resolution (#codeant-623) and (b) resolve a thread a maintainer has since
  # replied to (#codeant-666). The authorizing state is re-read per candidate via a
  # fresh node(id) fetch taken immediately before the mutation below.
  local ids=""
  local cursor="" has_next_page="true" page_response page_ids
  local cursor_args=()
  local addressed_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{
            id isResolved
            origin: comments(first:1){nodes{author{login __typename}}}
          }
        }
      }
    }
  }'
  while [ "$has_next_page" = "true" ]; do
    page_response=$(gh api graphql -f query="$addressed_query" \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      "${cursor_args[@]}" 2>/dev/null || echo "{}")
    page_ids=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.nodes // []
       | map(select(.isResolved == false
                    and (((.origin.nodes?[0]?.author?.login // "") | endswith("[bot]"))
                         or ((.origin.nodes?[0]?.author?.__typename // "") == "Bot"))))
       | .[] | .id' 2>/dev/null || true)
    [ -n "$page_ids" ] && ids=$(printf '%s\n%s' "$ids" "$page_ids")
    has_next_page=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.hasNextPage // false' \
      2>/dev/null || echo "false")
    cursor=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.endCursor // ""' \
      2>/dev/null || echo "")
    [ -z "$cursor" ] && has_next_page="false"
    cursor_args=("-f" "cursor=${cursor}")
  done

  if [ -z "$(printf '%s' "$ids" | sed '/^[[:space:]]*$/d')" ]; then
    echo "::notice::no addressed unresolved bot threads on PR #${PR_NUMBER}"
    return 0
  fi

  # Full-thread fetch (#1692 AC4): the earlier `comments(last:1)` read saw only the
  # latest reply, so a maintainer disposition posted before the model appended its
  # marker went invisible (the PR #1044 hole). Read ALL comments — author login +
  # __typename + body + createdAt — plus the thread `path` for the AC3 advisory.
  local node_query='query($id:ID!){
    node(id:$id){
      ... on PullRequestReviewThread {
        isResolved
        path
        comments(first:100){nodes{author{login __typename} body createdAt}}
      }
    }
  }'

  local resolved_count=0
  local id node_json cur_resolved comments_json marker_idx marker_body
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    # Re-read the thread's CURRENT state immediately before resolving so a reply
    # that landed after enumeration is not resolved against a stale snapshot.
    node_json=$(gh api graphql -f query="$node_query" -f id="$id" 2>/dev/null || echo "{}")
    # isResolved is branched on null explicitly (not `// false`) so a fetch that
    # failed to return the field is treated as "unknown" and skipped (fail closed),
    # never as a resolvable false.
    cur_resolved=$(printf '%s' "$node_json" | jq -r \
      'if .data.node.isResolved == null then "unknown"
       elif .data.node.isResolved then "true" else "false" end' 2>/dev/null || echo "unknown")
    if [ "$cur_resolved" != "false" ]; then
      echo "::notice::skipping thread ${id} — already resolved or state unknown at re-check (${cur_resolved})"
      continue
    fi
    # ── #1735: full-thread scan, not comments(last:1) ─────────────────────────
    # Our addressed-marker reply need NOT be the thread's LATEST comment. Find the
    # latest comment OUR account posted carrying the marker; a bot acknowledgement
    # (or our own later note) landing after it must not lock the thread unresolvable
    # forever (the regression #1691 exposed). A marker from any other account still
    # does not authorize resolution (acv_latest_marker_index checks the author).
    comments_json=$(printf '%s' "$node_json" | jq -c '.data.node.comments.nodes // []' 2>/dev/null || echo "[]")
    if ! marker_idx=$(acv_latest_marker_index "$comments_json" "$bot_user"); then
      echo "::notice::skipping thread ${id} — no addressed-marker reply from our account in the thread; leaving unresolved (#1735)"
      continue
    fi
    marker_body=$(printf '%s' "$comments_json" | jq -r --argjson i "$marker_idx" '.[$i]?.body // ""' 2>/dev/null || echo "")

    # Nothing UNADDRESSED may have landed since our marker (#1735 AC2/AC3/AC4): a bot
    # acknowledgement is fine, but a bot NEW finding or ANY human comment (regardless
    # of content, preserving #1415) blocks, and an undeterminable post-marker comment
    # fails closed. This composes with the #1692 claim gate below (AC5) — both must pass.
    local post_reason post_rc
    post_reason=$(acv_post_marker_clear "$comments_json" "$marker_idx" "$bot_user") && post_rc=0 || post_rc=$?
    if [ "${post_rc:-0}" -ne 0 ]; then
      echo "::notice::skipping thread ${id} — an unaddressed comment landed after our marker (${post_reason}); leaving unresolved (#1735)"
      continue
    fi

    # ── #1692: the marker is now a VERIFIABLE CLAIM, not an assertion ──────────
    # A marker with no claim payload (pre-migration replies) is unverifiable — do
    # NOT resolve (the safe direction; may leave some existing threads open until
    # re-run). A malformed/contract-violating claim is likewise unverifiable.
    local claim_json parse_reason
    if ! claim_json=$(acv_parse_claim "$marker_body"); then
      parse_reason="$claim_json"
      echo "::notice::skipping thread ${id} — addressed-marker claim not verifiable (${parse_reason:-unparseable}); leaving unresolved (#1692)"
      continue
    fi
    local claim_sha
    claim_sha=$(printf '%s' "$claim_json" | jq -r '.sha // ""' 2>/dev/null || echo "")

    # Gather the git facts for the claimed commit (the only impure step). Fail
    # closed: an unresolvable commit reads as on_head=false with empty diffs.
    local facts on_head own_files cumulative_files commit_date
    facts=$(acv_gather_commit_facts "$claim_sha")
    on_head=$(printf '%s' "$facts" | jq -r '.on_head // false' 2>/dev/null || echo "false")
    if [ "$on_head" != "true" ]; then
      echo "::notice::skipping thread ${id} — claimed commit ${claim_sha} is not on PR #${PR_NUMBER}'s head branch; leaving unresolved (#1692)"
      continue
    fi
    own_files=$(printf '%s' "$facts" | jq -r '.own_files[]? // empty' 2>/dev/null || echo "")
    cumulative_files=$(printf '%s' "$facts" | jq -r '.cumulative_files[]? // empty' 2>/dev/null || echo "")
    commit_date=$(printf '%s' "$facts" | jq -r '.commit_date // ""' 2>/dev/null || echo "")

    # File-level hard gate (AC2): non-empty diff touching ≥1 claimed file, named
    # commit's own diff first then the cumulative <sha>^..HEAD range.
    local claim_files_json verify_range
    claim_files_json=$(printf '%s' "$claim_json" | jq -c '.files' 2>/dev/null || echo "[]")
    if ! verify_range=$(acv_verify_intersection "$claim_files_json" "$own_files" "$cumulative_files"); then
      echo "::notice::skipping thread ${id} — claim ${claim_sha} not verified against the diff (${verify_range}); leaving unresolved (#1692)"
      continue
    fi
    if [ "$verify_range" = "cumulative" ]; then
      echo "::notice::thread ${id} verified from the cumulative range ${claim_sha}^..HEAD (fix amended/split across commits) (#1692)"
    fi

    # AC3: file-level is the hard gate; region proximity is advisory. If the claim's
    # files do not include the thread's own path, still resolve but surface the
    # mismatch so it is visible without producing a false block.
    local thread_path
    thread_path=$(printf '%s' "$node_json" | jq -r '.data.node.path // ""' 2>/dev/null || echo "")
    if [ -n "$thread_path" ]; then
      local path_in_claim
      path_in_claim=$(printf '%s' "$claim_json" | jq -r --arg p "$thread_path" 'if (.files | index($p)) != null then "yes" else "no" end' 2>/dev/null || echo "no")
      if [ "$path_in_claim" != "yes" ]; then
        echo "::warning::thread ${id}: claimed files do not include the thread's path '${thread_path}' (claim: $(printf '%s' "$claim_files_json")) — resolving on the file-level gate, but the region mismatch is advisory (#1692 AC3)"
      fi
    fi

    # AC4: honour a standing maintainer disposition. Scan ALL comments (reusing the
    # comments_json captured above); if a marker-less human maintainer asserted a
    # required disposition, resolve only if the verified commit postdates it.
    # Unparseable disposition -> fail closed.
    local disposition disp_rc
    disposition=$(acv_latest_maintainer_disposition "$comments_json" "$bot_user") && disp_rc=0 || disp_rc=$?
    if [ "${disp_rc:-0}" -eq 2 ]; then
      echo "::notice::skipping thread ${id} — a maintainer disposition could not be parsed; leaving unresolved (fail closed) (#1692 AC4)"
      continue
    fi
    if [ "${disp_rc:-0}" -eq 0 ] && [ -n "$disposition" ]; then
      # Require the verified-commit date strictly after the disposition. Both are
      # Z-terminated UTC ISO-8601 instants of identical width (commit_date from
      # acv_gather_commit_facts, disposition from GitHub's createdAt), so a pure
      # Bash lexicographical compare orders them chronologically — no jq needed,
      # matching the same comparison acv_latest_maintainer_disposition uses.
      local newer="false"
      if [ -n "$commit_date" ] && [[ "$commit_date" > "$disposition" ]]; then
        newer="true"
      fi
      if [ "$newer" != "true" ]; then
        echo "::notice::skipping thread ${id} — a maintainer disposition (${disposition}) is not postdated by the verified fix (${commit_date:-unknown}); leaving unresolved (#1692 AC4)"
        continue
      fi
    fi

    if gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
        -f id="$id" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::resolved addressed bot thread ${id} (claim ${claim_sha} verified via ${verify_range} range)"
    else
      echo "::warning::failed to resolve addressed bot thread ${id}"
    fi
  done <<< "$ids"
  echo "::notice::resolve_addressed_bot_threads: resolved ${resolved_count} addressed bot thread(s) on PR #${PR_NUMBER}"
}

# resolve_dispositioned_comments: the issue-comment sibling of
# resolve_addressed_bot_threads (#1813). A PR *issue comment* (from `gh pr comment`
# or the GitHub main comment box) creates no review thread, so it is invisible to
# the thread-resolution path above. The maintainer-comment gate withholds
# pr-review's approval while ANY non-agent issue comment lacks a VERIFIED
# DISPOSITION, surfaced server-side as the comment being minimized RESOLVED. This
# net supplies that signal: for each undispositioned non-agent comment it locates
# dev-lead's single disposition reply, VERIFIES the disposition against ground
# truth (the pushed diff for `fixed`, the tracking issue for `out-of-scope`, a
# non-empty evidence reply for invalid/answered/informational), and — when
# cdv_authorize permits — minimizes the ORIGINAL comment RESOLVED (never the
# model; the harness alone resolves, #1813 AC4).
#
# Authorship (#1813 AC5): is_human is the server's own classification
# (author.__typename == "User"). A human maintainer's comment is auto-resolved
# ONLY on a verified `fixed` (an agent can never dismiss a person's finding by
# arguing it away); a bot's comment resolves on any verified disposition.
#
# Loop safety (#860 / AC7): candidate enumeration excludes our own account and any
# comment carrying an agent marker (which includes the `dev-lead:comment-disposition`
# reply itself), so our replies are never themselves treated as findings. The pass
# is idempotent — an already-minimized comment is filtered out — and every decision
# is delegated to the pure cdv_*/acv_* verifiers so it fails closed on any ambiguity.
resolve_dispositioned_comments() {
  local intent="$1"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would resolve dispositioned PR issue comments on PR #${PR_NUMBER}"
    return 0
  fi
  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::notice::resolve_dispositioned_comments: PR_NUMBER not set for intent=${intent} — skipping"
    return 0
  fi

  local bot_user="${BOT_USER:-donpetry-bot}"

  # Fetch ALL PR issue comments (author login + __typename, body, minimize state,
  # createdAt, and the node id used both to match a disposition reply's `id=` and
  # as minimizeComment's subjectId). The full set is needed twice: to find
  # candidates AND to locate their disposition replies (a flat comment list, not a
  # thread). Paginated 100/page.
  local pages_file cursor="" has_next_page="true" page_response page_nodes
  local cursor_args=()
  local comments_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        comments(first:100,after:$cursor){
          pageInfo{hasNextPage endCursor}
          nodes{ id author{login __typename} body isMinimized minimizedReason createdAt }
        }
      }
    }
  }'
  pages_file=$(mktemp) || { echo "::error::failed to create temporary file" >&2; exit 1; }
  while [ "$has_next_page" = "true" ]; do
    page_response=$(gh api graphql -f query="$comments_query" \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      "${cursor_args[@]}" 2>/dev/null)
    page_nodes=$(printf '%s' "$page_response" | jq -c \
      '.data?.repository?.pullRequest?.comments?.nodes // []' 2>/dev/null || echo "[]")
    printf '%s\n' "$page_nodes" >> "$pages_file"
    has_next_page=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.comments?.pageInfo?.hasNextPage // false' \
      2>/dev/null || echo "false")
    cursor=$(printf '%s' "$page_response" | jq -r \
      '.data?.repository?.pullRequest?.comments?.pageInfo?.endCursor // ""' \
      2>/dev/null || echo "")
    [ -z "$cursor" ] && has_next_page="false"
    cursor_args=("-f" "cursor=${cursor}")
  done
  local all_comments
  all_comments=$(jq -s 'add // []' "$pages_file" 2>/dev/null || echo "[]")
  rm -f "$pages_file"

  # Candidate ids: non-agent comments not already minimized RESOLVED. Same filter
  # as the gate (login != our account, body not agent-marked, not resolved-minimized)
  # so what the harness resolves is exactly what the gate blocks on.
  local candidate_ids
  candidate_ids=$(printf '%s' "$all_comments" | jq -r \
    --arg botuser "$bot_user" \
    --arg markers "$_MAINTAINER_GATE_AGENT_MARKERS" '
      def bot_stripped: ($botuser | if endswith("[bot]") then .[0:-5] else . end);
      .[] | objects
      | (.author?.login // "" | tostring) as $l
      | select($l != $botuser and $l != bot_stripped)
      | select(((.body // "") | test($markers)) | not)
      | select(
          ((.isMinimized // false) == true)
          and (((.minimizedReason // "") | ascii_downcase) == "resolved")
          | not
        )
      | .id
    ' 2>/dev/null || true)

  if [ -z "$(printf '%s' "$candidate_ids" | sed '/^[[:space:]]*$/d')" ]; then
    echo "::notice::no undispositioned PR issue comments on PR #${PR_NUMBER}"
    return 0
  fi

  local resolved_count=0
  local cid is_human cur_minimized reply_body disp_json disposition sha ref verified
  while IFS= read -r cid || [ -n "$cid" ]; do
    [ -z "$cid" ] && continue

    # Re-read the ORIGINAL comment's CURRENT minimize state so a comment minimized
    # since enumeration is not double-processed; a fetch that can't confirm state
    # fails closed (skip).
    cur_minimized=$(gh api graphql -f query='query($id:ID!){node(id:$id){... on IssueComment{isMinimized minimizedReason}}}' \
      -f id="$cid" 2>/dev/null \
      | jq -r 'if .data.node.isMinimized == null then "unknown"
               elif .data.node.isMinimized then "true" else "false" end' 2>/dev/null || echo "unknown")
    if [ "$cur_minimized" != "false" ]; then
      echo "::notice::skipping comment ${cid} — already minimized or state unknown at re-check (${cur_minimized})"
      continue
    fi

    is_human=$(printf '%s' "$all_comments" | jq -r --arg id "$cid" \
      'first(.[] | select(.id == $id)) | if (.author?.__typename // "") == "User" then "true" else "false" end' 2>/dev/null || echo "false")

    # Locate OUR disposition reply for this comment id: a comment AUTHORED BY OUR
    # BOT ACCOUNT (BOT_USER, or its GraphQL-stripped login) whose parseable
    # disposition marker cites id=<cid>. Restricting to our account is an
    # authorization gate (CWE-863): without it, an EXTERNAL commenter could post a
    # marker citing a candidate id plus a real PR SHA and trick the harness into
    # minimizing the original comment as RESOLVED. cdv_parse_disposition rejects
    # malformed/ambiguous markers, so an unverifiable reply never matches. Require
    # EXACTLY ONE authorized disposition (AC7) — zero or many fail closed. Bodies
    # are base64-framed to survive newlines.
    reply_body=""
    local c_body_b64 c_body parsed pid auth_count=0
    while IFS= read -r c_body_b64 || [ -n "$c_body_b64" ]; do
      [ -z "$c_body_b64" ] && continue
      c_body=$(printf '%s' "$c_body_b64" | base64 -d 2>/dev/null || true)
      parsed=$(cdv_parse_disposition "$c_body" 2>/dev/null) || continue
      pid=$(printf '%s' "$parsed" | jq -r '.id // ""' 2>/dev/null || echo "")
      [ "$pid" = "$cid" ] || continue
      auth_count=$((auth_count + 1))
      reply_body="$c_body"
      disp_json="$parsed"
    done < <(printf '%s' "$all_comments" | jq -r \
      --arg botuser "$bot_user" '
        def bot_stripped: ($botuser | if endswith("[bot]") then .[0:-5] else . end);
        .[] | objects
        | (.author?.login // "" | tostring) as $l
        | select($l == $botuser or $l == bot_stripped)
        | (.body // "") | @base64' 2>/dev/null)

    if [ -z "$reply_body" ]; then
      echo "::notice::skipping comment ${cid} — no authorized dev-lead disposition reply from ${bot_user} found; leaving open (#1813)"
      continue
    fi
    if [ "$auth_count" -ne 1 ]; then
      echo "::notice::skipping comment ${cid} — expected exactly one authorized disposition reply, found ${auth_count}; leaving open (#1813)"
      continue
    fi

    disposition=$(printf '%s' "$disp_json" | jq -r '.disposition // ""' 2>/dev/null || echo "")
    sha=$(printf '%s' "$disp_json" | jq -r '.sha // ""' 2>/dev/null || echo "")
    ref=$(printf '%s' "$disp_json" | jq -r '.ref // ""' 2>/dev/null || echo "")

    # Verify the disposition against ground truth. Fail closed: unknown → false.
    verified="false"
    case "$disposition" in
      fixed)
        # Bind the `fixed` evidence to THIS pass's commit — not merely any ancestor
        # already on the PR head. Without this, a prior pass's commit (or any
        # existing ancestor) satisfies the on-head + non-empty-diff check even when
        # the current pass produced no fix. Require: this pass advanced the head
        # (RESOLUTION_BASE_SHA → current HEAD via ri_may_resolve), the cited sha was
        # produced by this pass (reachable from HEAD but NOT from the pre-pass base),
        # and its diff is non-empty. Fail closed when the pre-pass base or HEAD is
        # unknowable, or the sha predates this pass.
        local facts on_head own_files cumulative_files pass_base pass_head
        pass_base="${RESOLUTION_BASE_SHA:-}"
        pass_head="$(git rev-parse HEAD 2>/dev/null || true)"
        if ri_may_resolve "$pass_base" "$pass_head" \
             && git merge-base --is-ancestor "$sha" "$pass_head" 2>/dev/null \
             && ! git merge-base --is-ancestor "$sha" "$pass_base" 2>/dev/null; then
          facts=$(acv_gather_commit_facts "$sha")
          on_head=$(printf '%s' "$facts" | jq -r '.on_head // false' 2>/dev/null || echo "false")
          own_files=$(printf '%s' "$facts" | jq -r '(.own_files // []) | length' 2>/dev/null || echo "0")
          cumulative_files=$(printf '%s' "$facts" | jq -r '(.cumulative_files // []) | length' 2>/dev/null || echo "0")
          if [ "$on_head" = "true" ] && { [ "${own_files:-0}" -gt 0 ] || [ "${cumulative_files:-0}" -gt 0 ]; }; then
            verified="true"
          fi
        else
          echo "::notice::skipping comment ${cid} — cited sha ${sha} was not produced by this pass (base=${pass_base:-<unset>} head=${pass_head:-<unset>}); leaving open (#1813)"
        fi
        ;;
      out-of-scope)
        # The referenced tracking issue must exist.
        local ref_num="${ref#\#}"
        if [ -n "$ref_num" ] && gh issue view "$ref_num" --repo "$REPO" --json number >/dev/null 2>&1; then
          verified="true"
        fi
        ;;
      invalid|answered|informational)
        # The disposition reply must carry non-empty evidence beyond the marker itself.
        local evidence
        evidence=$(printf '%s' "$reply_body" | jq -Rsr 'gsub("<!--.*?-->";"";"s") | gsub("\\s";"";"g")' 2>/dev/null || echo "")
        [ -n "$evidence" ] && verified="true"
        ;;
      *)
        verified="false"
        ;;
    esac

    if ! cdv_authorize "$disposition" "$is_human" "$verified"; then
      echo "::notice::skipping comment ${cid} — disposition '${disposition}' not authorized to resolve (is_human=${is_human} verified=${verified}); leaving open (#1813)"
      continue
    fi

    if gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:RESOLVED}){minimizedComment{isMinimized}}}' \
        -f id="$cid" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
      echo "::notice::minimized comment ${cid} RESOLVED (disposition=${disposition} is_human=${is_human})"
    else
      echo "::warning::failed to minimize comment ${cid} RESOLVED"
    fi
  done <<< "$candidate_ids"
  echo "::notice::resolve_dispositioned_comments: minimized ${resolved_count} dispositioned comment(s) on PR #${PR_NUMBER}"
}

# ── CI blocking gate (#1859, completes #1795) ─────────────────────────────────
# has_hard_blockers / has_tier1_blockers determine whether CI is blocking via
# lib/ci-status.sh (compute_ci_status), NOT their own all-or-nothing logic. A
# failing NON-required check (e.g. `template-drift`, or a superseded/cancelled
# `dev-lead / *` orchestration job — all non-required) no longer blocks; a failing
# REQUIRED check and a genuine CHANGES_REQUESTED review still do. Fails closed: if
# the branch ruleset is unreadable, compute_ci_status gates on every failing check.

# _ci_required_checks: the branch ruleset's required status-check contexts, read
# once per run via ruleset_required_checks (lib/ci-status.sh) and cached. Names are
# NEVER hardcoded here — they are the authoritative required set for this branch.
# Empty when the ruleset API is unreadable → compute_ci_status fails closed.
_ci_required_checks() {
  if [ -z "${_CI_REQUIRED_CHECKS_CACHE+x}" ]; then
    _CI_REQUIRED_CHECKS_CACHE="$(ruleset_required_checks "${REPO:-}" "${BASE_REF:-main}" 2>/dev/null || true)"
  fi
  printf '%s' "$_CI_REQUIRED_CHECKS_CACHE"
}

# _ci_rollup_from_status_json: reshape CI_STATUS_JSON (built by fetch_pr_context
# from the check-runs + legacy-statuses APIs, lowercase conclusions) into the
# statusCheckRollup shape compute_ci_status consumes — uppercase status/conclusion,
# with the synthetic "pending" conclusion (fetch_pr_context maps a pending legacy
# status to it) normalised back to a null (non-terminal) conclusion so it
# classifies as pending, not failing.
_ci_rollup_from_status_json() {
  printf '%s' "${CI_STATUS_JSON:-[]}" | jq -c '
    (if type == "array" then . else [] end)
    | map({
        name: (.name // ""),
        status: ((.status // "") | ascii_upcase),
        conclusion: (if (.conclusion == null or .conclusion == "" or .conclusion == "pending")
                     then null else (.conclusion | ascii_upcase) end)
      })' 2>/dev/null || echo '[]'
}

# ci_blocking_status: the compute_ci_status verdict ("passing"/"pending"/"failing")
# for this PR, gated on required checks only.
ci_blocking_status() {
  compute_ci_status "$(_ci_rollup_from_status_json)" "$(_ci_required_checks)"
}

# ci_is_blocking: returns 0 (true) when CI is a hard blocker — a REQUIRED check is
# failing or still pending. A red NON-required check yields "passing" and is not a
# blocker (the #1795/#1859 deadlock).
ci_is_blocking() {
  local st
  st="$(ci_blocking_status)"
  [ "$st" = "failing" ] || [ "$st" = "pending" ]
}

# ci_blocking_reason: a human phrase naming the specific check(s) that make CI a
# blocker and whether they are required — AC #5. Mirrors compute_ci_status's gate
# so the two never drift: it reports the checks in the SAME gate set (the required
# subset when the ruleset named any, otherwise every external check — fail closed)
# that are pending or failing. Empty when CI is not blocking. Examples:
#   "required check `Lint` is failing"
#   "required checks `Lint`, `Build` are still pending"
#   "check `template-drift` is failing (required set unreadable — failing closed)"
ci_blocking_reason() {
  local agent_roles required_names is_unreadable="false"
  agent_roles="$(_ci_status_agent_roles_json)"
  # Normalise the required set to a JSON array. An empty/unreadable ruleset must
  # become [] (not the empty string), or --argjson would reject it and the whole
  # filter would silently fail — dropping us onto the generic fallback (#1859 AC5).
  # Distinguish an UNREADABLE ruleset (empty string from _ci_required_checks →
  # fail closed) from a readable-but-EMPTY one ("[]" → no required checks
  # configured): only the former warrants the "failing closed" note, or it
  # misleadingly claims the ruleset was unreadable when it was merely empty.
  required_names="$(_ci_required_checks)"
  if [ -z "$required_names" ]; then
    is_unreadable="true"
    required_names="[]"
  elif [ "$required_names" = "[]" ]; then
    required_names="[]"
  else
    required_names="$(jq -c 'if type == "array" then . else [] end' <<< "$required_names" 2>/dev/null || echo '[]')"
  fi
  _ci_rollup_from_status_json | jq -r \
    --argjson agent_roles "$agent_roles" \
    --argjson required_names "$required_names" \
    --arg unreadable "$is_unreadable" "
    def is_terminal: (.conclusion != null and .conclusion != \"\");
    def is_pending:
      (is_terminal | not) and (
        .status == \"IN_PROGRESS\" or .status == \"QUEUED\" or .status == \"WAITING\" or
        .status == \"COMPLETED\"  or .state == \"PENDING\" or .state == \"EXPECTED\"
      );
    def is_success:
      .conclusion == \"SUCCESS\" or .conclusion == \"SKIPPED\" or .conclusion == \"NEUTRAL\" or
      .state == \"SUCCESS\";
    def is_cancelled: .conclusion == \"CANCELLED\";
    def is_required:
      (.isRequired == true) or
      (((.name // .context // \"\") as \$n | (\$required_names | index(\$n)) != null));
    def chk_word(\$n): if \$n == 1 then \"check\" else \"checks\" end;
    def names(\$a): (\$a | map(\"\`\" + . + \"\`\") | join(\", \"));
    $_CI_STATUS_JQ_IS_OWN_CHECK
    $_CI_STATUS_JQ_IS_AGENT_CHECK
    if (. == null or (type != \"array\")) then \"\"
    else
      (map(select((is_own_check or is_agent_check) | not))) as \$ext |
      (\$ext | map(select(is_required))) as \$req |
      (\$req | length > 0) as \$gate_required |
      (if \$gate_required then \$req else \$ext end) as \$gate |
      (if \$gate_required then \"required \" else \"\" end) as \$qual |
      (if \$gate_required then \"\" elif \$unreadable == \"true\" then \" (required set unreadable — failing closed)\" else \"\" end) as \$closed |
      (\$gate | map(select((is_success or is_cancelled) | not))) as \$bad |
      (\$bad | map(select(is_pending))  | map(.name // .context // \"\") | map(select(length > 0))) as \$pending |
      (\$bad | map(select(is_pending | not)) | map(.name // .context // \"\") | map(select(length > 0))) as \$failing |
      ([ (if (\$failing | length) > 0
            then \$qual + chk_word(\$failing|length) + \" \" + names(\$failing) + \" \" + (if (\$failing|length)==1 then \"is\" else \"are\" end) + \" failing\" + \$closed
            else empty end),
         (if (\$pending | length) > 0
            then \$qual + chk_word(\$pending|length) + \" \" + names(\$pending) + \" \" + (if (\$pending|length)==1 then \"is\" else \"are\" end) + \" still pending\" + \$closed
            else empty end)
       ] | join(\"; \"))
    end
  " 2>/dev/null || true
}

# blocking_reason_phrase: the full "why this PR still can't be marked done" phrase
# for retry/hold messages — the named CI blocker(s) from ci_blocking_reason plus a
# changes-requested-review clause when applicable (AC #5). Falls back to a generic
# phrase only if nothing specific could be derived.
blocking_reason_phrase() {
  local reasons=() ci_reason changes_requested
  ci_reason="$(ci_blocking_reason)"
  [ -n "$ci_reason" ] && reasons+=("$ci_reason")
  changes_requested=$(printf '%s' "${ALL_REVIEWS_JSON:-[]}" | \
    jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' 2>/dev/null || echo "0")
  [ "${changes_requested:-0}" -gt 0 ] && reasons+=("a reviewer requested changes")
  if [ "${#reasons[@]}" -eq 0 ]; then
    printf 'a required check is failing or pending, or a reviewer requested changes'
  else
    local out="" r
    for r in "${reasons[@]}"; do
      if [ -z "$out" ]; then out="$r"; else out="${out}; ${r}"; fi
    done
    printf '%s' "$out"
  fi
}

# has_hard_blockers: returns 0 (true) if CI is blocking (per ci-status.sh) or
# ALL_REVIEWS_JSON contains a CHANGES_REQUESTED review.
# Unlike has_tier1_blockers, does NOT check for unresolved bot threads — used to
# distinguish "bot threads are the sole blocker" from "hard blockers present", so
# callers can post a retry marker instead of silently stalling on bot feedback.
has_hard_blockers() {
  local changes_requested

  changes_requested=$(printf '%s' "${ALL_REVIEWS_JSON:-[]}" | \
    jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' \
    2>/dev/null || echo "0")

  ci_is_blocking || [ "${changes_requested:-0}" -gt 0 ]
}

# has_tier1_blockers: returns 0 (true) if CI is blocking (per ci-status.sh),
# ALL_REVIEWS_JSON, or unresolved bot reviewer threads contain Tier-1 blockers:
# - A REQUIRED CI check failing or pending (via compute_ci_status; a red
#   NON-required check does not block — #1859)
# - Any reviewer with state = CHANGES_REQUESTED
# - Unresolved review threads from bot reviewers (prevents review-changes from ignoring bot feedback)
# Used to gate post_no_changes — never post a terminal no-changes marker while blockers
# exist, so the retry cron can re-attempt on the same SHA.
has_tier1_blockers() {
  local changes_requested unresolved_bot_threads

  changes_requested=$(printf '%s' "${ALL_REVIEWS_JSON:-[]}" | \
    jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' \
    2>/dev/null || echo "0")

  # Count unresolved bot reviewer threads with cursor pagination to cover PRs with >100 threads.
  # Detects bots via __typename == "Bot" (covers bots whose GraphQL login omits [bot] suffix)
  # or login ending with [bot] (belt-and-suspenders for bots that include the suffix).
  unresolved_bot_threads=0
  if [ -n "${PR_NUMBER:-}" ]; then
    local cursor="" has_next_page="true" page_response page_count
    local cursor_args=()
    local bot_thread_query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100,after:$cursor){
            pageInfo{hasNextPage endCursor}
            nodes{isResolved comments(first:1){nodes{author{login __typename}}}}
          }
        }
      }
    }'
    while [ "$has_next_page" = "true" ]; do
      page_response=$(gh api graphql -f query="$bot_thread_query" \
        -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
        "${cursor_args[@]}" 2>/dev/null) || {
        echo "::warning::has_tier1_blockers: bot-thread query failed — treating as blocked"
        return 0
      }
      page_count=$(printf '%s' "$page_response" | jq \
        '[.data?.repository?.pullRequest?.reviewThreads?.nodes // []
        | map(select(.isResolved == false
                     and (((.comments.nodes?[0]?.author?.login // "") | endswith("[bot]"))
                          or ((.comments.nodes?[0]?.author?.__typename // "") == "Bot"))))
        | length] | .[0]' 2>/dev/null || echo "0")
      unresolved_bot_threads=$(( ${unresolved_bot_threads:-0} + ${page_count:-0} ))
      has_next_page=$(printf '%s' "$page_response" | jq -r \
        '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.hasNextPage // false' \
        2>/dev/null || echo "false")
      cursor=$(printf '%s' "$page_response" | jq -r \
        '.data?.repository?.pullRequest?.reviewThreads?.pageInfo?.endCursor // ""' \
        2>/dev/null || echo "")
      [ -z "$cursor" ] && has_next_page="false"
      cursor_args=("-f" "cursor=${cursor}")
    done
  fi

  ci_is_blocking || [ "${changes_requested:-0}" -gt 0 ] || [ "${unresolved_bot_threads:-0}" -gt 0 ]
}

# try_enable_auto_merge: enables auto-merge (squash) on the PR when the engine run
# succeeds (rc==0). We do NOT gate on reviewDecision here: GitHub holds the merge
# until branch protection is satisfied (required reviews approved, review threads
# resolved, required checks green), so enabling early is safe and means a PR merges
# the moment it becomes mergeable. If the engine run fails the call is skipped, so a
# new dev-lead event is required in that case.
# Safe to call speculatively: it is idempotent when auto-merge is already on.
# Pass "true" as first arg for strict mode: API errors propagate and a merge failure
# exits non-zero rather than emitting a warning (use for the enable-auto-merge intent).
try_enable_auto_merge() {
  local strict="${1:-false}"
  if [[ "${DEV_LEAD_DRY_RUN:-false}" == "true" ]]; then
    echo "[dry-run] would enable auto-merge (${_AM_MERGE_METHOD:-squash}) on PR #${PR_NUMBER}"
    return 0
  fi
  # Refresh HEAD_SHA to the commit that is now the PR head. commit_and_push may
  # have created a new commit after HEAD_SHA was resolved at script startup, so
  # --match-head-commit would fail with the stale value.
  local current_head
  current_head=$(git rev-parse HEAD 2>/dev/null || true)
  [[ -n "$current_head" ]] && HEAD_SHA="$current_head"

  local auto_merge_state
  if [[ "$strict" == "true" ]]; then
    auto_merge_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.auto_merge // empty')
  else
    auto_merge_state=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" \
      --jq '.auto_merge // empty' 2>/dev/null || true)
  fi
  if [[ -n "$auto_merge_state" ]]; then
    echo "::notice::PR #${PR_NUMBER} auto-merge already enabled"
    return 0
  fi

  local method="${_AM_MERGE_METHOD:-squash}"
  local merge_flag
  case "$method" in
    merge)  merge_flag="--merge" ;;
    rebase) merge_flag="--rebase" ;;
    *)      merge_flag="--squash" ;;
  esac
  echo "::notice::PR #${PR_NUMBER} — enabling auto-merge (${method}); GitHub will merge once branch protection is satisfied"
  local merge_args=("--auto" "$merge_flag")
  [[ -n "${_AM_COMMIT_TITLE:-}" ]] && merge_args+=("--subject" "${_AM_COMMIT_TITLE}")
  [[ -n "${_AM_COMMIT_MESSAGE:-}" ]] && merge_args+=("--body" "${_AM_COMMIT_MESSAGE}")
  [[ -n "${HEAD_SHA:-}" ]] && merge_args+=("--match-head-commit" "$HEAD_SHA")
  if [[ "$strict" == "true" ]]; then
    gh pr merge "$PR_NUMBER" --repo "$REPO" "${merge_args[@]}"
  else
    gh pr merge "$PR_NUMBER" --repo "$REPO" "${merge_args[@]}" 2>/dev/null || \
      echo "::warning::auto-merge could not be enabled on PR #${PR_NUMBER} — check repository settings and token permissions"
  fi
}

# detect_conflicting_paths <base_ref> — list paths that conflict when merging
# origin/<base_ref> into the current HEAD, one per line. Uses a trial merge
# (immediately aborted) because it is robust across git versions: the former
# `git merge-tree <base> HEAD <base>` 3-arg form prints a "changed in both"
# section header whose last field is the literal word "both" (the filename is on
# the indented our/their lines), so `awk '{print $NF}'` produced a bogus "both"
# path that was fed to the rebase prompt. Leaves the worktree clean.
detect_conflicting_paths() {
  local base="$1"
  [[ -z "$base" ]] && return 0
  git merge --no-commit --no-ff "origin/${base}" >/dev/null 2>&1 || true
  git diff --name-only --diff-filter=U || true
  git merge --abort >/dev/null 2>&1 || true
}

# ── rebase exhaustion / large-conflict guard (#865) ───────────────────────────
# A hard/unresolvable rebase conflict used to run the engine to the per-tier
# timeout (exit 124) instead of aborting, and the auto-rebase-conflict sentinel
# could re-fire repeatedly — a burst of full-timeout runs. These wrappers pair
# the gh-api reads/writes with the pure decision helpers in
# lib/rebase-exhaustion.sh to abort cleanly and cap repeated attempts, mirroring
# the fix-ci per-PR exhaustion marker.
REBASE_MAX_FAIL_ATTEMPTS="${REBASE_MAX_FAIL_ATTEMPTS:-2}"
REBASE_MAX_CONFLICT_FILES="${REBASE_MAX_CONFLICT_FILES:-40}"

# _rebase_comment_bodies: newline-delimited bodies of all PR comments (paginated
# so markers on busy PRs are not missed).
_rebase_comment_bodies() {
  local output
  output=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null) || return 1
  printf '%s\n' "$output" | jq -r '.[].body' 2>/dev/null || return 1
}

# rebase_pr_is_exhausted: exit status distinguishes three states so the caller
# can fail closed on a retrieval fault instead of treating it as "not exhausted":
#   0 → exhaustion marker present (skip the engine)
#   1 → comments retrieved, no marker (safe to proceed)
#   2 → comment retrieval failed (unknown — caller must not invoke the engine)
rebase_pr_is_exhausted() {
  local marker bodies
  marker="$(rebase_exhaustion_marker "$REVIEWS_MARKER_PREFIX" "$PR_NUMBER")"
  if ! bodies="$(_rebase_comment_bodies)"; then
    return 2
  fi
  rebase_is_exhausted "$marker" "$bodies"
}

# post_rebase_exhaustion <reason>: posts the PR-level block so a stuck conflict
# cannot generate repeated timing-out runs from sentinel re-fires.
post_rebase_exhaustion() {
  local reason="$1" marker body
  marker="$(rebase_exhaustion_marker "$REVIEWS_MARKER_PREFIX" "$PR_NUMBER")"
  body="${marker}
## Dev-Lead — rebase (exhausted)

This PR's rebase conflict failed automated resolution **${REBASE_MAX_FAIL_ATTEMPTS}** time(s) (timeouts or unresolvable conflicts). Automated rebasing is paused to stop repeated full-timeout runs from the auto-rebase-conflict sentinel.

**Reason for last failure:** ${reason}

Resolve the conflict manually, then delete this comment to re-enable automated rebasing."
  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post rebase exhaustion marker"
    return 0
  fi
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body" 2>/dev/null || true
}

# handle_rebase_failure <reason>: converts a rebase engine failure — a per-tier
# timeout (exit 124, the #865 defect) or a hard engine error — into a clean
# terminal abort. It leaves the worktree clean, records a terminal
# `status=failed` marker (so the retry cron stops re-dispatching this SHA), then
# posts the PR-level exhaustion marker once failures reach the threshold.
handle_rebase_failure() {
  local reason="$1" fail_count bodies
  # Leave the worktree clean so a lingering half-applied merge can't poison a
  # later attempt.
  git merge --abort >/dev/null 2>&1 || true
  git rebase --abort >/dev/null 2>&1 || true
  post_reviews_terminal "rebase" "failed" "$reason"
  # Capture bodies and retrieval status separately: a failed retrieval must not be
  # passed to rebase_count_failures as valid empty data (it would count 0 and
  # suppress the exhaustion marker even when the threshold was reached). On a
  # retrieval fault, fail closed by posting the PR-level block — a stuck conflict
  # must not keep generating full-timeout sentinel re-fires just because we could
  # not read the comment history this run.
  if bodies="$(_rebase_comment_bodies)"; then
    fail_count="$(rebase_count_failures "$REVIEWS_MARKER_PREFIX" "$PR_NUMBER" "$bodies")"
    echo "  [rebase] recorded failures on this PR: ${fail_count} (threshold: ${REBASE_MAX_FAIL_ATTEMPTS})"
    if rebase_should_exhaust "${fail_count:-0}" "$REBASE_MAX_FAIL_ATTEMPTS"; then
      echo "::warning::rebase exhaustion threshold reached — posting PR-level block to stop sentinel re-fires (#865)"
      post_rebase_exhaustion "$reason"
    fi
  else
    echo "::warning::could not retrieve PR comments to count rebase failures — failing closed and posting PR-level block to stop sentinel re-fires (#865)"
    post_rebase_exhaustion "$reason"
  fi
}

# expire_stale_terminal_markers: deletes any existing terminal comments (applied,
# no-changes, or failed) for this SHA+intent before a hard-blocker retry marker is
# posted. Without this, the retry cron sees a stale terminal and skips re-dispatch
# even though a new hard blocker (e.g. a CHANGES_REQUESTED review added after the
# prior run) now requires retry.
expire_stale_terminal_markers() {
  local intent="$1"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would expire stale terminal markers for intent=${intent} sha=${sha}"
    return 0
  fi
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=(applied|no-changes|failed)"
  local stale_ids
  stale_ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -r --arg pat "$pattern" '[.[] | select(.body | test($pat))] | .[].id' 2>/dev/null || true)
  for comment_id in $stale_ids; do
    echo "::notice::expire_stale_terminal_markers: deleting stale terminal comment ${comment_id} for intent=${intent} SHA=${sha}"
    gh api -X DELETE "repos/${REPO}/issues/comments/${comment_id}" 2>/dev/null || \
      echo "::warning::expire_stale_terminal_markers: failed to delete comment ${comment_id}" >&2
  done
}

# expire_stale_rate_limited_marker: deletes any existing hold marker
# (status=rate-limited OR status=blocked, #1568) for this SHA+intent before a new
# one is posted. Without this, when a hard blocker persists past the initial backoff
# window the dedup check in post_reviews_rate_limited skips posting, leaving a marker
# whose reset_time is already in the past. The retry cron then dispatches on every
# scan indefinitely instead of extending the backoff. Both tokens are matched so a
# reason switch (or a pre-#1568 marker) is still cleaned up.
expire_stale_rate_limited_marker() {
  local intent="$1"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would expire stale rate-limited marker for intent=${intent} sha=${sha}"
    return 0
  fi
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=(rate-limited|blocked)"
  local stale_ids
  stale_ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -r --arg pat "$pattern" '[.[] | select(.body | test($pat))] | .[].id' 2>/dev/null || true)
  for comment_id in $stale_ids; do
    echo "::notice::expire_stale_rate_limited_marker: deleting stale rate-limited comment ${comment_id} for intent=${intent} SHA=${sha}"
    gh api -X DELETE "repos/${REPO}/issues/comments/${comment_id}" 2>/dev/null || \
      echo "::warning::expire_stale_rate_limited_marker: failed to delete comment ${comment_id}" >&2
  done
}

# has_reviews_rate_limited_marker: returns 0 if a hold marker with the same reason
# (status=rate-limited for rate-limit reason, status=blocked for blocked reason, #1568)
# for this intent+SHA already exists on the PR (dedup check — suppresses repeat
# visible acks for the SAME hold reason, not across reason changes).
has_reviews_rate_limited_marker() {
  local intent="$1"
  local reason="${2:-rate-limit}"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 1  # no SHA means no dedup possible
  local status_token="rate-limited"
  [ "$reason" = "blocked" ] && status_token="blocked"
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=${status_token}"
  local count
  count=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -c --arg pat "$pattern" '[.[] | select(.body | test($pat))] | length' 2>/dev/null \
    || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# post_reviews_rate_limited: posts a rate-limited marker for fix-reviews intents.
# For retryable intents (fix-reviews, review-changes, rebase), the cron will re-dispatch.
# For non-retryable intents (on-mention, fix-bot-comment), asks the user to re-trigger
# since USER_INSTRUCTION/COMMENT_BODY cannot be reconstructed at retry time.
#
# $2 (reason) selects both the machine-readable status token and the user-facing
# wording:
#   rate-limit (default) — all AI engines genuinely rate-limited (engine exit 2);
#                          emits `status=rate-limited`
#   blocked              — engine ran fine but the PR still has hard blockers
#                          (failing/cancelled checks or CHANGES_REQUESTED reviews);
#                          emits `status=blocked` and schedules a 30-minute backoff
#                          retry (issues #461, #1568)
# The status token is now honest per reason (#1568): a non-quota hold is
# `status=blocked`, not `status=rate-limited`, so quota signal is never polluted by
# a hold that has nothing to do with provider quota. dev-lead-retry.sh recognizes
# both tokens (`status=(rate-limited|blocked)`) so re-dispatch behaviour is
# unchanged and pre-#1568 `status=rate-limited` blocked markers still in the wild
# remain retriable.
post_reviews_rate_limited() {
  local intent="$1"
  local reason="${2:-rate-limit}"

  # The blocked path owns its backoff: a fixed 30-minute reset so the retry cron
  # backs off instead of re-dispatching immediately. The rate-limit path's reset
  # is parsed from engine output (parse_reset_time) before this function is called.
  if [ "$reason" = "blocked" ]; then
    printf '%s' "$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" > /tmp/dev-lead-rate-limit-reset
  fi

  # Expire any stale terminal markers (applied/no-changes/failed) for this SHA+intent
  # so the retry cron is not masked by a prior terminal that predates the current blocker.
  # Without this, a no-changes terminal from before a reviewer's CHANGES_REQUESTED would
  # cause the cron to skip dispatch even though a new rate-limited marker was just posted.
  expire_stale_terminal_markers "$intent"

  # Detect whether a prior marker with the same reason exists BEFORE posting the new one.
  # Used to suppress duplicate visible ack comments when a persistent blocker keeps
  # triggering retries — the user-facing ack is only shown on the first cycle.
  # Only suppress if the reason is the same (issue #1568 logic error: suppress on
  # reason change would hide the shift from blocked→rate-limited or vice versa).
  local had_prior_rl_marker=false
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "false" ]; then
    has_reviews_rate_limited_marker "$intent" "$reason" && had_prior_rl_marker=true
  fi

  # Collect IDs of existing rate-limited markers BEFORE posting the new one. The new
  # marker is posted first so the old one remains as a safety net if the post fails
  # transiently; old markers are only removed after the replacement is confirmed posted.
  local stale_rl_ids=""
  if [ -n "${HEAD_SHA:-}" ]; then
    if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
      echo "[dry-run] would expire stale rate-limited marker for intent=${intent} sha=${HEAD_SHA}"
    else
      local rl_pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${HEAD_SHA} intent=${intent} status=(rate-limited|blocked)"
      stale_rl_ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
        | jq -r --arg pat "$rl_pattern" '[.[] | select(.body | test($pat))] | .[].id' 2>/dev/null || true)
    fi
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

  # The status token is honest per reason (#1568): a non-quota hold is
  # `status=blocked`; a genuine quota hold is `status=rate-limited`. `reason=` stays
  # for visible-text selection + marker forensics. The retry cron and marker dedup
  # patterns match `status=(rate-limited|blocked)`, so both tokens re-dispatch.
  local status_token="rate-limited"
  [ "$reason" = "blocked" ] && status_token="blocked"
  local marker="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}${sha_detail} intent=${intent} status=${status_token} reason=${reason}${reset_detail} -->"

  # Retry message depends on the reason and on whether the intent can be
  # re-dispatched automatically.
  local heading retry_msg
  if [ "$reason" = "blocked" ]; then
    heading="## Dev-Lead — waiting on PR blockers (intent: ${intent})"
    retry_msg="No changes were committed, but the PR still can't be marked done: $(blocking_reason_phrase). The retry cron will re-attempt automatically."
    if [ -n "$reset_time" ]; then
      retry_msg="${retry_msg} Next attempt after: \`${reset_time}\`"
    fi
  else
    heading="## Dev-Lead — rate-limited (intent: ${intent})"
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
  fi

  local marker_body="${marker}
${heading}
**PR:** #${PR_NUMBER}
${retry_msg}"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post rate-limited marker for intent=${intent} reason=${reason}"
    echo "$marker_body"
  else
    # Post the new marker FIRST, then remove old marker(s) only after the replacement
    # is confirmed. If the post fails transiently, the old marker remains as a safety net
    # so the retry cron does not lose track of this SHA+intent.
    if gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$marker_body"; then
      for _stale_id in $stale_rl_ids; do
        echo "::notice::post_reviews_rate_limited: deleting superseded rate-limited marker ${_stale_id} for intent=${intent}"
        gh api -X DELETE "repos/${REPO}/issues/comments/${_stale_id}" 2>/dev/null || \
          echo "::warning::post_reviews_rate_limited: failed to delete old rate-limited marker ${_stale_id}" >&2
      done
    fi
  fi

  # For user-triggered intents, post a separate visible acknowledgment on the first
  # rate-limit cycle only. Suppress repeat acks when a persistent blocker keeps the
  # backoff interval cycling — the old ack is still visible and a repeat is misleading.
  if [ "$had_prior_rl_marker" = "false" ]; then
    case "$intent" in
      review-changes)
        local actor_mention=""
        [ -n "${ACTOR:-}" ] && actor_mention="@${ACTOR} "
        local reset_display="${reset_time:-unknown}"
        local ack_body
        if [ "$reason" = "blocked" ]; then
          ack_body="<!-- dev-lead rate-limit-ack -->
> [!NOTE]
> ${actor_mention}I reviewed this PR and no code changes were needed, but I can't mark it done yet: $(blocking_reason_phrase). I'll re-check automatically.
> Next attempt after: \`${reset_display}\`"
        else
          ack_body="<!-- dev-lead rate-limit-ack -->
> [!NOTE]
> ${actor_mention}I received your request but all AI engines are currently rate-limited. I'll retry automatically once the rate limit clears.
> Rate limit resets at: \`${reset_display}\`"
        fi
        if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
          echo "[dry-run] would post user-visible ${reason} acknowledgment"
          echo "$ack_body"
        else
          gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$ack_body"
        fi
        ;;
      on-mention)
        local actor_mention=""
        [ -n "${ACTOR:-}" ] && actor_mention="@${ACTOR} "
        local reset_display="${reset_time:-unknown}"
        local ack_body="<!-- dev-lead rate-limit-ack -->
> [!NOTE]
> ${actor_mention}I received your request but all AI engines are currently rate-limited. Please re-mention \`@dev-lead\` when the rate limit clears (estimated: \`${reset_display}\`) — I cannot reconstruct the original instruction automatically."
        if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
          echo "[dry-run] would post user-visible rate-limit acknowledgment"
          echo "$ack_body"
        else
          gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$ack_body"
        fi
        ;;
    esac
  fi
}

handle_rate_limit() {
  local intent="$1"
  echo "::warning::All engines rate-limited for intent=${intent} — posting rate-limited marker"
  post_reviews_rate_limited "$intent"
  [[ -n "${PR_NUMBER:-}" ]] && try_enable_auto_merge
  exit 2
}

# Marker for the no-op guard flag comment (#1340), deduped per PR+intent.
NOOP_MARKER_PREFIX="<!-- dev-lead-noop-guard pr="

# pr_nets_to_zero [base] — returns 0 (true) when the PR branch's net diff against
# its base is empty: every change the PR's own commits introduced has been undone,
# so `origin/<base>...HEAD` shows zero changed files. Such a PR must never carry a
# pushed fix — merging a `Closes #N` PR that nets to zero would auto-close its
# compliance issue while the finding remains unfixed (#1340). When the base cannot
# be resolved (no ref, fetch fails, no common ancestor) it returns 1 and warns,
# so an unverifiable state never blocks a legitimate push.
pr_nets_to_zero() {
  local base="${1:-${BASE_REF:-main}}"
  local baseref="origin/${base}"
  # actions/checkout defaults to a depth-1 shallow clone, which lacks the common
  # ancestor "${baseref}...HEAD" needs. A plain `git fetch origin "$base"` does NOT
  # deepen a shallow checkout, so the merge-base stays absent, the diff below errors,
  # and the guard silently fails OPEN (returns 1 → "not net-zero" → push proceeds).
  # Deepen to full history first so the merge-base resolves; fall back to a bounded
  # fetch if --unshallow is unavailable.
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    git fetch --quiet --unshallow origin 2>/dev/null \
      || git fetch --quiet --depth=2147483647 origin "$base" 2>/dev/null \
      || true
  fi
  if ! git rev-parse --verify --quiet "${baseref}^{commit}" >/dev/null 2>&1; then
    git fetch --quiet origin "$base" 2>/dev/null || {
      echo "::warning::no-op guard: could not resolve ${baseref} — skipping net-zero check" >&2
      return 1
    }
  fi
  # A merge-base must exist before diffing; without it "${baseref}...HEAD" errors and
  # the guard would fail open. Treat a genuinely absent merge-base as unverifiable.
  if ! git merge-base "$baseref" HEAD >/dev/null 2>&1; then
    echo "::warning::no-op guard: no merge-base between ${baseref} and HEAD — skipping net-zero check" >&2
    return 1
  fi
  local changed
  changed=$(git diff --name-only "${baseref}...HEAD" 2>/dev/null) || {
    echo "::warning::no-op guard: git diff against ${baseref} failed — skipping net-zero check" >&2
    return 1
  }
  [ -z "$changed" ]
}

# flag_noop_pr <intent> — a fix pass reverted the PR's own changes, netting the
# base…head diff to zero (#1340). Post one deduped human-attention comment, add
# the needs-human-review label, and disable auto-merge — and suppress the
# EXIT-trap auto-merge restore so a self-cancelling PR is never silently made
# mergeable again. Mirrors pr_automation_escalate's escalation shape.
flag_noop_pr() {
  local intent="$1"
  # A self-cancelling PR must stay unmergeable until a human looks: prevent
  # restore_auto_merge (EXIT trap) from re-enabling what we are about to disable.
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] no-op guard: would flag PR #${PR_NUMBER} (${intent}) as net-zero, add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}, disable auto-merge"
    return 0
  fi
  local marker="${NOOP_MARKER_PREFIX}${PR_NUMBER} intent=${intent} -->"
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already flagged as net-zero for intent=${intent} — not reposting"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
## No-op fix detected — human attention needed

The \`${intent}\` pass reverted this PR's own changes, so its net diff against \`${BASE_REF:-main}\` is now **empty** (zero changed files). Merging a PR that nets to zero would auto-close its \`Closes #N\` compliance issue while the underlying finding remains unfixed (#1340), and the idempotent audit would immediately re-open it.

Auto-merge has been disabled and no commit was pushed. A human should restore the correct fix or close this PR." \
      || echo "::warning::could not post no-op flag comment on PR #${PR_NUMBER}"
  fi
  gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}" 2>/dev/null \
    || echo "::warning::could not add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review} label on PR #${PR_NUMBER}"
  gh pr merge "$PR_NUMBER" --repo "$REPO" --disable-auto 2>/dev/null \
    || echo "::notice::auto-merge was not enabled on PR #${PR_NUMBER} (nothing to disable)"
  return 0
}

# commit_and_push: adds all changes, commits with an intent-specific message,
# and pushes to the PR branch. Returns 0 if changes were made and pushed,
# 1 if no changes were found, 3 if the no-op guard aborted the push (#1340).
commit_and_push() {
  local intent="$1"
  local has_uncommitted=false has_unpushed=false

  # git status --porcelain covers untracked files that git diff misses
  [ -n "$(git status --porcelain 2>/dev/null)" ] && has_uncommitted=true

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
    human|human-pr)  commit_msg="chore: apply manual instructions [skip ci-relay]" ;;
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
      # Ensure git identity is set — actions/checkout only sets local config for the
      # repo it checks out (.github-private), not for target repos cloned separately.
      setup_git_identity
      # Explicit exit on failure: set -e is suspended when commit_and_push is called from
      # an if-statement condition, so git commit failures would be silently swallowed
      # otherwise. Using exit (not return) ensures CI fails visibly instead of posting a
      # false "Changes committed and pushed" comment.
      git commit -m "$commit_msg" || { echo "::error::git commit failed — check git identity configuration on the runner" >&2; exit 1; }
    fi
    # No-op guard (#1340, extended #1786): a fix/review/rebase pass that reverts
    # the PR's own changes nets the base…head diff to zero. Pushing it would let a
    # `Closes #N` PR auto-close its compliance issue while the finding remains
    # unfixed. Abort the push and flag for a human instead of self-cancelling.
    # #1786 broadens the covered intents from fix-reviews/fix-bot-comment to every
    # intent that pushes to a PR branch (review-changes, human, rebase, …).
    case "$intent" in
      enable-auto-merge) ;;  # never pushes; nothing to guard
      *)
        if pr_nets_to_zero "${BASE_REF:-main}"; then
          echo "::error::No-op guard: PR #${PR_NUMBER} nets to zero changed files against ${BASE_REF:-main} after ${intent} — refusing to push a self-cancelling fix (#1340/#1786)"
          flag_noop_pr "$intent"
          return 3
        fi
        ;;
    esac
    # No-clobber push (#1311): never discard a concurrent writer's unseen commit.
    # push_no_clobber fast-forwards normally and only ever force-with-leases a
    # rewritten branch, aborting if the remote moved beyond what we fetched.
    push_no_clobber || {
      echo "::error::git push failed — check remote access and branch permissions" >&2
      exit 1
    }
  fi
  return 0
}

# count_not_applied_markers <intent> — number of not-applied terminal markers
# currently on the PR for this intent. They are cleared on the next `applied`,
# so the count is the run of consecutive non-converging passes (#1567 AC #4).
count_not_applied_markers() {
  local intent="$1"
  [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ] && { echo 0; return 0; }
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}.* intent=${intent} status=not-applied"
  # No error masking: a failing gh api (auth, rate-limit, network) must abort
  # loudly rather than silently return 0, which would suppress escalation.
  gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
    | jq -r --arg pat "$pattern" '[.[] | select((.body // "") | test($pat))] | length'
}

# clear_not_applied_markers <intent> — delete the not-applied markers once a pass
# genuinely applies the requested changes, so the convergence counter resets.
clear_not_applied_markers() {
  local intent="$1"
  [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ] && return 0
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}.* intent=${intent} status=not-applied"
  local ids id
  # No error masking: a failing gh api|jq must abort loudly rather than silently
  # skip the clear, which would leave a stale non-convergence count behind.
  ids=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
    | jq -r --arg pat "$pattern" '[.[] | select((.body // "") | test($pat))] | .[].id')
  # Split safely into an array (IFS scoped to read) so no glob metacharacter in
  # the id list undergoes pathname expansion.
  local -a ids_arr=()
  if [ -n "$ids" ]; then
    IFS=$'\n' read -r -d '' -a ids_arr <<< "$ids" || true
  fi
  for id in "${ids_arr[@]}"; do
    gh api -X DELETE "repos/${REPO}/issues/comments/${id}"
  done
}

# escalate_review_nonconvergence <intent> <count> — the fix pass has committed
# <count> times without applying the requested review changes. Add the
# needs-human label, post one deduped attention comment, disable auto-merge, and
# set _REVIEW_ESCALATED so the caller does not re-enable it (#1567 AC #4).
escalate_review_nonconvergence() {
  local intent="$1" count="$2"
  _REVIEW_ESCALATED=1
  # Keep the EXIT-trap restore from re-enabling auto-merge we are about to disable.
  _AM_NEEDS_RESTORE=0
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] review non-convergence: would escalate PR #${PR_NUMBER} (${intent}) after ${count} not-applied passes"
    return 0
  fi
  local marker="${NONCONVERGE_MARKER_PREFIX}${PR_NUMBER} intent=${intent} -->"
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already escalated for review non-convergence (${intent})"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
## Review changes not converging — human attention needed

The \`${intent}\` pass has now committed **${count}** times against this review without applying the requested changes: each pass changed something, but none touched the regions the review named. Automatic retries are unlikely to converge, so this needs a human.

Auto-merge has been disabled and no further automatic passes will run until a human intervenes. A human should apply the requested changes, or clarify the review." \
      || echo "::warning::could not post review non-convergence comment on PR #${PR_NUMBER}"
  fi
  gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}" 2>/dev/null \
    || echo "::warning::could not add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review} label on PR #${PR_NUMBER}"
  gh pr merge "$PR_NUMBER" --repo "$REPO" --disable-auto 2>/dev/null \
    || echo "::notice::auto-merge was not enabled on PR #${PR_NUMBER} (nothing to disable)"
}

# finalize_review_application <intent> — called after commit_and_push succeeds on
# the fix-reviews / review-changes path. It gates the status=applied claim on
# evidence the pushed commit actually addressed the requested changes: the commit
# must be non-trivial (has a non-whitespace change) AND touch the regions the
# review named (#1567). Otherwise it posts an honest partial / not-applied
# terminal, enumerating per requested item what landed and what did not, and — on
# repeated non-convergence — escalates to a human.
#
# Fail-open: when the diff cannot be computed (no base SHA, shallow clone, fork
# weirdness) it treats the change as substantive so a genuine fix is never
# wrongly downgraded — the guard only downgrades on positive evidence of a
# non-fix.
finalize_review_application() {
  local intent="$1"
  # Dry-run has no worktree diff to assess — preserve the prior announcement.
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    post_reviews_terminal "$intent" "applied" "Changes committed and pushed."
    return 0
  fi

  local pre_sha="${HEAD_SHA:-}" cur_sha
  cur_sha="$(git rev-parse HEAD 2>/dev/null || true)"

  local substantive="true" changed_regions="" named_regions verdict
  if [ -n "$pre_sha" ] && [ -n "$cur_sha" ] \
     && git rev-parse --verify --quiet "${pre_sha}^{commit}" >/dev/null 2>&1; then
    if [ -z "$(git diff -w --name-only "$pre_sha" "$cur_sha" 2>/dev/null)" ]; then
      substantive="false"
    fi
    changed_regions="$(git diff --unified=0 "$pre_sha" "$cur_sha" 2>/dev/null | rce_parse_hunks)"
  fi
  named_regions="$(rce_named_regions "${OPEN_THREADS_JSON:-[]}")"
  verdict="$(rce_classify "$substantive" "$named_regions" "$changed_regions")"

  local enumerated=""
  [ -n "$named_regions" ] && enumerated="$(rce_enumerate "$named_regions" "$changed_regions")"

  case "$verdict" in
    applied)
      clear_not_applied_markers "$intent"
      local summary="Changes committed and pushed."
      [ -n "$enumerated" ] && summary="Changes committed and pushed. Requested items addressed:
${enumerated}"
      post_reviews_terminal "$intent" "applied" "$summary"
      ;;
    partial)
      # Progress was made (some named region was touched), so the run of
      # consecutive zero-progress passes is broken — reset the not-applied
      # counter so old cycles cannot trigger premature escalation (#1567).
      clear_not_applied_markers "$intent"
      # The requested changes are not fully applied — do not let this pass become
      # auto-mergeable.
      _REVIEW_INCOMPLETE=1
      local summary="A commit was pushed, but **not every requested change was applied**. Per requested item:
${enumerated}

The unaddressed items above still need work."
      post_reviews_terminal "$intent" "partial" "$summary"
      ;;
    *)  # not-applied
      # The requested changes were not applied — do not let this pass become
      # auto-mergeable, even before the escalation limit is reached.
      _REVIEW_INCOMPLETE=1
      local summary
      if [ "$substantive" = "false" ]; then
        summary="A commit was pushed, but it made **no substantive change** (whitespace/cosmetic only) — the requested review changes were not applied."
      elif [ -n "$enumerated" ]; then
        summary="A commit was pushed, but it **did not touch any region the review named** — the requested changes were not applied. Per requested item:
${enumerated}"
      else
        summary="A commit was pushed, but there is no evidence it addressed the requested review changes."
      fi
      post_reviews_terminal "$intent" "not-applied" "$summary"
      # AC #4: escalate to a human once non-convergence reaches the limit. The
      # marker for this pass is already posted, so it is included in the count.
      local nonconverged
      nonconverged="$(count_not_applied_markers "$intent")"
      if [ "${nonconverged:-0}" -ge "${REVIEW_NONCONVERGENCE_LIMIT:-3}" ]; then
        echo "::warning::review-changes non-convergence: ${nonconverged} consecutive not-applied passes for intent=${intent} on PR #${PR_NUMBER} — escalating to a human"
        escalate_review_nonconvergence "$intent" "$nonconverged"
      fi
      ;;
  esac
}

# resolution_gate_open <cp_rc> — the #1617 gate that wires the pure #1609
# head-movement predicate (ri_may_resolve) into the resolve_* review-thread nets.
# A dev-lead fix pass may auto-resolve review threads ONLY when it advanced the PR
# head; a pass that produced no commit resolves zero threads. This closes the #1024
# vector where a no-commit pass resolved 18 threads (incl. a Critical finding) purely
# on reply markers. Returns 0 (gate open — resolution permitted) / non-zero (closed).
#
# - Dry-run passes through so the announce-only nets keep announcing what they would
#   resolve — that existing behaviour and its tests are preserved.
# - Otherwise compares the immutable pre-pass RESOLUTION_BASE_SHA (snapshotted right
#   after the worktree checkout, before any work) against the post-pass
#   `git rev-parse HEAD` via ri_may_resolve (fail-closed: an empty or unchanged SHA
#   closes the gate). RESOLUTION_BASE_SHA — not HEAD_SHA — is used deliberately:
#   HEAD_SHA is the event-time value and is reassigned by try_enable_auto_merge, so
#   gating on it could open on a no-commit pass whose checkout drifted from the event.
# - Falls back to cp_rc == 0 ONLY when a SHA is genuinely unavailable (base snapshot
#   unset or `git rev-parse HEAD` unresolvable), so a pass that legitimately pushed a
#   commit is never wrongly gated shut just because the runner cannot report a SHA.
resolution_gate_open() {
  local cp_rc="${1:-1}"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    return 0
  fi
  local pre_sha="${RESOLUTION_BASE_SHA:-}" cur_sha
  cur_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$pre_sha" ] || [ -z "$cur_sha" ]; then
    return "$cp_rc"
  fi
  ri_may_resolve "$pre_sha" "$cur_sha"
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
    # resolve_actor_outdated_threads needs ACTOR (the raw GitHub Actions login,
    # with the [bot] suffix preserved — the helper strips it for the GraphQL
    # comparison). The workflow passes the actor via TRIGGERING_REVIEWER, so
    # fall back to it when ACTOR is not set explicitly.
    export ACTOR="${ACTOR:-${TRIGGERING_REVIEWER:-}}"
    OPEN_THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:50) {
              nodes { id isResolved isOutdated line path comments(first:5) { nodes { body author { login __typename } } } }
            }
          }
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved == false))' 2>/dev/null || echo "[]")
    export OPEN_THREADS_JSON
    fetch_pr_context
    rc=0
    build_and_run "fix-reviews" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-reviews"
    if [ "$rc" -eq 0 ]; then
      cp_rc=0
      commit_and_push "fix-reviews" || cp_rc=$?
      if [ "$cp_rc" -eq 0 ]; then
        notify_coderabbit_resolve
        finalize_review_application "fix-reviews"
      elif [ "$cp_rc" -eq 3 ]; then
        # No-op guard (#1340): the fix nets base…head to zero — already flagged
        # for a human, auto-merge disabled. Post no applied/no-changes/retry
        # marker and do not re-enable auto-merge or resolve threads.
        echo "::warning::fix-reviews produced a net-zero diff — flagged for human, not pushed (#1340)"
      else
        notify_coderabbit_resolve
        if has_hard_blockers; then
          echo "::warning::Tier-1 blockers still present ($(blocking_reason_phrase)) — posting retry marker with backoff"
          post_reviews_rate_limited "fix-reviews" "blocked"
        elif has_tier1_blockers; then
          echo "::notice::Unresolved bot review threads remain — not posting no-changes terminal to allow future retries"
        else
          post_no_changes "fix-reviews"
        fi
      fi
      # Minimize PR issue comments dev-lead has dispositioned + verified (#1813).
      # Deliberately OUTSIDE the review-thread resolution gate: each disposition is
      # verified on its own terms (a `fixed` sha must be on head; out-of-scope needs
      # a tracking issue; invalid/answered/informational need a non-empty evidence
      # reply), so an answered/invalid disposition requires no head advance. Runs on
      # every successful pass, including a net-zero one where the model only replied.
      resolve_dispositioned_comments "fix-reviews"
      if [ "$cp_rc" -ne 3 ]; then
        # Resolution gate (#1617): auto-resolve threads only when this pass advanced
        # the PR head. A no-commit pass resolves zero threads (#1609/#1024).
        if resolution_gate_open "$cp_rc"; then
          resolve_bot_outdated_threads "fix-reviews"
          resolve_actor_outdated_threads "fix-reviews"
          # Resolve bot threads dev-lead addressed in-thread but left open (#1547) —
          # these are not necessarily outdated, so the nets above miss them.
          resolve_addressed_bot_threads "fix-reviews"
        else
          echo "::notice::resolution gate closed (#1609): the fix-reviews pass did not advance PR #${PR_NUMBER}'s head — zero review threads resolved"
        fi
        # Never auto-merge an escalated or not-fully-applied review pass (#1567).
        if [ "${_REVIEW_ESCALATED:-0}" -ne 1 ] && [ "${_REVIEW_INCOMPLETE:-0}" -ne 1 ]; then
          try_enable_auto_merge
        fi
      fi
    fi
    exit "$rc"
    ;;
  fix-bot-comment)
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO ACTOR="${ACTOR:-}" COMMENT_BODY="${COMMENT_BODY:-}" HEAD_SHA
    fetch_pr_context
    rc=0
    build_and_run "fix-bot-comment" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-bot-comment"
    if [ "$rc" -eq 0 ]; then
      cp_rc=0
      commit_and_push "fix-bot-comment" || cp_rc=$?
      if [ "$cp_rc" -eq 0 ]; then
        notify_coderabbit_resolve
        post_reviews_terminal "fix-bot-comment" "applied" "Changes committed and pushed."
      elif [ "$cp_rc" -eq 3 ]; then
        # No-op guard (#1340): the fix nets base…head to zero — already flagged
        # for a human, auto-merge disabled. Post no terminal marker and do not
        # re-enable auto-merge or resolve threads.
        echo "::warning::fix-bot-comment produced a net-zero diff — flagged for human, not pushed (#1340)"
      else
        notify_coderabbit_resolve
        if has_hard_blockers; then
          echo "::warning::Tier-1 blockers still present ($(blocking_reason_phrase)) — fix-bot-comment is not retried automatically; posting terminal marker"
          post_no_changes "fix-bot-comment"
        elif has_tier1_blockers; then
          echo "::warning::Unresolved bot review threads remain — fix-bot-comment is not automatically retried; posting no-changes terminal marker"
          post_no_changes "fix-bot-comment"
        else
          post_no_changes "fix-bot-comment"
        fi
      fi
      # Minimize PR issue comments dev-lead has dispositioned + verified (#1813).
      # Outside the review-thread resolution gate for the same reason as fix-reviews:
      # each disposition is independently verified, so a non-`fixed` disposition
      # needs no head advance. Runs on every successful pass, net-zero included.
      resolve_dispositioned_comments "fix-bot-comment"
      if [ "$cp_rc" -ne 3 ]; then
        # Resolution gate (#1617): auto-resolve threads only when this pass advanced
        # the PR head. A no-commit pass resolves zero threads (#1609/#1024).
        if resolution_gate_open "$cp_rc"; then
          resolve_bot_outdated_threads "fix-bot-comment"
          resolve_actor_outdated_threads "fix-bot-comment"
          # Resolve bot threads dev-lead addressed in-thread but left open (#1547) —
          # these are not necessarily outdated, so the nets above miss them.
          resolve_addressed_bot_threads "fix-bot-comment"
        else
          echo "::notice::resolution gate closed (#1609): the fix-bot-comment pass did not advance PR #${PR_NUMBER}'s head — zero review threads resolved"
        fi
        try_enable_auto_merge
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
      cp_rc=0
      commit_and_push "on-mention" || cp_rc=$?
      if [ "$cp_rc" -eq 3 ]; then
        # Net-zero abort: flag_noop_pr already flagged for human and disabled
        # auto-merge. Do not re-enable it or claim changes were applied (#1786).
        echo "::notice::on-mention: no-op guard aborted the push for PR #${PR_NUMBER} — flagged for human, not merged (#1786)"
        exit "$rc"
      fi
      if [ "$cp_rc" -eq 0 ]; then
        post_reviews_terminal "on-mention" "applied" "Changes committed and pushed."
      else
        post_reviews_terminal "on-mention" "no-changes" "Engine ran but made no changes."
      fi
      # Enable auto-merge by default when the mention targets a PR (issue mentions
      # carry no PR_NUMBER and are skipped). GitHub holds the merge until branch
      # protection is satisfied.
      [[ -n "${PR_NUMBER:-}" ]] && try_enable_auto_merge
    fi
    exit "$rc"
    ;;
  human-pr|review-changes)
    export PR_NUMBER="${PR_NUMBER:-}"
    export PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    # ACTOR is exported so resolve_actor_outdated_threads can scrub outdated
    # threads from the triggering reviewer in the no-changes branch. The
    # workflow's review-changes step passes ACTOR via env.INTENT_ACTOR.
    export REPO ACTOR="${ACTOR:-}" PR_TITLE="${PR_TITLE:-}" PR_DESCRIPTION="${PR_DESCRIPTION:-}"
    OPEN_THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:50) {
              nodes { id isResolved isOutdated line path comments(first:5) { nodes { body author { login __typename } } } }
            }
          }
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved == false))' 2>/dev/null || echo "[]")
    export OPEN_THREADS_JSON BASE_REF="${BASE_REF:-main}"
    fetch_pr_context
    rc=0
    build_and_run "review-changes" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "review-changes"
    if [ "$rc" -eq 0 ]; then
      cp_rc=0
      commit_and_push "review-changes" || cp_rc=$?
      # No-op guard (#1786): a review-changes pass whose net diff to base is empty
      # was already flagged by flag_noop_pr (needs-human label + auto-merge
      # disabled + suppressed EXIT-trap restore). Stop here — never resolve threads
      # or re-enable auto-merge on a self-cancelling PR.
      if [ "$cp_rc" -eq 3 ]; then
        echo "::notice::review-changes: no-op guard aborted the push for PR #${PR_NUMBER} — flagged for human, not merged (#1786)"
        exit "$rc"
      fi
      if [ "$cp_rc" -eq 0 ]; then
        notify_coderabbit_resolve
        finalize_review_application "review-changes"
      else
        notify_coderabbit_resolve
        if has_hard_blockers; then
          echo "::warning::Tier-1 blockers still present ($(blocking_reason_phrase)) — posting retry marker with backoff"
          post_reviews_rate_limited "review-changes" "blocked"
        elif has_tier1_blockers; then
          echo "::notice::Unresolved bot review threads remain — not posting no-changes terminal to allow future retries"
        else
          post_reviews_terminal "review-changes" "no-changes" "No changes were needed for this PR."
        fi
      fi
      # Minimize PR issue comments dev-lead has dispositioned + verified (#1813) —
      # independently verified, so outside the head-movement resolution gate.
      resolve_dispositioned_comments "review-changes"
      # Resolution gate (#1617): auto-resolve threads only when this pass advanced
      # the PR head. A no-commit pass resolves zero threads (#1609/#1024).
      if resolution_gate_open "$cp_rc"; then
        resolve_bot_outdated_threads "review-changes"
        resolve_actor_outdated_threads "review-changes"
        # Resolve bot threads dev-lead addressed in-thread but left open (#1547) —
        # these are not necessarily outdated, so the nets above miss them.
        resolve_addressed_bot_threads "review-changes"
      else
        echo "::notice::resolution gate closed (#1609): the review-changes pass did not advance PR #${PR_NUMBER}'s head — zero review threads resolved"
      fi
      # Never auto-merge an escalated or not-fully-applied review pass (#1567).
      if [ "${_REVIEW_ESCALATED:-0}" -ne 1 ] && [ "${_REVIEW_INCOMPLETE:-0}" -ne 1 ]; then
        try_enable_auto_merge
      fi
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
    # Per-PR exhaustion guard (#865): a stuck conflict must not generate repeated
    # full-timeout runs from auto-rebase-conflict sentinel re-fires. If this PR's
    # rebase is already exhausted, skip cleanly before invoking the engine.
    rebase_exhausted_rc=0
    rebase_pr_is_exhausted || rebase_exhausted_rc=$?
    if [ "$rebase_exhausted_rc" -eq 0 ]; then
      echo "::notice::PR #${PR_NUMBER} rebase is exhausted — skipping (sentinel re-fire guard, #865)"
      exit 0
    elif [ "$rebase_exhausted_rc" -eq 2 ]; then
      # Retrieval fault: we cannot confirm the exhaustion marker is absent, so fail
      # closed — do not invoke the engine on unknown state. Exit nonzero so the
      # retry cron re-dispatches once the transient gh-api/jq fault clears.
      echo "::error::could not retrieve PR #${PR_NUMBER} comments to check rebase exhaustion — failing closed, not invoking engine (#865)"
      exit 1
    fi
    git fetch origin "$BASE_REF"
    CONFLICTING_FILES=$(detect_conflicting_paths "$BASE_REF")
    export CONFLICTING_FILES
    # Up-front large-conflict guard (#865): a conflict spanning more files than
    # the engine can resolve within the writer-tier timeout is aborted cleanly
    # here, rather than handed to the engine and left to run to the per-tier
    # timeout (surfacing as exit 124).
    rebase_conflict_file_count=$(printf '%s\n' "$CONFLICTING_FILES" | grep -c . || true)
    if rebase_conflict_too_large "${rebase_conflict_file_count:-0}" "$REBASE_MAX_CONFLICT_FILES"; then
      echo "::warning::rebase conflict spans ${rebase_conflict_file_count} files (> ${REBASE_MAX_CONFLICT_FILES}) — too large for automated resolution; aborting cleanly (#865)"
      handle_rebase_failure "Conflict too large for automated resolution: ${rebase_conflict_file_count} files conflict against \`${BASE_REF}\` (limit ${REBASE_MAX_CONFLICT_FILES}). Please rebase manually."
      exit 1
    fi
    # Capture the branch tip *before* the resolution so the integrity check can
    # use it as one parent (the base ref is the other) when scanning the resolved
    # tree for introduced duplicate declarations (#1482).
    PRE_RESOLVE_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
    rc=0
    build_and_run "rebase" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "rebase"
    # A per-tier timeout (exit 124) or a hard engine failure means the conflict
    # was not resolved. Convert it into a clean terminal abort with a comment —
    # never a bare process-killed exit 124 (#865) — and count it toward the
    # per-PR exhaustion threshold. (rc==2 already exited via handle_rate_limit.)
    if [ "$rc" -ne 0 ]; then
      handle_rebase_failure "$(rebase_failure_reason "$rc")"
      exit 1
    fi
    if [ "$rc" -eq 0 ]; then
      # Advisory post-resolution integrity check (#1482): flag, do not block.
      # `|| true` guarantees a detector fault can never fail a real resolution.
      run_post_resolution_integrity_check "$BASE_REF" "${PRE_RESOLVE_SHA:-}" || true
      # No-op guard (#1786): a rebase / merge-from-main can ERASE the PR's own
      # changes, netting the base…head diff to zero. The rebase prompt has the
      # engine force-push the rebased branch itself, so we cannot un-push — but we
      # must never report it "applied" (which would let it merge and auto-close its
      # Closes #N issue with nothing fixed). Re-check the already-rebased HEAD and,
      # if it nets to zero, flag for a human instead of reporting success.
      git fetch origin "$BASE_REF" >/dev/null 2>&1 || true
      if pr_nets_to_zero "$BASE_REF"; then
        echo "::error::No-op guard: PR #${PR_NUMBER} nets to zero changed files against ${BASE_REF} after rebase — flagging for human, not reporting applied (#1786)"
        flag_noop_pr "rebase"
        exit "$rc"
      fi
      cp_rc=0
      commit_and_push "rebase" || cp_rc=$?
      if [ "$cp_rc" -eq 3 ]; then
        # commit_and_push committed a script-side change that nets to zero and
        # already flagged it. Stop — never report a self-cancelling rebase applied.
        echo "::notice::rebase: no-op guard aborted the push for PR #${PR_NUMBER} — flagged for human, not merged (#1786)"
        exit "$rc"
      fi
      if [ "$cp_rc" -eq 0 ]; then
        # Engine left commits/changes for the script to push — resolution applied.
        post_reviews_terminal "rebase" "applied" "Rebase completed and pushed."
      else
        # The rebase prompt has the engine force-push the rebased branch itself
        # (rebase.md step 6), so commit_and_push finds nothing to push on success.
        # Relying on it alone recorded EVERY successful rebase as "no-changes"
        # (0% applied — discussion #735 telemetry). Distinguish a real resolution
        # (no conflicts remain against the base) from an abort/no-op (conflicts
        # persist) by re-checking the base conflict state after the run.
        git fetch origin "$BASE_REF" >/dev/null 2>&1 || true
        if [ -z "$(detect_conflicting_paths "$BASE_REF")" ]; then
          post_reviews_terminal "rebase" "applied" "Rebase completed and pushed."
        else
          post_no_changes "rebase"
        fi
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
