#!/usr/bin/env bash
# pr-automation-budget.sh — per-PR automated-churn circuit breaker (issue #926).
#
# PR #860 ran away to 378 commits / 1,582 comments produced entirely by agents
# looping, with no human in the thread. Every pre-existing guard was per-worker
# or per-run; nothing bounded TOTAL automated activity on one PR over its
# lifetime, and no guard's reset required a human.
#
# This library bounds the work item (the PR), not each worker script:
#   compute_pr_automation_cycles <events_json>
#     Counts agent-authored activity (commits + comments + reviews/acks) that
#     happened AFTER the most recent HUMAN interaction. A human action resets
#     the count to zero; a machine action (bot comment, bot commit, machine
#     approval) never does — so the runaway can't re-arm its own budget.
#   pr_budget_exhausted <events_json>
#     Exit 0 when the count has reached MAX_PR_AUTOMATION_CYCLES (default 10).
#   gather_pr_automation_events <pr> <repo>   -> normalized {when, login}[] JSON
#   enforce_pr_budget <pr> <repo>
#     The orchestration entrypoint scripts call before doing automated writes:
#     on exhaustion it escalates ONCE (deduped marker + needs-human-review label
#     + auto-merge disabled) and returns 0 so the caller stops. Returns 1 when
#     there is still budget to proceed.
#
# Events are {when, login} objects. `when` is an ISO-8601 timestamp (strings
# compare correctly); items with null/empty `when` are ignored. A login is a
# bot when it ends in `[bot]` or is listed in AUTOMATION_BOT_LOGINS; an empty /
# unattributed login is treated as a machine (conservative — it must not reset).

# Space-separated bot logins beyond any `*[bot]` GitHub App identity. Includes
# the agent identity (donpetry-bot) and repair-pr-approvals, whose machine
# approvals must not reset the budget.
: "${AUTOMATION_BOT_LOGINS:=donpetry-bot github-actions[bot] repair-pr-approvals}"
: "${MAX_PR_AUTOMATION_CYCLES:=10}"

# The label this breaker adds on exhaustion (and the cycle cap adds on escalation).
# It is the human-controlled re-engagement gate: a human removing it resumes
# automation. The retry/sweep crons skip a PR while it carries this label (#946).
: "${NEEDS_HUMAN_REVIEW_LABEL:=needs-human-review}"

PR_AUTOMATION_EXHAUSTION_MARKER="<!-- pr-automation-budget exhausted -->"

_PR_BUDGET_JQ_DEFS='
  def is_bot($bots):
    . as $login
    | ($login == null) or ($login == "")
      or ($login | endswith("[bot]"))
      or (($bots | index($login)) != null);
'

