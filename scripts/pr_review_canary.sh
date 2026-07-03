#!/usr/bin/env bash
# pr_review_canary.sh — post-merge / scheduled canary for the pr-review-trigger
# stub (#1052, Part D). Turns the silent post-merge breakage of #1034 into a
# gating signal.
#
# #1034 broke EVERY pr-review with `startup_failure` and no PR was reviewed until
# the #1048 hotfix, because a channel-pinned caller stub's `with:` forward is
# exercised by nothing in PR CI — GitHub validates the caller's inputs against
# the reusable AT THE PINNED REF only at startup, so the mismatch surfaces only
# on the first real run on main. This canary reproduces exactly the manual
# dry-run used to verify #1048's recovery: it fires a DRY-RUN dispatch of
# pr-review-trigger.yml (`dry_run=true`, which never submits reviews/comments)
# and FAILS LOUD if the run ends in `startup_failure` (or otherwise fails).
#
# Layout mirrors scripts/initiative_canary.sh:
#   * classify_canary_run / canary_is_failure / canary_report are PURE — they
#     take scalars and write stdout. Unit-tested in tests/pr_review_canary.bats.
#   * main() does the network I/O: dispatch, poll, classify.
#
# Env vars consumed:
#   REPO                 owner/repo hosting the trigger (default petry-projects/.github-private)
#   WORKFLOW_FILE        trigger workflow to dispatch (default pr-review-trigger.yml)
#   GH_TOKEN             a PAT with workflow scope (a workflow_dispatch fired with
#                        GITHUB_TOKEN is accepted but never starts a run)
#   CANARY_POLL_TIMEOUT  seconds to wait for the run to complete (default 600)
#   CANARY_POLL_INTERVAL seconds between polls (default 15)
#   CANARY_OUT           optional path; the report is written there in addition to stdout

set -euo pipefail

REPO="${REPO:-petry-projects/.github-private}"
WORKFLOW_FILE="${WORKFLOW_FILE:-pr-review-trigger.yml}"

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network)
# ---------------------------------------------------------------------------

# classify_canary_run <conclusion>
# Maps a completed run's conclusion to a canary status:
#   STARTUP_FAILURE — conclusion == startup_failure (the #1034 fingerprint: the
#                     reusable call could not even start because the caller's
#                     forwarded inputs did not match the reusable at the pin)
#   OK              — conclusion == success
#   NO_RUN          — empty/null conclusion (no completed run was found)
#   FAILED          — any other conclusion (failure/timed_out/cancelled/…)
classify_canary_run() {
  local conclusion="${1:-}"
  case "$conclusion" in
    startup_failure) echo "STARTUP_FAILURE" ;;
    success)         echo "OK" ;;
    ""|null)         echo "NO_RUN" ;;
    *)               echo "FAILED" ;;
  esac
}

# canary_is_failure <status>
# Exit 0 (alert) for any status other than OK; exit 1 for OK.
canary_is_failure() {
  [ "${1:-}" != "OK" ]
}

