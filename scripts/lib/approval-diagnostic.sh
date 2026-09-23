#!/usr/bin/env bash
# approval-diagnostic.sh — the single "why is this PR not approved?" diagnostic (#1894).
#
# Ten of eleven open PRs in this repo had never received an approving review, yet
# every component reported healthy: the advisory gate logged "ready to approve",
# the disposition gate logged a dismissal, and the PR's own surface showed only
# `REVIEW_REQUIRED` with no reason. No component owned the END-TO-END question, so
# diagnosing one PR meant reading three scripts and correlating timeline events by
# hand. This library owns that question.
#
# diagnose_approval evaluates the approval gate chain and emits ONE structured
# verdict naming:
#   * blocking_gate  — the gate that withholds approval (or "none" when approved),
#   * condition      — the specific unmet condition, and
#   * satisfied_by   — exactly what would satisfy it.
# It reports the DEEPEST ENDURING blocker, NOT the runtime's first-indicated skip
# reason (#1902). review-one-pr.sh consults the advisory gate FIRST, but that gate
# never truly withholds — it always proceeds once its head-age/quiescence timeout
# elapses. So when a PR simultaneously has incomplete advisory evidence AND an
# undispositioned maintainer comment (or an unresolved maintainer thread), the
# runtime may skip first with `waiting-for-advisory-bots`, yet the comment/thread
# gate is the blocker that STILL stands after the advisory timeout fires. The
# diagnostic names that enduring blocker (comment/thread gate ahead of
# advisory-waiting) so the operator sees the condition they must actually clear,
# not the transient one that will time out.
# It also always reports the advisory denominator RECONCILED with the registry
# (#1894 AC #2): `advisory.required` is the count of advisory_gate=yes logins in
# reviewer-sources.tsv and `advisory.missing` names the bots that have not
# participated, so a partial denominator (the "6 != 7" silent drop) is observable
# rather than hidden inside an effective-total subtraction.
#
# It is PURE — it reads a PR snapshot JSON (the exact object review-one-pr.sh
# already fetches: reviewDecision, headRefOid, reviews, comments, labels) plus, when
# the caller supplies it, the review-thread snapshot the maintainer-review-thread
# gate (#1415) consumes, and writes JSON / Markdown, doing NO network I/O itself —
# so it is unit-tested in tests/test_approval_diagnostic.bats. The caller (or the
# standalone runner) fetches the review threads, exactly as it already fetches the
# PR snapshot.
#
# It FAILS CLOSED (mirrors the gates it summarizes): an unparseable snapshot
# returns non-zero and never emits `approved:true`, so an undeterminable state can
# never be read as "nothing wrong" (the AGENTS.md "cannot check ≠ nothing to
# check" rule).

set -euo pipefail

# Agent-comment markers — IDENTICAL to maintainer-comment-gate.sh's
# _MAINTAINER_GATE_AGENT_MARKERS so the diagnostic's undispositioned-comment count
# can never diverge from the gate that actually withholds approval. A comment
# carrying any of these is one of our own automation's replies, never a finding.
readonly _APPROVAL_DIAG_AGENT_MARKERS='<!-- (pr-review-agent|pr-review-claim|persona:|dev-lead|dependency-advisory)[^>]*-->'

# Canonical rate-limit / out-of-quota body pattern — IDENTICAL to
# advisory-review-gate.sh's ADVISORY_RATE_LIMIT_RE (#711/#1349). The advisory gate
# keeps only each bot's LATEST submission and drops it from the effective set when
# that latest submission is a rate-limit notice. So the diagnostic must classify
# the same way: a bot whose latest review/comment is a rate-limit notice did NOT
# submit real advisory evidence. Counting any historical appearance would
# over-report participation and diverge from the gate (the b76 defect).
# shellcheck disable=SC2034
readonly _APPROVAL_DIAG_RATE_LIMIT_RE='usage limit|rate[-_ ]?limit|too many requests|quota (exceeded|reached|exhausted)|out of (quota|credits|tokens|requests)|limit (reached|exceeded|exhausted)|(reached|exceeded|hit) (the |your )?(usage |rate |daily |monthly )?limit|used up its prepaid credits|Qodo.{0,40}(monthly|usage|PR|review) limit|CodeAnt.{0,40}(monthly|trial|usage) limit'

