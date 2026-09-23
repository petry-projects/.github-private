#!/usr/bin/env bash
set -euo pipefail
# persona-pr-pregate.sh — the persona event pre-gate the shared runtime consults
# before running the engine (issue #1905).
#
# The mention router serves qa-lead's pull_request advisory by dispatching
# repository_dispatch:persona-mention with client_payload.surface=pull_request
# into .github/workflows/persona-runner-reusable.yml. The router binds the
# GENERIC brakes (stop markers, opt-out label, write-gate, trust floor, recursion
# axes, declared events); it does NOT carry the PERSONA-SPECIFIC suppressors the
# local qa-lead-pr-advisory.yml gate enforces (no-test-surface, budget-exhausted,
# already-advised). Without this pre-gate the runner posts on EVERY trusted PR.
#
# persona_event_pregate is what the runner calls after resolving the persona and
# BEFORE the engine:
#   * surface == mention (or absent -> mention): "run", no gate. Existing mention
#     dispatches are unchanged (AC #1).
#   * an unrecognized surface: fail closed (skip) — malformed dispatch data must
#     not be treated as a mention and bypass the pull_request suppressors.
#   * surface == pull_request + a persona with a registered pre-gate (qa-lead):
#     run that gate — the ONE shared gather+decide (AC #2).
#   * surface == pull_request + a persona with NO registered pre-gate: the generic
#     already-advised marker check only, logging that no persona gate exists (AC #3).
#   * any unreadable signal: fail closed (skip) with a ::error naming it (AC #3).
#
# Prints exactly one decision line on stdout: "run" or "skip:<reason>". Returns 0
# for run, 1 for skip. Diagnostics (::error/::notice) go to stderr.

_PERSONA_PREGATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/qa-lead-pr-gate.sh
source "${_PERSONA_PREGATE_DIR}/qa-lead-pr-gate.sh"
# shellcheck source=scripts/lib/persona-runner.sh
source "${_PERSONA_PREGATE_DIR}/lib/persona-runner.sh"

# persona_generic_already_advised_gate <persona> <repo> <item>
#   The fallback pull_request pre-gate for a persona with no registered
#   suppressor set: the generic idempotency check only. Scans the item's comment
#   stream for the persona's recursion marker; an existing marker means an
#   advisory already landed -> skip. Fails closed on an unreadable comment stream.
persona_generic_already_advised_gate() {
  local persona="$1" repo="$2" item="$3" marker bodies
  marker="$(pr_agent_marker "$persona")"
  if ! bodies="$(gh api --paginate \
      "repos/${repo}/issues/${item}/comments" --jq '.[].body')"; then
    echo "::error::persona pull_request pre-gate: existing-advisory scan unavailable for ${repo}#${item} — failing closed (skip)" >&2
    printf 'skip:signal-unavailable\n'
    return 1
  fi
  if grep -qF "$marker" <<< "$bodies"; then
    printf 'skip:already-advised\n'
    return 1
  fi
  printf 'run\n'
}

# persona_event_pregate <persona> <surface> <repo> <item> [event_action]
#   The single entry point the runner calls. See the header for the dispatch.
persona_event_pregate() {
  local persona="$1" surface="${2:-mention}" repo="$3" item="$4"
  # event_action ($5) is forwarded for parity with the router payload and future
  # per-persona gates; the qa-lead decision does not consider it (the surface's
  # declared events are bound by the router, per ADR-0009).

  # Recognized surfaces ONLY. A mention (or absent -> mention, via the default
  # above) is unchanged: the pre-gate is a pull_request-only concern (AC #1). A
  # pull_request surface falls through to the persona gate below. Any OTHER value
  # is malformed dispatch data — fail CLOSED (skip) rather than treat an
  # unrecognized surface as a mention, which would bypass every pull_request
  # suppressor.
  case "$surface" in
    mention)
      printf 'run\n'
      return 0
      ;;
    pull_request) ;;
    *)
      echo "::error::persona event pre-gate: unrecognized surface '${surface}' for ${repo}#${item} — failing closed (skip)" >&2
      printf 'skip:unknown-surface\n'
      return 1
      ;;
  esac

  case "$persona" in
    qa-lead)
      qa_lead_pr_gather_and_decide "$repo" "$item"
      ;;
    *)
      echo "::notice::no persona-specific pull_request pre-gate registered for '${persona}' — applying only the generic already-advised marker check" >&2
      persona_generic_already_advised_gate "$persona" "$repo" "$item"
      ;;
  esac
}

# Allow direct CLI use for debugging: persona-pr-pregate.sh <persona> <surface> …
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  persona_event_pregate "$@"
fi
