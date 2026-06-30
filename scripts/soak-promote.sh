#!/usr/bin/env bash
set -euo pipefail
# soak-promote.sh — the autonomous fleet-wide soak-and-promote loop (#993),
# successor to the single-agent canary (#501). One idempotent, stateless pass:
# re-derive each reusable's frontier from its channel tags + run history, decide an
# action through the human overrides, rewrite live status, and (in `auto` mode)
# move the channel tag for any advance.
#
# Usage:
#   soak-promote.sh report [--registry F] [--control F] [--status-out F]   # default
#   soak-promote.sh auto   [--registry F] [--control F] [--status-out F]
#
#   report  — evaluate the whole fleet, write STATUS + job summary, mutate NOTHING
#             ("canary the canary": this is the mode the scheduled workflow ships in).
#   auto    — same, but additionally execute mutating actions (ADVANCE / FORCE /
#             ROLLBACK) by moving the channel tag(s).
#
# Truth is re-derived every run from channel tags + run history, so a missed or
# duplicated run is harmless.
#
# Env (override the defaults; used by the tests):
#   SOAK_REGISTRY     path to release/registry.yml
#   SOAK_CONTROL      path to release/control.yml
#   SOAK_STATUS_OUT   path to the committed live status file
#   SOAK_WINDOW_DAYS  default trailing health window (per-reusable gate.soak_window_days wins)
#   GITHUB_STEP_SUMMARY  if set, the evaluation table is appended for the run summary
#   GH_TOKEN / GH_PAT_WORKFLOWS  credential for gh (cross-repo + deployments)

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_ROOT="$(cd "${_HERE}/.." && pwd)"
# shellcheck source=lib/soak-promote.sh
source "${_HERE}/lib/soak-promote.sh"
# shellcheck source=lib/canary-rollout.sh
source "${_HERE}/lib/canary-rollout.sh"   # decide_gate, min_healthy_runs, failure_rate_permille

THIS_REPO="petry-projects/.github-private"
SOAK_REGISTRY="${SOAK_REGISTRY:-${_ROOT}/release/registry.yml}"
SOAK_CONTROL="${SOAK_CONTROL:-${_ROOT}/release/control.yml}"
SOAK_STATUS_OUT="${SOAK_STATUS_OUT:-${_ROOT}/release/STATUS.md}"

# ── registry / control readers (yq) ───────────────────────────────────────────
_reg() { yq -r "$1" "$SOAK_REGISTRY"; }
_ctl() { yq -r "$1" "$SOAK_CONTROL"; }

reusable_names() { _reg '.reusables | keys | .[]'; }

reusable_field() { _reg ".reusables.\"$1\".$2 // \"\""; }

ordered_channels() {
  _reg "(.reusables.\"$1\".rings // []) | sort_by(.order) | map(.channel) | join(\",\")"
}

# repos for one ring, with the host-relative tokens expanded ($host / $org_infra / *).
ring_repos() {
  local r="$1" channel="$2" host="$3" t
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
      '$host') printf '%s\n' "$host" ;;
      '$org_infra')
        while IFS= read -r o; do
          [ "$o" != "$host" ] && printf '%s\n' "$o"
        done < <(_reg '.org_infra_repos[]') ;;
      '*') printf '%s\n' '*' ;;
      *) printf '%s\n' "$t" ;;
    esac
  done < <(_reg "(.reusables.\"$r\".rings // [])[] | select(.channel==\"$channel\") | (.repos // [])[]")
  return 0
}

# ── tag resolution (this-repo via git; cross-repo via gh) ─────────────────────
channel_commit() {
  local r="$1" host="$2" channel="$3" tag="$1/$3"
  if [ "$host" = "$THIS_REPO" ]; then
    git rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null \
      || git rev-parse -q --verify "${tag}^{commit}" 2>/dev/null || true
  else
    gh api "repos/${host}/git/ref/tags/${tag}" --jq '.object.sha' 2>/dev/null || true
  fi
}

# version a candidate commit corresponds to (its <reusable>/vX.Y.Z release tag).
candidate_version() {
  local r="$1" host="$2" commit="$3"
  [ -z "$commit" ] && { echo ""; return 0; }
  if [ "$host" = "$THIS_REPO" ]; then
    git tag --points-at "$commit" -l "$r/v*" 2>/dev/null | head -1 | sed "s#^$r/v##"
  else
    echo ""   # cross-repo version lookup is best-effort; pin simply disabled if absent
  fi
}

# ── per-ring health → gate verdict (reuses the #501 decision core) ────────────
ring_health() {
  local wf="$1" window="$2"; shift 2
  local since healthy=0 fail=0 repo json
  if ! since="$(date -u -d "-${window} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
    if ! since="$(date -u -v"-${window}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
      since=""
    fi
  fi
  for repo in "$@"; do
    [ "$repo" = '*' ] && continue
    json="$(gh run list --repo "$repo" --workflow "$wf" ${since:+--created ">=$since"} \
              -L 300 --json conclusion 2>/dev/null || echo '[]')"
    healthy=$(( healthy + $(jq '[.[]?|select(.conclusion=="success")]|length' 2>/dev/null <<< "$json" || echo 0) ))
    fail=$(( fail + $(jq '[.[]?|select(.conclusion=="failure")]|length' 2>/dev/null <<< "$json" || echo 0) ))
  done
  echo "$healthy $fail $(( healthy + fail ))"
}