# Sentinel the caller passes for [review_threads_json] when the review-thread FETCH
# itself failed (mrtg_fetch_review_threads echoes an empty string only on an API
# failure — a PR with no threads yields {"reviewThreads":[]}). The real
# maintainer-review-thread gate (#1415) fails closed on that same failure, so the
# diagnostic must too: a surface it could not read may hide an unresolved maintainer
# thread that blocks approval. Distinct from "" (thread data not supplied), which
# keeps the diagnostic pure and simply does not model that gate (#1902).
readonly _APPROVAL_DIAG_THREADS_FETCH_FAILED='__MRT_FETCH_FAILED__'

# Kept in sync with advisory-review-gate.sh's ADVISORY_HEAD_AGE_TIMEOUT_SEC (#1193):
# the head-push age past which the advisory gate stops waiting and proceeds on
# partial evidence. The diagnostic runs BEFORE the gate but holds the same head
# committer date, so it predicts the same head-age timeout — an old PR reports
# "approval issues via the head-age timeout" instead of "still waiting", matching
# the run (#1902). The quiescence timeout stays gate-owned (it depends on live
# submission timing) to avoid duplicating drift-prone logic here.
# shellcheck disable=SC2034
readonly _APPROVAL_DIAG_HEAD_AGE_TIMEOUT_SEC=1200

# _approval_diag_default_advisory_json
#   The advisory-gate denominator as a JSON array of logins, derived from the
#   reviewer-source registry (advisory_gate=yes) so the diagnostic and the gate
#   share one source of truth. Falls back to the built-in advisory set when the
#   registry is absent/unreadable — never `exit`, matching advisory-review-gate.sh
#   (#1538): this file is sourced into the review process and the test suite.
_approval_diag_default_advisory_json() {
  local reg_sh logins="" json=""
  reg_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewer-sources.sh"
  if [ -f "$reg_sh" ]; then
    # shellcheck source=scripts/lib/reviewer-sources.sh
    # shellcheck disable=SC1091
    if source "$reg_sh" 2>/dev/null; then
      logins="$(reviewer_sources_advisory_gate_logins 2>/dev/null)" || logins=""
      if [ -n "$logins" ]; then
        json="$(jq -R . <<<"$logins" | jq -sc 'map(select(. != ""))')" || json=""
      fi
    fi
  fi
  if [ -z "$json" ] || [ "$json" = "[]" ]; then
    json='["copilot-pull-request-reviewer","gemini-code-assist","chatgpt-codex-connector","sonarqubecloud","qodo-code-review","codeant-ai","graphite-app"]'
  fi
  printf '%s' "$json"
}