# canary_report <status> <repo> <run_url> [today]
# Writes a Markdown alert/health body to stdout. Pure: no network.
canary_report() {
  local st="${1:-}" repo="${2:-}" run_url="${3:-}" today="${4:-}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local icon headline
  case "$st" in
    OK)              icon='✅'; headline='canary passed — dry-run review started cleanly' ;;
    STARTUP_FAILURE) icon='🔴'; headline='REGRESSION — pr-review-trigger ended in startup_failure (#1034 class)' ;;
    NO_RUN)          icon='🟠'; headline='no pr-review-trigger run observed within the poll window' ;;
    *)               icon='🔴'; headline='pr-review-trigger dry-run failed' ;;
  esac

  printf '# %s PR-review-trigger canary — %s\n\n' "$icon" "$today"
  printf '_Repo `%s` · dry-run dispatch of `%s` · gates on `startup_failure` (the #1034 breakage)_\n\n' \
    "$repo" "$WORKFLOW_FILE"
  printf -- '- **Result:** %s — %s\n' "$st" "$headline"
  printf -- '- **Mode:** dry-run dispatch (`dry_run=true`) — never submits reviews or comments\n'
  [ -n "$run_url" ] && printf -- '- **Run:** %s\n' "$run_url"
  printf '\n'

  if [ "$st" = "STARTUP_FAILURE" ]; then
    printf '> The trigger run ended in `startup_failure` — the reusable call could not start. '
    printf 'This is the #1034 breakage: the channel-pinned caller stub forwards a `with:` input '
    printf 'the reusable does not declare at the pinned ref (or a required input is missing). '
    printf 'Fix the forwarding or advance the pinned channel to a commit that declares the input, '
    printf 'per AGENTS.md "Caller-stub input forwarding across channel pins".\n'
  elif [ "$st" = "NO_RUN" ]; then
    printf '> No `workflow_dispatch` trigger run completed within the poll window. '
    printf 'The dispatch may have been rejected (PAT missing/expired) or the run is still queued.\n'
  elif [ "$st" != "OK" ]; then
    printf '> The dry-run trigger dispatch did not conclude successfully — inspect the run log.\n'
  fi
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

main() {
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::error::GH_TOKEN is required — a workflow_dispatch fired with GITHUB_TOKEN will not start a run." >&2
    exit 1
  fi

  local timeout="${CANARY_POLL_TIMEOUT:-600}"
  local interval="${CANARY_POLL_INTERVAL:-15}"
  local today dispatch_ts dispatch_epoch
  today="$(date -u +%Y-%m-%d)"
  # Subtract a 60-second buffer to account for clock drift between runner and GitHub.
  dispatch_epoch=$(( $(date +%s) - 60 ))
  dispatch_ts="$(date -u -d "@${dispatch_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${dispatch_epoch}" +%Y-%m-%dT%H:%M:%SZ)"

  echo "=== PR-review-trigger canary ===" >&2
  echo "  Repo:     $REPO" >&2
  echo "  Workflow: $WORKFLOW_FILE (dry-run)" >&2

  # Fire the DRY-RUN dispatch. dry_run=true guarantees no review/comment is ever
  # submitted; we only care whether the reusable call can START.
  local ref_flags=()
  if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" == refs/heads/* || "$GITHUB_REF" == refs/tags/* ) ]]; then
    ref_flags=(--ref "$GITHUB_REF")
  fi
  gh workflow run "$WORKFLOW_FILE" --repo "$REPO" "${ref_flags[@]}" \
    -f dry_run=true

  # Poll for the workflow_dispatch run created after our dispatch timestamp.
  local deadline run_id="" conclusion="" run_status=""
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local row
    row="$(gh run list --repo "$REPO" --workflow "$WORKFLOW_FILE" \
      --event workflow_dispatch --created ">=${dispatch_ts}" --limit 20 \
      --json databaseId,status,conclusion,createdAt \
      --jq 'sort_by(.createdAt) | reverse | .[0] // {} |
            [(.databaseId // "" | tostring), (.status // ""), (.conclusion // "")] | @tsv' \
      2>/dev/null || true)"
    IFS=$'\t' read -r run_id run_status conclusion <<< "$row"
    [ "$run_status" = "completed" ] && break
    sleep "$interval"
  done

  local result
  result="$(classify_canary_run "$conclusion")"

  local run_url=""
  [ -n "$run_id" ] && run_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${run_id}"

  local report
  report="$(canary_report "$result" "$REPO" "$run_url" "$today")"
  printf '%s\n' "$report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "${CANARY_OUT:-}" ]; then
    printf '%s\n' "$report" > "$CANARY_OUT"
  fi

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "CANARY_STATUS=${result}" >> "$GITHUB_ENV"
  fi

  if canary_is_failure "$result"; then
    [ -n "${GITHUB_ENV:-}" ] && echo "CANARY_FAILED=true" >> "$GITHUB_ENV"
    echo "::error::PR-review-trigger canary result: ${result}" >&2
    exit 1
  fi
  echo "::notice::PR-review-trigger canary passed (dry-run dispatch started and concluded success)." >&2
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