# compute_pr_automation_cycles <events_json>
#   Prints the number of bot-authored events newer than the latest human event.
compute_pr_automation_cycles() {
  local events_json="${1:-[]}"
  local bots_json count
  bots_json=$(printf '%s' "${AUTOMATION_BOT_LOGINS}" \
    | jq -R 'split(" ") | map(select(. != ""))' 2>/dev/null) || bots_json='[]'
  count=$(jq -r --argjson bots "$bots_json" "$_PR_BUDGET_JQ_DEFS"'
    map(select(.when != null and .when != ""))
    | ([.[] | select((.login | is_bot($bots)) | not) | .when] | max // "") as $last_human
    | [.[] | select((.login | is_bot($bots)) and (.when > $last_human))]
    | length
  ' <<<"$events_json" 2>/dev/null) || count=0
  # Defensive: malformed input degrades to 0 so the integer comparison at the
  # budget gate never breaks ("integer expression expected").
  case "$count" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$count" ;;
  esac
}

# pr_has_escalation_label <labels_json>
#   Exit 0 if the JSON array of label NAMES contains NEEDS_HUMAN_REVIEW_LABEL —
#   i.e. the PR is currently escalated to a human.
#
#   This is the gate the retry/sweep crons consult before re-dispatching (#946),
#   so a PR that exhausted its automation budget is not re-ignited (the #860
#   "amplifier" failure mode). We gate on the LABEL, not the exhaustion MARKER
#   comment: the marker is an immutable audit record that the resume flow can
#   never clear, so gating on it would make re-engagement impossible. The label
#   is human-controlled — removing it re-enables the crons — mirroring
#   review-one-pr.sh, which pauses only while the label is present.
#
#   Malformed/empty/missing input degrades to "not escalated" (exit 1).
pr_has_escalation_label() {
  local labels_json="${1:-[]}"
  jq -e --arg l "${NEEDS_HUMAN_REVIEW_LABEL}" \
    'if type == "array" then any(.[]; . == $l) else false end' \
    <<<"$labels_json" >/dev/null 2>&1
}

# pr_resume_suppressed <pr> <repo> [labels_json] [events_json]
#   Exit 0 (SUPPRESS — do NOT resume / re-dispatch) when the PR is human-gated
#   (carries NEEDS_HUMAN_REVIEW_LABEL) OR its per-PR automation budget is
#   exhausted; exit 1 (proceed) otherwise.
#
#   This is the SINGLE stop-condition consulted before any automated resume of a
#   blocked/rate-limited dev-lead state — by the event-first resume bridge
#   (scripts/dev-lead-resume.sh) AND the safety-net cron
#   (scripts/dev-lead-retry.sh). Routing both paths through one gate is what makes
#   the event fast-path provably as safe as the timer (#1407 AC #3): neither can
#   re-ignite the #860 amplifier. It is the LABEL + the BUDGET together — the
#   label is the human-controlled re-engagement gate (#946), the budget is the
#   since-last-human action ceiling (#926); FORCE_REVIEW does not bypass either.
#
#   labels_json / events_json may be passed in by a caller that already fetched
#   them (avoids a redundant API round-trip); when omitted they are fetched here.
pr_resume_suppressed() {
  local pr="$1" repo="$2" labels_json="${3:-}" events_json="${4:-}"
  [ -n "$pr" ] && [ -n "$repo" ] || return 1

  if [ -z "$labels_json" ]; then
    labels_json=$(gh api "repos/${repo}/pulls/${pr}" \
      --jq '[.labels[]?.name]' 2>/dev/null || echo '[]')
  fi
  if pr_has_escalation_label "$labels_json"; then
    echo "  [suppress] PR #${pr} in ${repo} carries ${NEEDS_HUMAN_REVIEW_LABEL} — human-gated; not resuming (#946)" >&2
    return 0
  fi

  if [ -z "$events_json" ]; then
    events_json=$(gather_pr_automation_events "$pr" "$repo")
  fi
  if pr_budget_exhausted "$events_json"; then
    echo "  [suppress] PR #${pr} in ${repo} exhausted its per-PR automation budget (MAX_PR_AUTOMATION_CYCLES=${MAX_PR_AUTOMATION_CYCLES}) since the last human interaction — not resuming (#926/#860)" >&2
    return 0
  fi

  return 1
}

# pr_budget_exhausted <events_json>
#   Exit 0 when the per-PR automation budget is spent.
pr_budget_exhausted() {
  local events_json="${1:-[]}"
  local n
  n=$(compute_pr_automation_cycles "$events_json")
  [ "${n:-0}" -ge "${MAX_PR_AUTOMATION_CYCLES:-10}" ]
}

# gather_pr_automation_events <pr> <repo>
#   Assemble {when, login}[] from the PR's commits, issue comments, and reviews.
gather_pr_automation_events() {
  local pr="$1" repo="$2"
  local comments commits reviews
  comments=$(gh api --paginate "repos/${repo}/issues/${pr}/comments?per_page=100" 2>/dev/null \
    | jq -s '[.[][] | {when: .created_at, login: (.user?.login // "")}]' 2>/dev/null) || comments='[]'
  commits=$(gh api --paginate "repos/${repo}/pulls/${pr}/commits?per_page=100" 2>/dev/null \
    | jq -s '[.[][] | {when: (.commit?.author?.date // .commit?.committer?.date), login: (.author?.login // .commit?.author?.name // "")}]' 2>/dev/null) || commits='[]'
  reviews=$(gh api --paginate "repos/${repo}/pulls/${pr}/reviews?per_page=100" 2>/dev/null \
    | jq -s '[.[][] | {when: .submitted_at, login: (.user?.login // "")}]' 2>/dev/null) || reviews='[]'
  jq -n --argjson a "${comments:-[]}" --argjson b "${commits:-[]}" --argjson c "${reviews:-[]}" \
    '$a + $b + $c' 2>/dev/null || echo '[]'
}

# pr_automation_already_escalated <pr> <repo>
#   Exit 0 if the exhaustion escalation comment is already present (dedupe).
pr_automation_already_escalated() {
  local pr="$1" repo="$2"
  gh api --paginate "repos/${repo}/issues/${pr}/comments?per_page=100" 2>/dev/null \
    | jq -r '.[].body // ""' 2>/dev/null \
    | grep -qF "$PR_AUTOMATION_EXHAUSTION_MARKER"
}

# pr_automation_escalate <pr> <repo>
#   Post one deduped escalation, add needs-human-review, disable auto-merge.
#   Re-engagement is human-gated: only a human removing the label / acting on
#   the PR resets the budget (see compute_pr_automation_cycles).
pr_automation_escalate() {
  local pr="$1" repo="$2"
  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ] || [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[dry-run] would escalate PR #${pr}: post budget-exhaustion comment, add needs-human-review, disable auto-merge"
    return 0
  fi
  if pr_automation_already_escalated "$pr" "$repo"; then
    echo "::notice::PR #${pr} already has a pr-automation-budget escalation — not re-posting"
    return 0
  fi
  local body
  body="${PR_AUTOMATION_EXHAUSTION_MARKER}
## Automated activity budget exhausted — human attention needed

This PR has reached **${MAX_PR_AUTOMATION_CYCLES}** automated actions (agent commits + review cycles + acks) since the last human interaction, without converging. To prevent a runaway loop (see #926 / the #860 post-mortem), all automated commits, reviews, and acknowledgements on this PR are now **paused**, auto-merge is disabled, and \`needs-human-review\` is applied.

**Re-engaging is human-gated.** A human reviewing, commenting, or pushing to this PR resets the budget; a machine action will not. Removing \`needs-human-review\` after a human has looked is the clean way to resume."
  gh pr comment "$pr" --repo "$repo" --body "$body" \
    || echo "::warning::could not post budget-exhaustion comment on PR #${pr}"
  gh pr edit "$pr" --repo "$repo" --add-label "$NEEDS_HUMAN_REVIEW_LABEL" 2>/dev/null \
    || echo "::warning::could not add ${NEEDS_HUMAN_REVIEW_LABEL} on PR #${pr}"
  gh pr merge "$pr" --repo "$repo" --disable-auto 2>/dev/null \
    || echo "::notice::auto-merge was not enabled on PR #${pr} (nothing to disable)"
  return 0
}

# enforce_pr_budget <pr> <repo>
#   Returns 0 (exhausted — caller must STOP all automated writes) after
#   escalating once, or 1 (budget remains — proceed).
enforce_pr_budget() {
  local pr="$1" repo="$2"
  [ -n "$pr" ] && [ -n "$repo" ] || return 1
  local events
  events=$(gather_pr_automation_events "$pr" "$repo")
  if pr_budget_exhausted "$events"; then
    echo "::warning::PR #${pr} reached MAX_PR_AUTOMATION_CYCLES=${MAX_PR_AUTOMATION_CYCLES} automated actions since the last human interaction — halting automation"
    pr_automation_escalate "$pr" "$repo"
    return 0
  fi
  return 1
}
