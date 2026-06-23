#!/usr/bin/env bash
set -euo pipefail
# canary-rollout.sh — ring-staged, health-gated promotion of agent releases by
# moving channel tags only (initiative #495, issue #501; rollback/observability #502).
#
# The ONLY action this performs is moving a channel tag (`git tag -f <agent>/<ring>
# <vX.Y.Z-commit> && git push -f`) — it never writes consumer files. A ring advances
# only when the rings already on the candidate pass the soak/health gate (see
# scripts/lib/canary-rollout.sh for the pure decision core).
#
# Channel tags ARE the rollout state (#502): the frontier is derived from where each
# channel tag resolves; there is no separate state store.
#
# Usage:
#   canary-rollout.sh evaluate <agent>                 # read-only gate + health report (also the #502 report)
#   canary-rollout.sh promote  <agent> [--override] [--dry-run]
#   canary-rollout.sh rollback <agent> <ring> --to <vX.Y.Z> [--dry-run]
#   canary-rollout.sh resolve  <agent> <channel>       # debug: print resolved member repos
#
# Env:
#   CANARY_RINGS        path to ring SoT (default: standards/canary-rings.json next to this repo)
#   SOAK_WINDOW_DAYS    trailing window for the health gate (default 7)
#   GH_TOKEN / GH_PAT_WORKFLOWS   credential; the workflow passes GH_PAT_WORKFLOWS as the mover

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/canary-rollout.sh
source "${_HERE}/lib/canary-rollout.sh"
DEFAULT_RINGS="$(cd "${_HERE}/.." && pwd)/standards/canary-rings.json"
CANARY_RINGS="${CANARY_RINGS:-$DEFAULT_RINGS}"

_jq()  { jq "$@" "$CANARY_RINGS"; }
_agent_field() { _jq -r --arg a "$1" ".agents[\$a].$2"; }

# ordered_channels <agent> — e.g. "next,ring0,ring1,stable"
ordered_channels() {
  _jq -r --arg a "$1" '.agents[$a].rings | sort_by(.order) | map(.channel) | join(",")'
}

# resolve_members <agent> <channel> — print the member repos, expanding the
# host-relative tokens $host / $org_infra / * (one repo per line).
resolve_members() {
  local agent="$1" channel="$2" host t r
  host="$(_agent_field "$agent" host)"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
      '$host') printf '%s\n' "$host" ;;
      '$org_infra')
        while IFS= read -r r; do
          if [ "$r" != "$host" ]; then printf '%s\n' "$r"; fi
        done < <(_jq -r '.org_infra_repos[]') ;;
      '*') printf '%s\n' '*' ;;
      *) printf '%s\n' "$t" ;;
    esac
  done < <(_jq -r --arg a "$agent" --arg c "$channel" \
            '.agents[$a].rings[] | select(.channel==$c) | .members[]')
  return 0
}

# channel_commit <agent> <channel> — commit a channel tag resolves to (short-circuits
# to empty if the tag does not exist).
channel_commit() {
  git rev-parse -q --verify "refs/tags/$1/$2^{commit}" 2>/dev/null \
    || git rev-parse -q --verify "$1/$2^{commit}" 2>/dev/null || true
}

# ring_health <agent> <repo...> — aggregate run health over the trailing soak window
# across the given member repos. Prints "<healthy> <failures> <total>" where healthy =
# success, failures = failure, total = healthy+failures (skipped/cancelled are noise,
# excluded — consistent with the canary classification in #781).
ring_health() {
  local agent="$1"; shift
  local wf since healthy=0 fail=0 repo json
  wf="$(_agent_field "$agent" run_workflow)"
  if ! since="$(date -u -d "-${SOAK_WINDOW_DAYS:-7} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
    since="$(date -u -v"-${SOAK_WINDOW_DAYS:-7}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  fi
  for repo in "$@"; do
    [ "$repo" = '*' ] && continue
    json="$(gh run list --repo "$repo" --workflow "$wf" ${since:+--created ">=$since"} \
              -L 300 --json conclusion 2>/dev/null || echo '[]')"
    healthy=$(( healthy + $(printf '%s' "$json" | jq '[.[]|select(.conclusion=="success")]|length' 2>/dev/null || echo 0) ))
    fail=$(( fail + $(printf '%s' "$json" | jq '[.[]|select(.conclusion=="failure")]|length' 2>/dev/null || echo 0) ))
  done
  echo "$healthy $fail $(( healthy + fail ))"
}

# _frontier_state <agent> — compute the rollout frontier and gate, echoing:
#   "<candidate_commit> <frontier_channel> <state> <healthy> <min_healthy> <cand‰> <base‰>"
# frontier = first ring (after next) not yet on the candidate commit.
_frontier_state() {
  local agent="$1"
  local cand chans frontier="" prev_on=()
  cand="$(channel_commit "$agent" next)"
  chans="$(ordered_channels "$agent")"

  # Collect the rings already on the candidate (starting at next) and find the frontier.
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$chans"
  local ch
  for ch in "${chan_array[@]}"; do
    local c; c="$(channel_commit "$agent" "$ch")"
    if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then
      prev_on+=("$ch")
    else
      frontier="$ch"; break
    fi
  done

  if [ -z "$frontier" ]; then
    echo "$cand  -  COMPLETE 0 0 0 0"; return 0
  fi

  # Health of the rings already on the candidate (the evidence), vs the frontier ring's
  # current (prior-version) volume/quality as the baseline.
  local repos=() ch2
  for ch2 in "${prev_on[@]}"; do
    while IFS= read -r r; do repos+=("$r"); done < <(resolve_members "$agent" "$ch2")
  done
  read -r ch_healthy ch_fail ch_total < <(ring_health "$agent" "${repos[@]}")

  local base_repos=()
  while IFS= read -r r; do base_repos+=("$r"); done < <(resolve_members "$agent" "$frontier")
  read -r _base_healthy base_fail base_total < <(ring_health "$agent" "${base_repos[@]}")

  local min_healthy cand_rate base_rate state
  min_healthy="$(min_healthy_runs "$base_total")"
  cand_rate="$(failure_rate_permille "$ch_fail" "$ch_total")"
  base_rate="$(failure_rate_permille "$base_fail" "$base_total")"
  state="$(decide_gate "$ch_healthy" "$min_healthy" "$cand_rate" "$base_rate")"
  echo "$cand $frontier $state $ch_healthy $min_healthy $cand_rate $base_rate"
}