# diagnose_approval <pr_snapshot_json> [advisory_json] [approver] [review_threads_json] [head_committer_date_iso]
#   <pr_snapshot_json>      — output of `gh pr view --json reviewDecision,headRefOid,reviews,comments,labels`.
#   [advisory_json]         — JSON array of advisory-gate logins (default: registry projection).
#   [approver]              — the login pr-review approves as (default: donpetry-bot).
#   [review_threads_json]   — optional {"reviewThreads":[…]} snapshot (the exact object
#                             mrtg_fetch_review_threads emits). When supplied, the
#                             maintainer-review-thread gate (#1415) is modelled in-chain by
#                             REUSING check_maintainer_review_threads, so the diagnostic can
#                             never report approval while an unresolved maintainer thread
#                             blocks it (the b78 gap). When absent, that gate is not evaluated
#                             (the diagnostic stays pure and its verdict covers only the
#                             review/comment surface it can see).
#   [head_committer_date_iso] — head commit committer date, passed straight to the review-thread
#                             gate for its postdates-push comparison.
#
#   Prints ONE verdict JSON object to stdout:
#     { pr, approved, head_sha, blocking_gate, condition, satisfied_by,
#       advisory: { required, submitted, missing, via_timeout } }
#   Returns 0 on a determinable verdict, 2 when the snapshot cannot be parsed
#   (fail-closed — never emits approved:true in that case). Still does NO network
#   I/O: any review-thread data is supplied by the caller, exactly like the snapshot.
diagnose_approval() {
  local snap="${1:-}"
  local advisory="${2:-}"
  local approver="${3:-donpetry-bot}"
  local review_threads="${4:-}"
  local head_date="${5:-}"
  [ -n "$advisory" ] || advisory="$(_approval_diag_default_advisory_json)"

  # Extract the raw facts in a single jq pass. A parse failure (malformed snapshot,
  # or a value that can't be indexed) exits non-zero → fail closed.
  local facts
  facts=$(printf '%s' "$snap" | jq -c \
    --argjson advisory "$advisory" \
    --arg approver "$approver" \
    --arg markers "$_APPROVAL_DIAG_AGENT_MARKERS" \
    --arg ratelimit "$_APPROVAL_DIAG_RATE_LIMIT_RE" '
      def approver_logins: [$approver, ($approver | if endswith("[bot]") then .[0:-5] else . end)];
      # Validate the snapshot BEFORE deriving a verdict (#1902). An incomplete
      # snapshot (not an object, or missing the head SHA / reviews array) must NOT
      # be read as "approved with no findings" — it is undeterminable, so error out
      # and let the caller fail closed (return 2), mirroring the gates this
      # diagnostic summarizes ("cannot check ≠ nothing to check").
      ( if (type != "object") then error("snapshot is not a JSON object")
        elif (has("headRefOid") | not) or ((.headRefOid // "") == "") then error("snapshot missing headRefOid (head data)")
        elif (has("reviews") | not) or ((.reviews | type) != "array") then error("snapshot missing reviews array (review data)")
        else . end )
      | ($advisory | map(ascii_downcase)) as $adv
      | (.headRefOid // "") as $sha
      | (.reviewDecision // "") as $decision
      # Advisory participation, reconciled with advisory-review-gate.sh
      # get_advisory_bot_states: build each advisory bot submission set (a review
      # carries its own state; a comment whose body matches the rate-limit pattern
      # is RATE_LIMITED, else COMMENTED), keep the LATEST per bot, and count a bot as
      # participated only when its latest state is neither RATE_LIMITED nor
      # UNSUPPORTED — the gate effective set. So a bot whose newest signal is a
      # rate-limit notice (even after an older real review) is NOT counted (b76).
      | ( [ (.reviews // [])[]
              | { bot: (.author.login // "" | ascii_downcase),
                  state: (.state // ""),
                  time: (.submittedAt // "") } ]
          + [ (.comments // [])[]
              | { bot: (.author.login // "" | ascii_downcase),
                  state: (if ((.body // "") | test($ratelimit; "i")) then "RATE_LIMITED" else "COMMENTED" end),
                  time: (.createdAt // "") } ]
          | map(select(.bot as $b | $adv | index($b)))
          | group_by(.bot)
          | map(sort_by(.time) | last)
        ) as $latest
      | ([ $latest[] | select(.state != "RATE_LIMITED" and .state != "UNSUPPORTED") | .bot ] | unique) as $participated
      # Unavailable = advisory bots whose LATEST signal is a rate-limit/unsupported
      # notice — IDENTICAL to num_unavailable in advisory-review-gate.sh (#657). The
      # runtime gate decides against effective_total = required minus unavailable
      # (clamped to >= 1), so the diagnostic must classify against the same effective
      # denominator, or a PR where every AVAILABLE bot submitted (6/6 with one
      # rate-limited of 7 registered) would be mislabelled waiting while the gate
      # is ready to approve (#1902). The full registry count stays in advisory.required.
      | ([ $latest[] | select(.state == "RATE_LIMITED" or .state == "UNSUPPORTED") | .bot ] | unique) as $unavailable_bots
      | ([ [($adv | length) - ($unavailable_bots | length), 1] | max ]) as $eff_arr
      | ([ $adv[] | select(. as $b | ($participated | index($b)) | not) ] | sort) as $missing
      # Undispositioned non-agent issue comments (maintainer-comment-gate logic).
      | ([ (.comments // [])[] | objects
           | (.author.login // "" | ascii_downcase) as $l
           | select((approver_logins | map(ascii_downcase) | index($l)) | not)
           | select(((.body // "") | test($markers)) | not)
           | select(((.isMinimized // false) == true)
                    and (((.minimizedReason // "") | ascii_downcase) == "resolved") | not)
         ] | length) as $undispositioned
      | ([ (.reviews // [])[]
           | select((.state // "") == "CHANGES_REQUESTED" and (.commit.oid // "") == $sha) ] | length) as $cr_at_head
      | ([ (.reviews // [])[]
           | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
           | select((.state // "") == "APPROVED" and (.commit.oid // "") == $sha) ] | length) as $appr_at_head
      | { head_sha: $sha,
          decision: $decision,
          required: ($adv | length),
          submitted: ($participated | length),
          unavailable: ($unavailable_bots | length),
          effective: ($eff_arr[0]),
          missing: $missing,
          undispositioned: $undispositioned,
          cr_at_head: $cr_at_head,
          appr_at_head: $appr_at_head }
    ' 2>/dev/null) || {
    echo "[approval-diagnostic] ERROR: could not parse PR snapshot — failing closed" >&2
    return 2
  }
  if [ -z "$facts" ]; then
    echo "[approval-diagnostic] ERROR: PR snapshot produced no verdict — failing closed" >&2
    return 2
  fi

  # One jq pass, read line-per-field via mapfile. mapfile preserves empty fields
  # (an empty head_sha or decision is a blank line, kept as an empty element) —
  # unlike an IFS=$'\t' read, where tab is whitespace-class and adjacent empty
  # fields would collapse and shift every subsequent value.
  local _f=()
  mapfile -t _f < <(jq -r '.head_sha, .decision, .required, .submitted, .cr_at_head, .appr_at_head, .undispositioned, .effective, .unavailable' <<<"$facts")
  local head_sha="${_f[0]}" decision="${_f[1]}" required="${_f[2]}" submitted="${_f[3]}"
  local cr_at_head="${_f[4]}" appr_at_head="${_f[5]}" undispositioned="${_f[6]}"
  local effective="${_f[7]}" unavailable="${_f[8]}"

  # Maintainer review-thread gate (#1415), modelled only when the caller supplies
  # review-thread data. REUSE check_maintainer_review_threads so the diagnostic and
  # the runtime gate can never disagree (the b78 fix). Any non-zero return (an
  # unresolved maintainer thread postdating the push, or an undeterminable one)
  # means the gate withholds approval, so it blocks here too. Guarded: source the
  # sibling gate once (re-sourcing would trip its readonly vars), and never let a
  # missing file or a gate error abort the diagnostic.
  local mrt_block="no" mrt_undeterminable="no"
  if [ "$review_threads" = "$_APPROVAL_DIAG_THREADS_FETCH_FAILED" ]; then
    # The review-thread fetch failed (thread F, #1902). The real gate fails closed on
    # this same failure, so the diagnostic must too — an unread surface may hide an
    # unresolved maintainer thread. Block, and mark it undeterminable so the condition
    # names the fetch failure rather than falsely asserting a specific unresolved thread.
    mrt_block="yes"
    mrt_undeterminable="yes"
  elif [ -n "$review_threads" ]; then
    if ! declare -f check_maintainer_review_threads >/dev/null 2>&1; then
      # shellcheck source=scripts/lib/maintainer-review-thread-gate.sh
      # shellcheck disable=SC1091
      source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/maintainer-review-thread-gate.sh" 2>/dev/null || true
    fi
    if declare -f check_maintainer_review_threads >/dev/null 2>&1; then
      local _mrt_rc=0
      check_maintainer_review_threads "$review_threads" "$head_date" "$approver" >/dev/null 2>&1 || _mrt_rc=$?
      [ "$_mrt_rc" -ne 0 ] && mrt_block="yes"
    fi
  fi

  # Head-age timeout prediction (thread D, #1902). The advisory gate proceeds on
  # partial evidence once the head push is older than the head-age timeout. The
  # diagnostic runs BEFORE the gate, but it holds the same head committer date, so it
  # predicts the same timeout: an old PR reports "approval issues via the head-age
  # timeout" instead of "still waiting", so the summary matches the run. Best-effort:
  # an absent/unparseable head_date leaves this "no" and the waiting branch is used.
  local head_age_timeout="no"
  if [ -n "$head_date" ]; then
    local _head_epoch="" _now_epoch
    _head_epoch=$(date -u -d "$head_date" +%s 2>/dev/null) \
      || _head_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$head_date" +%s 2>/dev/null) \
      || _head_epoch=""
    if [ -n "$_head_epoch" ]; then
      _now_epoch=$(date -u +%s)
      [ $((_now_epoch - _head_epoch)) -gt "$_APPROVAL_DIAG_HEAD_AGE_TIMEOUT_SEC" ] && head_age_timeout="yes"
    fi
  fi

  local approved="false" gate condition satisfied_by via_timeout="false"

  # Gate chain — the DEEPEST ENDURING blocker, NOT review-one-pr.sh's first skip
  # reason (#1902). The advisory gate never truly withholds (it always proceeds once
  # its head-age/quiescence timeout elapses), so advisory-waiting is reported only
  # when no maintainer gate outlasts it: an undispositioned comment or an unresolved
  # maintainer thread STILL blocks after the advisory timeout fires, so it is checked
  # first here even though the runtime consults the advisory gate first. The
  # maintainer gates are also checked BEFORE the "an approval already exists at head"
  # fallback, because both DISMISS a standing approval (the #1813/#1415 revocations) —
  # so an undispositioned comment or an unresolved maintainer thread must win over an
  # approval that is about to be revoked.
  if [ "$undispositioned" -gt 0 ]; then
    gate="maintainer-comment-gate"
    condition="${undispositioned} PR issue comment(s) lack a verified disposition (not minimized RESOLVED) — #1290/#1813"
    satisfied_by="each non-agent comment is minimized with classifier RESOLVED after a verified disposition, or an @mention (FORCE_REVIEW) bypasses the gate"
  elif [ "$mrt_block" = "yes" ]; then
    gate="maintainer-review-thread-gate"
    if [ "$mrt_undeterminable" = "yes" ]; then
      condition="the review-thread surface could not be fetched, so an unresolved maintainer thread cannot be ruled out — failing closed (#1415/#1902)"
      satisfied_by="the review-thread fetch succeeds on a subsequent run and no unresolved maintainer thread postdates the last push"
    else
      condition="an unresolved maintainer review thread postdates the last push (or its authorship/push-time is undeterminable) — #1415"
      satisfied_by="the maintainer resolves the thread and a new commit is pushed, or an @mention (FORCE_REVIEW) bypasses the gate"
    fi
  elif [ "$decision" = "APPROVED" ]; then
    approved="true"
    gate="none"
    condition="the PR has an approving review at head ${head_sha:0:8}"
    satisfied_by=""
  elif [ "$decision" = "CHANGES_REQUESTED" ] && [ "$cr_at_head" -gt 0 ]; then
    gate="changes-requested"
    condition="a CHANGES_REQUESTED review targets the current head commit ${head_sha:0:8}"
    satisfied_by="the reviewer approves, the author pushes a new commit making the review stale, or @mentions the bot for a re-review"
  elif [ "$appr_at_head" -gt 0 ]; then
    # An approving review exists at head and nothing blocks — the reviewDecision is
    # merely lagging (or the ruleset needs more approvers than are present here).
    approved="true"
    gate="none"
    condition="an approving review from ${approver} exists at head ${head_sha:0:8}"
    satisfied_by=""
  elif [ "$submitted" -lt "$effective" ]; then
    # Advisory evidence is incomplete — classified against the EFFECTIVE denominator
    # (effective = required − unavailable), IDENTICAL to advisory-review-gate.sh, so a
    # PR where every AVAILABLE bot submitted (rate-limited/unsupported bots dropped)
    # is never mislabelled "waiting" while the gate is ready to approve (#1902). The
    # full registry count stays in advisory.required for observability.
    if [ "$head_age_timeout" = "yes" ]; then
      # The head-age timeout has ALREADY elapsed (snapshot-provable from the head
      # committer date): the advisory gate will proceed on partial evidence and
      # pr-review issues its approving review on the next run. Report it as a proven
      # timeout fallback, not "still waiting" — this is the case thread D describes.
      gate="approval-not-yet-issued"
      condition="advisory evidence is incomplete (${submitted}/${effective} effective advisory bots; ${required} registered, ${unavailable} unavailable) but the advisory head-age timeout has elapsed — approval issues on partial evidence on the next pr-review run"
      satisfied_by="pr-review re-runs and issues its approving review on the elapsed head-age timeout (partial evidence)"
      via_timeout="true"
    else
      # No timeout has fired yet: the advisory gate is WAITING inside its windows.
      gate="waiting-for-advisory-bots"
      condition="advisory evidence is incomplete (${submitted}/${effective} effective advisory bots have participated; ${required} registered, ${unavailable} unavailable); the advisory gate is still waiting and has not reached a timeout fallback"
      satisfied_by="the missing advisory bots submit a review/comment, or the advisory gate's head-age/quiescence timeout elapses and pr-review issues its approving review on partial evidence"
    fi
  else
    gate="approval-not-yet-issued"
    condition="no approving review from ${approver} exists at head ${head_sha:0:8}; advisory evidence is complete (${submitted}/${effective} effective; ${required} registered) so approval would issue on the next pr-review run"
    satisfied_by="pr-review re-runs and issues its approving review — an advisory bot's pull_request_review event or the scheduled pr-review sweep re-triggers it"
  fi

  # via_timeout means approval issues on partial evidence via the advisory gate
  # timeout fallback. It is set ONLY where the snapshot can PROVE the timeout — the
  # head-age branch above, where the head committer date shows the head-age window
  # has elapsed. A STANDING approval on incomplete advisory evidence is NOT annotated
  # via_timeout (thread H, #1902): the snapshot cannot prove the approval issued via a
  # timeout rather than on the reduced effective denominator or manually.

  local pr_ref="${PR_URL:-}"
  jq -cn \
    --arg pr "$pr_ref" \
    --argjson approved "$approved" \
    --arg head_sha "$head_sha" \
    --arg gate "$gate" \
    --arg condition "$condition" \
    --arg satisfied_by "$satisfied_by" \
    --argjson required "$required" \
    --argjson submitted "$submitted" \
    --argjson missing "$(jq -c '.missing' <<<"$facts")" \
    --argjson via_timeout "$via_timeout" '
    { pr: $pr, approved: $approved, head_sha: $head_sha,
      blocking_gate: $gate, condition: $condition, satisfied_by: $satisfied_by,
      advisory: { required: $required, submitted: $submitted, missing: $missing, via_timeout: $via_timeout } }'
}

# render_approval_diagnostic <verdict_json>
#   PURE Markdown renderer for the step summary / a PR marker. Turns the verdict
#   into the block an operator reads instead of correlating three scripts by hand.
render_approval_diagnostic() {
  local verdict="${1:-}"
  local approved gate condition satisfied_by required submitted missing via_timeout
  if [ -z "$verdict" ] || ! jq -e . <<<"$verdict" >/dev/null 2>&1; then
    echo "_approval diagnostic unavailable (unparseable verdict)_"
    return 0
  fi
  # One jq pass, read line-per-field via mapfile so empty fields (e.g. a boolean
  # `false` stringified, or an empty `missing` join) are preserved as blank lines
  # rather than collapsing under a whitespace-class tab IFS and shifting the rest.
  # `?` chaining and `// ""` guard missing/null parents so a partial verdict never
  # aborts the render under set -e.
  local _f=()
  mapfile -t _f < <(jq -r '
    (.approved | tostring),
    (.blocking_gate // ""),
    (.condition // ""),
    (.satisfied_by // ""),
    (.advisory?.required // "" | tostring),
    (.advisory?.submitted // "" | tostring),
    ((.advisory?.missing // []) | join(", ")),
    (.advisory?.via_timeout | tostring)' <<<"$verdict")
  approved="${_f[0]}"; gate="${_f[1]}"; condition="${_f[2]}"; satisfied_by="${_f[3]}"
  required="${_f[4]}"; submitted="${_f[5]}"; missing="${_f[6]}"; via_timeout="${_f[7]}"

  printf '### Approval diagnostic\n\n'
  if [ "$approved" = "true" ]; then
    printf -- '- **Status:** APPROVED — %s.\n' "$condition"
  else
    # shellcheck disable=SC2016  # backticks are literal Markdown code spans, not command substitution
    printf -- '- **Not approved.** Blocking gate: `%s`.\n' "$gate"
    printf -- '- **Condition:** %s\n' "$condition"
    printf -- '- **Satisfied by:** %s\n' "$satisfied_by"
  fi
  printf -- '- **Advisory evidence:** %s/%s registered advisory bots participated' "$submitted" "$required"
  if [ "$via_timeout" = "true" ]; then
    printf ' (approval issues via the timeout fallback — partial evidence)'
  fi
  printf '.\n'
  if [ -n "$missing" ]; then
    printf -- '- **Advisory bots not participating:** %s.\n' "$missing"
  fi
  printf '\n'
}

# Run standalone against a PR URL (only if executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  _pr_url="${1:-}"
  if [[ -z "$_pr_url" ]]; then
    echo "usage: approval-diagnostic.sh <pr-url>" >&2
    exit 2
  fi
  export PR_URL="$_pr_url"
  set +e
  _snap=$(gh pr view "$_pr_url" --json reviewDecision,headRefOid,reviews,comments,labels 2>/dev/null)
  _gh_rc=$?
  set -e
  if [ "$_gh_rc" -ne 0 ] || [ -z "$_snap" ]; then
    echo "[approval-diagnostic] ERROR: gh pr view failed for $_pr_url" >&2
    exit 2
  fi
  # Fetch the review-thread surface + head push-time so the standalone run models the
  # maintainer-review-thread gate (#1415) too, matching the runtime chain. A FETCH
  # FAILURE (empty output from a declared helper) passes the fail-closed sentinel so
  # the diagnostic blocks rather than skipping the thread gate (thread F, #1902).
  _threads=""
  _head_date=""
  _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _mrt_lib="$_lib_dir/maintainer-review-thread-gate.sh"
  if [ -f "$_mrt_lib" ]; then
    # The head-commit push-time helper lives in the sibling issue-comment gate.
    if [ -f "$_lib_dir/maintainer-comment-gate.sh" ]; then
      # shellcheck source=scripts/lib/maintainer-comment-gate.sh
      # shellcheck disable=SC1091
      source "$_lib_dir/maintainer-comment-gate.sh" 2>/dev/null || true
    fi
    # shellcheck source=scripts/lib/maintainer-review-thread-gate.sh
    # shellcheck disable=SC1091
    source "$_mrt_lib" 2>/dev/null || true
    if declare -f mrtg_fetch_review_threads >/dev/null 2>&1; then
      _threads=$(mrtg_fetch_review_threads "$_pr_url" 2>/dev/null) || _threads=""
      # An empty result from a declared helper is an API failure (a PR with no threads
      # yields {"reviewThreads":[]}). Fail closed via the sentinel, matching the gate.
      [ -z "$_threads" ] && _threads="$_APPROVAL_DIAG_THREADS_FETCH_FAILED"
    fi
    if declare -f maintainer_gate_head_committer_date >/dev/null 2>&1; then
      _head_date=$(maintainer_gate_head_committer_date "$_pr_url" 2>/dev/null) || _head_date=""
    fi
  fi
  set +e
  _verdict=$(diagnose_approval "$_snap" "" "${BOT_USER:-donpetry-bot}" "$_threads" "$_head_date")
  _diag_rc=$?
  set -e
  if [ "$_diag_rc" -ne 0 ]; then
    exit "$_diag_rc"
  fi
  printf '%s\n' "$_verdict"
  render_approval_diagnostic "$_verdict" >&2
fi