# frontier_state <reusable> — echo "<cand_commit> <cand_version> <advance_ring> <gate>".
# advance_ring is the first ring (from the soak-start) not yet on the candidate;
# empty when the whole ladder is aligned. gate is PROMOTE|SOAKING|INVESTIGATE for
# that advance_ring (empty when there is nothing to advance).
frontier_state() {
  local r="$1" host csv start window
  host="$(reusable_field "$r" host)"
  csv="$(ordered_channels "$r")"
  window="$(reusable_field "$r" gate.soak_window_days)"; window="${window:-${SOAK_WINDOW_DAYS:-7}}"
  start="$(reusable_field "$r" soak_start_ring)"

  local chans=(); IFS=, read -r -a chans <<< "$csv"
  [ -z "$start" ] && start="${chans[0]}"
  local start_idx; start_idx="$(ring_index "$start" "$csv" 2>/dev/null || echo 0)"

  local cand; cand="$(channel_commit "$r" "$host" "$start")"
  local cver; cver="$(candidate_version "$r" "$host" "$cand")"

  local advance="" evidence=() i
  for (( i=start_idx; i<${#chans[@]}; i++ )); do
    local ch="${chans[$i]}" c
    c="$(channel_commit "$r" "$host" "$ch")"
    if [ "$i" -eq "$start_idx" ] || [ "$c" = "$cand" ]; then
      evidence+=("$ch")
    else
      advance="$ch"; break
    fi
  done

  if [ -z "$advance" ]; then
    printf '%s|%s||\n' "$cand" "$cver"   # nothing to advance; advance+gate blank
    return 0
  fi

  # Evidence = rings already on the candidate; baseline = the ring we'd advance.
  local ev_repos=() base_repos=() ch r2
  for ch in "${evidence[@]}"; do
    while IFS= read -r r2; do ev_repos+=("$r2"); done < <(ring_repos "$r" "$ch" "$host")
  done
  while IFS= read -r r2; do base_repos+=("$r2"); done < <(ring_repos "$r" "$advance" "$host")

  local eh ef et _bh bf bt
  read -r eh ef et < <(ring_health "$(reusable_field "$r" run_workflow)" "$window" "${ev_repos[@]}")
  read -r _bh bf bt < <(ring_health "$(reusable_field "$r" run_workflow)" "$window" "${base_repos[@]}")
  local min_h cand_r base_r gate
  min_h="$(min_healthy_runs "$bt")"
  cand_r="$(failure_rate_permille "$ef" "$et")"
  base_r="$(failure_rate_permille "$bf" "$bt")"
  gate="$(decide_gate "$eh" "$min_h" "$cand_r" "$base_r")"
  printf '%s|%s|%s|%s\n' "$cand" "$cver" "$advance" "$gate"
}

# ── mutating ops (auto mode only) ─────────────────────────────────────────────
move_channel() {  # <reusable> <host> <channel> <commit>
  local r="$1" host="$2" channel="$3" commit="$4" tag="$1/$3"
  if [ "$host" = "$THIS_REPO" ]; then
    git tag -f "$tag" "$commit" >/dev/null
    git push --force origin "$tag"
  else
    # cross-repo: move the lightweight channel ref on the host repo via the API.
    if gh api "repos/${host}/git/ref/tags/${tag}" >/dev/null 2>&1; then
      gh api -X PATCH "repos/${host}/git/refs/tags/${tag}" -f "sha=${commit}" -F "force=true" >/dev/null
    else
      gh api -X POST "repos/${host}/git/refs" -f "ref=refs/tags/${tag}" -f "sha=${commit}" >/dev/null
    fi
  fi
}

record_deployment() {  # <reusable> <host> <ring> <version> <evidence_note>
  local r="$1" host="$2" ring="$3" version="$4" evidence_note="$5"
  gh api -X POST "repos/${host}/deployments" \
    -f "ref=${r}/${ring}" -f "environment=${ring}" -f "auto_merge=false" \
    -f "required_contexts=[]" \
    -f "description=soak-promote: ${r} v${version} → ${ring} (${evidence_note})" >/dev/null 2>&1 || true
}

# ── main loop ─────────────────────────────────────────────────────────────────
run() {
  local mode="$1"   # report | auto
  local paused; paused="$(_ctl '.pause // false')"

  local rows=()
  local r
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    local host; host="$(reusable_field "$r" host)"
    local cand cver advance gate
    IFS='|' read -r cand cver advance gate < <(frontier_state "$r")

    local hold pin force_ring rollback
    hold="$(_ctl ".reusables.\"$r\".hold_at // \"\"")"
    pin="$(_ctl ".reusables.\"$r\".pin // \"\"")"
    force_ring="$(_ctl ".reusables.\"$r\".force.ring // \"\"")"
    rollback="$(_ctl ".reusables.\"$r\".rollback // \"\"")"

    local action
    action="$(plan_action "$paused" "$rollback" "$force_ring" "$advance" \
                          "$hold" "$pin" "$cver" "$gate" "$(ordered_channels "$r")")"

    rows+=("$(status_row "$r" "${advance:-—}" "${cver:-—}" "${gate:-—}" "$action")")
    printf '  %-22s frontier=%-7s cand=%-9s gate=%-12s -> %s\n' \
      "$r" "${advance:-—}" "${cver:-—}" "${gate:-—}" "$action"

    [ "$mode" = "auto" ] && apply_action "$r" "$host" "$cand" "$cver" "$action"
  done < <(reusable_names)

  write_status "$mode" "${rows[@]}"
}