cmd_evaluate() {
  local agent="$1"
  echo "== canary-rollout evaluate: $agent (soak window ${SOAK_WINDOW_DAYS:-7}d) =="
  local cand; cand="$(channel_commit "$agent" next)"
  echo "candidate (next) = ${cand:0:12}"
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  local ch
  for ch in "${chan_array[@]}"; do
    local c; c="$(channel_commit "$agent" "$ch")"
    local mark="  "; [ -n "$cand" ] && [ "$c" = "$cand" ] && mark="* "
    printf '  %s%-7s -> %s\n' "$mark" "$ch" "${c:0:12}"
  done
  read -r _cand frontier state healthy min_h cand_r base_r < <(_frontier_state "$agent")
  echo "----"
  if [ "$frontier" = "-" ]; then
    echo "frontier: none — fully rolled out (all rings on candidate)."
  else
    gate_summary_line "$frontier" "$state" "$healthy" "$min_h" "$cand_r" "$base_r"
    echo "decision for next ring '$frontier': $state"
  fi
}

cmd_promote() {
  local agent="$1"; shift
  local override=false dry=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --override) override=true ;;
      --dry-run)  dry=true ;;
      *) echo "::error::unknown promote flag: $1" >&2; return 2 ;;
    esac; shift
  done
  read -r cand frontier state _healthy _min _cr _br < <(_frontier_state "$agent")
  if [ "$frontier" = "-" ]; then
    echo "nothing to promote — $agent is fully rolled out."; return 0
  fi
  if [ "$state" != "PROMOTE" ] && [ "$override" != true ]; then
    echo "gate=$state for ring '$frontier' — not promoting. (use --override to force; investigate first if INVESTIGATE)"
    return 0
  fi
  [ "$override" = true ] && [ "$state" != "PROMOTE" ] && echo "::warning::overriding gate state '$state' for $agent/$frontier"
  echo "advancing $agent/$frontier -> ${cand:0:12}"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: git tag -f $agent/$frontier $cand && git push --force origin $agent/$frontier"
    return 0
  fi
  git tag -f "$agent/$frontier" "$cand"
  git push --force origin "$agent/$frontier"
  echo "promoted $agent/$frontier -> ${cand:0:12}"
}

cmd_rollback() {
  local agent="$1" ring="$2"; shift 2
  local to="" dry=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)
        if [ $# -lt 2 ]; then echo "::error::--to requires a value" >&2; return 2; fi
        to="$2"; shift
        ;;
      --dry-run) dry=true ;;
      *) echo "::error::unknown rollback flag: $1" >&2; return 2 ;;
    esac; shift
  done
  [ -z "$to" ] && { echo "::error::rollback requires --to <vX.Y.Z>" >&2; return 2; }
  local target; target="$(git rev-parse -q --verify "refs/tags/$agent/$to^{commit}" 2>/dev/null || true)"
  [ -z "$target" ] && { echo "::error::release tag $agent/$to not found" >&2; return 1; }
  echo "rolling back $agent/$ring -> $to (${target:0:12})"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: git tag -f $agent/$ring $target && git push --force origin $agent/$ring"
    return 0
  fi
  git tag -f "$agent/$ring" "$target"
  git push --force origin "$agent/$ring"
  echo "rolled back $agent/$ring -> $to"
}

main() {
  local cmd
  for cmd in jq gh git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "::error::Required command '$cmd' is not installed." >&2
      return 1
    fi
  done
  if ! [[ "${SOAK_WINDOW_DAYS:-7}" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::SOAK_WINDOW_DAYS must be a positive integer" >&2
    return 2
  fi
  local sub="${1:-}"; shift || true
  case "$sub" in
    evaluate) [ $# -ge 1 ] || { echo "usage: evaluate <agent>" >&2; return 2; }; cmd_evaluate "$@" ;;
    promote)  [ $# -ge 1 ] || { echo "usage: promote <agent> [--override] [--dry-run]" >&2; return 2; }; cmd_promote "$@" ;;
    rollback) [ $# -ge 2 ] || { echo "usage: rollback <agent> <ring> --to <vX.Y.Z>" >&2; return 2; }; cmd_rollback "$@" ;;
    resolve)  [ $# -ge 2 ] || { echo "usage: resolve <agent> <channel>" >&2; return 2; }; resolve_members "$@" ;;
    *) echo "::error::usage: canary-rollout.sh {evaluate|promote|rollback|resolve} <agent> ..." >&2; return 2 ;;
  esac
}

# Source-guard: tests source this file to exercise resolve_members etc. without running.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
