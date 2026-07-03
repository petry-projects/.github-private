#!/usr/bin/env bash
set -euo pipefail
# canary_agent_options.sh — single source of truth for the canary-rollout.yml
# `agent` workflow_dispatch choice options (issue #1045).
#
# GitHub `workflow_dispatch` choice inputs must be a STATIC list — they cannot be
# computed from a file at dispatch time. Before #1045 that list was hardcoded to
# `[dev-lead]`, so `gh workflow run canary-rollout.yml -f agent=auto-rebase`
# returned HTTP 422 and the 6 #482 reusables could never be promoted.
#
# This script makes the list registry-derived so it never goes stale:
#   list  (default)   emit the canonical option list (every agent in canary-rings.json,
#                     LC_ALL=C sorted) — one per line. Regenerate the workflow from this.
#   check <workflow>  fail (exit 1) if the workflow's `agent` input options drift from
#                     the registry. The lint/bats drift gate calls this.
#
# Env:
#   CANARY_RINGS  path to the ring SoT (default: standards/canary-rings.json next to this repo)

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEFAULT_RINGS="$(cd "${_HERE}/.." && pwd)/standards/canary-rings.json"
CANARY_RINGS="${CANARY_RINGS:-$DEFAULT_RINGS}"

# registry_agents — the canonical option list: every agent key, LC_ALL=C sorted.
registry_agents() {
  jq -r '.agents | keys[]' "$CANARY_RINGS" | LC_ALL=C sort
}

# workflow_agent_options <workflow.yml> — the option tokens of the `agent:` input's
# `options: [ ... ]` flow sequence, one per line, LC_ALL=C sorted. Reads the first
# `options:` line at or after the `agent:` key (the `command:` input is declared
# earlier in the file, so its options are never the first match after `agent:`).
workflow_agent_options() {
  awk '
    $1 == "agent:" { found = 1 }
    found && /options:[[:space:]]*\[/ {
      if (match($0, /\[[^]]*\]/)) {
        seq = substr($0, RSTART + 1, RLENGTH - 2)
        n = split(seq, a, ",")
        for (i = 1; i <= n; i++) { gsub(/[[:space:]]/, "", a[i]); if (a[i] != "") print a[i] }
      }
      exit
    }
  ' "$1" | LC_ALL=C sort
}

cmd_check() {
  local wf="$1"
  [ -n "$wf" ] || { echo "::error::check requires a workflow file path" >&2; return 2; }
  [ -f "$wf" ] || { echo "::error::workflow file not found: $wf" >&2; return 2; }
  local want got
  want="$(registry_agents)"
  got="$(workflow_agent_options "$wf")"
  if [ "$want" = "$got" ]; then
    echo "OK: ${wf##*/} agent options match canary-rings.json ($(printf '%s' "$want" | tr '\n' ' '))"
    return 0
  fi
  echo "::error::DRIFT — ${wf##*/} 'agent' dispatch options do not match canary-rings.json." >&2
  echo "  registry agents : $(printf '%s' "$want" | tr '\n' ' ')" >&2
  echo "  workflow options: $(printf '%s' "$got" | tr '\n' ' ')" >&2
  echo "  Regenerate with: scripts/canary_agent_options.sh list" >&2
  return 1
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "::error::Required command 'jq' is not installed." >&2
    return 1
  fi
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)  registry_agents ;;
    check) cmd_check "${1:-}" ;;
    *) echo "::error::usage: canary_agent_options.sh {list|check <workflow.yml>}" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