# apply_action — execute a mutating action in auto mode. report mode never calls this.
apply_action() {
  local r="$1" host="$2" cand="$3" cver="$4" action="$5"
  local verb arg; verb="${action%% *}"; arg="${action#* }"
  case "$verb" in
    ADVANCE|FORCE)
      [ -z "$cand" ] && { echo "::warning::$r: no candidate commit — skipping $verb"; return 0; }
      echo "::notice::$r: moving $r/$arg -> ${cand:0:12} ($verb)"
      move_channel "$r" "$host" "$arg" "$cand"
      record_deployment "$r" "$host" "$arg" "$cver" "$verb"
      ;;
    ROLLBACK)
      _rollback_reusable "$r" "$host" "$arg"
      ;;
    *) : ;;   # PAUSED/COMPLETE/HALT/PINNED/HOLD/WAIT are non-mutating
  esac
}

# Reset every channel currently on the candidate back to the named release — the
# "rollback is free" path (immutable vX.Y.Z tags are the rollback targets).
_rollback_reusable() {
  local r="$1" host="$2" version="$3" target csv ch c
  if [ "$host" = "$THIS_REPO" ]; then
    target="$(git rev-parse -q --verify "refs/tags/$r/v$version^{commit}" 2>/dev/null || true)"
  else
    target="$(gh api "repos/${host}/git/ref/tags/$r/v$version" --jq '.object.sha' 2>/dev/null || true)"
  fi
  [ -z "$target" ] && { echo "::error::$r: rollback target $r/v$version not found"; return 0; }
  local cand; cand="$(channel_commit "$r" "$host" "$(ordered_channels "$r" | cut -d, -f1)")"
  csv="$(ordered_channels "$r")"
  local -a channels
  IFS=, read -r -a channels <<< "$csv"
  for ch in "${channels[@]}"; do
    c="$(channel_commit "$r" "$host" "$ch")"
    if [ -n "$cand" ] && [ "$c" = "$cand" ]; then
      echo "::notice::$r: rollback $r/$ch -> v$version (${target:0:12})"
      move_channel "$r" "$host" "$ch" "$target"
    fi
  done
}

write_status() {
  local mode="$1"; shift
  local rows=("$@")
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo "# Soak-and-Promote — Fleet Status"
    echo
    echo "_Generated ${now} by \`scripts/soak-promote.sh ${mode}\` (#993). Re-derived every run from channel tags + run history._"
    echo
    echo "| Reusable | Frontier (next ring) | Candidate | Gate | Action |"
    echo "| --- | --- | --- | --- | --- |"
    local row
    for row in "${rows[@]}"; do echo "$row"; done
  } > "$SOAK_STATUS_OUT"
  echo "wrote $SOAK_STATUS_OUT"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Soak-and-Promote (${mode})"
      echo "| Reusable | Frontier | Candidate | Gate | Action |"
      echo "| --- | --- | --- | --- | --- |"
      local row
      for row in "${rows[@]}"; do echo "$row"; done
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

main() {
  local cmd
  for cmd in yq jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "::error::required command '$cmd' not found" >&2; return 1; }
  done
  local mode="${1:-report}"; shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --registry)
        if [ "$#" -lt 2 ]; then echo "::error::--registry requires an argument" >&2; return 2; fi
        SOAK_REGISTRY="$2"; shift 2 ;;
      --control)
        if [ "$#" -lt 2 ]; then echo "::error::--control requires an argument" >&2; return 2; fi
        SOAK_CONTROL="$2"; shift 2 ;;
      --status-out)
        if [ "$#" -lt 2 ]; then echo "::error::--status-out requires an argument" >&2; return 2; fi
        SOAK_STATUS_OUT="$2"; shift 2 ;;
      *) echo "::error::unknown argument: $1" >&2; return 2 ;;
    esac
  done
  case "$mode" in
    report|auto) run "$mode" ;;
    *) echo "::error::usage: soak-promote.sh {report|auto} [--registry F] [--control F] [--status-out F]" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
