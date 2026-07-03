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
#   canary-rollout.sh evaluate     <agent>             # read-only gate + health report (also the #502 report)
#   canary-rollout.sh evaluate-all                     # read-only evaluate for EVERY registry agent (fleet-wide; the 4h timer)
#   canary-rollout.sh promote  <agent> [--override] [--allow-pre-existing] [--dry-run]
#   canary-rollout.sh promote-all [--override] [--allow-pre-existing] [--dry-run]  # gated fleet auto-promote (the SCHEDULED arm, #1045b)
#   canary-rollout.sh rollback <agent> <ring> --to <vX.Y.Z> [--dry-run]
#   canary-rollout.sh resolve  <agent> <channel>       # debug: print resolved member repos
#
# Gate standard: .github#548 — graduated per-transition dwell/sample floors over a
# per-candidate cumulative window (since the candidate's OWN vX.Y.Z cut), a robust
# spike-capped baseline for the sample target, the ring0->ring1 sample waiver, and
# candidate-regression-vs-environmental failure triage. Knobs live in the ring SoT
# under .agents[<agent>].gate (see scripts/lib/canary-rollout.sh for the pure core).
#
# Env:
#   CANARY_RINGS        path to ring SoT (default: standards/canary-rings.json next to this repo)
#   SOAK_WINDOW_DAYS    optional override of the baseline-window length in days
#                       (default: .gate.baseline_window_days, else 14)
#   CANARY_FAILURE_CATEGORY  optional triage hint (comment-cap|rate-limit|infra|data)
#   GH_TOKEN            credential; the workflow mints a GitHub App token and passes it here

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/canary-rollout.sh
source "${_HERE}/lib/canary-rollout.sh"
DEFAULT_RINGS="$(cd "${_HERE}/.." && pwd)/standards/canary-rings.json"
CANARY_RINGS="${CANARY_RINGS:-$DEFAULT_RINGS}"

# THIS_REPO — the repo this checkout belongs to. Agents hosted HERE (dev-lead, pr-review)
# keep their channel/release tags in this checkout and resolve them via local git. A
# cross-repo agent (host != THIS_REPO, e.g. the #482 reusables hosted in petry-projects/
# .github) keeps its <name>/<channel> and <name>/vX.Y.Z tags on ITS host, so those tags
# must be resolved there via `gh api` — reading local refs resolves empty and the frontier
# falsely reports "fully rolled out" (#1049). Mirrors cut-release.sh's CROSS_REPO_TARGET.
THIS_REPO="${GITHUB_REPOSITORY:-petry-projects/.github-private}"

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

# _gh_tag_commit <repo> <tag> — echo the COMMIT sha <tag> resolves to on <repo> via the
# GitHub API, dereferencing an annotated tag object (mirrors cut-release.sh's
# gh_release_commit). Empty on any error / absent tag (never fails the caller).
_gh_tag_commit() {
  local repo="$1" tag="$2" ref_info obj type
  ref_info="$(gh api "repos/$repo/git/ref/tags/$tag" --jq '[(.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>/dev/null)" || return 0
  [ -z "$ref_info" ] && return 0
  read -r obj type <<< "$ref_info"
  if [ "$type" = "tag" ]; then
    gh api "repos/$repo/git/tags/$obj" --jq '(.object?.sha // "" | tostring)' 2>/dev/null || true
  else
    printf '%s\n' "$obj"
  fi
}

# _gh_move_tag <repo> <tag> <sha> — force-move (or create) the lightweight ref
# refs/tags/<tag> on <repo> to <sha> via the GitHub API. The cross-repo counterpart of
# `git tag -f <tag> <sha> && git push --force`: a cross-repo agent's channel tags live on
# ITS host, so the promote/rollback move must go through gh api, not local git — local
# `git tag -f` fails with "nonexistent object" for a host commit absent from this checkout
# (#1054). Tries PATCH (existing ref) then falls back to POST (create the ref).
_gh_move_tag() {
  local repo="$1" tag="$2" sha="$3"
  gh api -X PATCH "repos/$repo/git/refs/tags/$tag" \
      -f sha="$sha" -F force=true >/dev/null 2>&1 && return 0
  gh api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$sha" >/dev/null 2>&1
}

# channel_commit <agent> <channel> — commit the channel tag <agent>/<channel> resolves to
# (empty if the tag does not exist). Agents hosted in THIS repo resolve against the local
# checkout; a cross-repo agent's channel tags live on ITS host, so they are resolved there
# via the GitHub API — reading local refs resolves empty and the frontier falsely reports
# "fully rolled out" (#1049).
channel_commit() {
  local agent="$1" channel="$2" host
  host="$(_agent_field "$agent" host)"
  if [ -n "$host" ] && [ "$host" != "$THIS_REPO" ]; then
    _gh_tag_commit "$host" "$agent/$channel"
    return 0
  fi
  git rev-parse -q --verify "refs/tags/$agent/$channel^{commit}" 2>/dev/null \
    || git rev-parse -q --verify "$agent/$channel^{commit}" 2>/dev/null || true
}

# _gate_field <agent> <field> — read .agents[a].gate.<field> (empty if absent).
_gate_field() { _jq -r --arg a "$1" --arg f "$2" '.agents[$a].gate[$f] // empty'; }
# _gate_knob <agent> <transition_key> <field> — read a per-transition knob (empty if absent).
_gate_knob() { _jq -r --arg a "$1" --arg t "$2" --arg f "$3" '.agents[$a].gate.transitions[$t][$f] // empty'; }

# _iso_now_minus_days <ndays> — ISO-8601 Zulu timestamp n days ago (GNU or BSD date).
_iso_now_minus_days() {
  date -u -d "-${1} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v"-${1}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}
_to_z() {   # normalise any parseable timestamp to ISO-8601 Zulu (empty passes through)
  [ -z "${1:-}" ] && { echo ""; return 0; }
  date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "$1"
}
_epoch() {
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -v "$1" +%s 2>/dev/null \
    || echo 0
}

# _gh_candidate_cut_date <repo> <agent> <commit> — ISO-8601 Zulu tagger date of the
# release tag <agent>/vX.Y.Z on <repo> whose (dereferenced) commit equals <commit>. The
# cross-repo analogue of the local for-each-ref path: a cross-repo agent's release tags
# live on its host, not this checkout (#1049). Empty if no matching release tag is found.
_gh_candidate_cut_date() {
  local repo="$1" agent="$2" commit="$3" obj type csha cdate
  while IFS=$'\t' read -r _ obj type; do
    [ -z "$obj" ] && continue
    if [ "$type" = "tag" ]; then
      IFS=$'\t' read -r csha cdate < <(gh api "repos/$repo/git/tags/$obj" \
        --jq '[(.object?.sha // "" | tostring), (.tagger?.date // "" | tostring)] | @tsv' 2>/dev/null) || true
    else
      csha="$obj"; cdate=""
    fi
    if [ "$csha" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(gh api "repos/$repo/git/matching-refs/tags/$agent/v" \
             --jq '.[]? | [.ref, (.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>/dev/null)
  echo ""
}

# candidate_cut_date <agent> <candidate_commit> — ISO-8601 Zulu tagger date of the
# immutable release tag <agent>/vX.Y.Z that points at the candidate commit. This is the
# per-candidate cumulative-window start (#548): health is measured since the candidate's
# OWN cut, NOT a rolling window — so a pre-cut failure of a prior version is excluded.
# For a cross-repo agent (host != THIS_REPO) the release tags live on the host, so the
# date is resolved there via the GitHub API instead of the local for-each-ref (#1049).
candidate_cut_date() {
  local agent="$1" commit="$2" host obj deref cdate c
  host="$(_agent_field "$agent" host)"
  if [ -n "$host" ] && [ "$host" != "$THIS_REPO" ]; then
    _gh_candidate_cut_date "$host" "$agent" "$commit"
    return 0
  fi
  while IFS='|' read -r obj deref cdate; do
    c="$deref"; [ -z "$c" ] && c="$obj"
    if [ "$c" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(git for-each-ref \
             --format='%(objectname)|%(*objectname)|%(creatordate:iso-strict)' \
             "refs/tags/${agent}/v*" 2>/dev/null)
  git log -1 --format=%cI "$commit" 2>/dev/null || echo ""
}

# _run_json <repo> <workflow> <since_z> — gh run-list JSON (conclusion,createdAt,databaseId,workflowName) for a
# repo since the given Zulu timestamp. Empty repo/wildcard → []. Never fails the caller.
_run_json() {
  local repo="$1" wf="$2" since="$3"
  [ -z "$repo" ] || [ "$repo" = '*' ] && { echo '[]'; return 0; }
  gh run list --repo "$repo" --workflow "$wf" ${since:+--created ">=$since"} \
    -L 1000 --json conclusion,createdAt,databaseId,workflowName 2>/dev/null || echo '[]'
}

# _tier_sample <agent> <since_z> <repo...> — EXECUTED runs (success+failure) on the
# source tier since the candidate cut. Prints "<executed> <earliest_createdAt|->".
_tier_sample() {
  local agent="$1" since="$2"; shift 2
  local wf repo json executed=0 earliest="" e
  wf="$(_agent_field "$agent" run_workflow)"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    executed=$(( executed + $(jq '[.[]?|select(.conclusion=="success" or .conclusion=="failure")]|length' 2>/dev/null <<< "$json" || echo 0) ))
    e="$(jq -r '[.[]?|select(.conclusion=="success" or .conclusion=="failure")|.createdAt?]|min // empty' 2>/dev/null <<< "$json" || echo "")"
    if [ -n "$e" ] && { [ -z "$earliest" ] || [[ "$e" < "$earliest" ]]; }; then earliest="$e"; fi
  done
  echo "$executed ${earliest:--}"
}

# _benign_patterns <agent> — emit the per-reusable known-benign failure-class allowlist
# (#1025 P2) as TSV "<workflow_regex>\t<step_regex>", one entry per line. Empty if none.
_benign_patterns() {
  _jq -r --arg a "$1" \
    '.agents[$a].gate?.benign_failure_classes // [] | .[] | [(.workflow // ""), (.step // "")] | @tsv'
}

# Memoization cache for _run_signature: keyed by "repo:run_id".
# Avoids duplicate gh run view calls for the same (repo, run_id) across agents
# in evaluate-all (where multiple agents can share repos).
declare -A _RUN_SIG_CACHE=()

# _run_signature <repo> <run_id> — the failed step names of a run, joined by newlines
# (the "step/error signature" the allowlist matches against). Empty repo/wildcard/id or
# any gh error → "" (fail-closed: an unknown signature is never treated as benign).
_run_signature() {
  local repo="$1" id="$2" cache_key sig json
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 0; }
  cache_key="${repo}:${id}"
  if [[ -v _RUN_SIG_CACHE["$cache_key"] ]]; then
    echo "${_RUN_SIG_CACHE[$cache_key]}"
    return 0
  fi
  json="$(gh run view "$id" --repo "$repo" --json jobs 2>/dev/null || echo '{}')"
  sig="$(jq -r '[.jobs[]?|.steps[]?|select(.conclusion=="failure")|.name] | join("\n")' \
    2>/dev/null <<< "$json" || echo "")"
  _RUN_SIG_CACHE["$cache_key"]="$sig"
  echo "$sig"
}

# _failure_benign <repo> <run_id> <workflow_name> <patterns_tsv> — return 0 if this
# in-window failure matches any allowlist entry, else 1. Fail-closed on an empty signature.
_failure_benign() {
  local repo="$1" rid="$2" rwf="$3" patterns="$4" sig wf_re step_re
  sig="$(_run_signature "$repo" "$rid")"
  [ -z "$sig" ] && return 1
  while IFS=$'\t' read -r wf_re step_re; do
    [ -z "$step_re" ] && continue
    if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then return 0; fi
  done <<< "$patterns"
  return 1
}

# _cumulative_health <agent> <since_z> <apply_benign 0|1> <repo...> — failures +
# startup_failures across EVERY given tier repo since the candidate cut. When
# apply_benign=1, failures matching the per-reusable known-benign allowlist (#1025 P2)
# are counted separately and excluded from the blocking total. Prints
# "<failures> <startup_failures> <benign_excluded>".
_cumulative_health() {
  local agent="$1" since="$2" apply_benign="$3"; shift 3
  local wf repo json fail=0 startup=0 benign=0 patterns="" rid rwf
  wf="$(_agent_field "$agent" run_workflow)"
  [ "$apply_benign" = "1" ] && patterns="$(_benign_patterns "$agent")"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    startup=$(( startup + $(jq '[.[]?|select(.conclusion=="startup_failure")]|length' 2>/dev/null <<< "$json" || echo 0) ))
    if [ -z "$patterns" ]; then
      # No benign patterns to match — count all failures with one jq pass,
      # avoiding a gh run view call per failure.
      fail=$(( fail + $(jq '[.[]?|select(.conclusion=="failure")]|length' 2>/dev/null <<< "$json" || echo 0) ))
    else
      while IFS=$'\t' read -r rid rwf; do
        if _failure_benign "$repo" "$rid" "$rwf" "$patterns"; then
          benign=$(( benign + 1 ))
        else
          fail=$(( fail + 1 ))
        fi
      done < <(jq -r '.[]?|select(.conclusion=="failure")|[(.databaseId // "" | tostring),(.workflowName // "")]|@tsv' 2>/dev/null <<< "$json")
    fi
  done
  echo "$fail $startup $benign"
}

# _baseline_daily <agent> <window_days> <repo...> — per-day EXECUTED counts on the
# source tier over the trailing window_days (exactly window_days integers, zero-filled),
# feeding the robust spike-capped baseline for the sample target (#548).
_baseline_daily() {
  local agent="$1" window="$2"; shift 2
  local wf since repo json dates="" day i count out=""
  wf="$(_agent_field "$agent" run_workflow)"
  since="$(_iso_now_minus_days "$window")"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    dates+="$(jq -r '.[]?|select(.conclusion=="success" or .conclusion=="failure")|.createdAt[0:10]?' 2>/dev/null <<< "$json" || true)"$'\n'
  done
  for (( i=0; i<window; i++ )); do
    day="$(date -u -d "-${i} days" +%Y-%m-%d 2>/dev/null || date -u -v"-${i}d" +%Y-%m-%d 2>/dev/null || echo "")"
    count=$(grep -c "^${day}$" 2>/dev/null <<< "$dates" || true)
    out+="${count} "
  done
  echo "${out% }"
}

# _reusable_differs <agent> <candidate_commit> <prior_commit> — 1 if the agent's reusable
# workflow blob differs between the candidate SHA and the prior channel SHA, else 0. Used
# by triage to confirm a CANDIDATE REGRESSION (#548): a failure whose reusable is identical
# to the prior version is pre-existing, not introduced by the candidate.
_reusable_differs() {
  local agent="$1" cand="$2" prior="$3" reusable a b
  reusable="$(_agent_field "$agent" reusable)"
  [ -z "$reusable" ] || [ -z "$cand" ] || [ -z "$prior" ] && { echo 0; return 0; }
  a="$(git rev-parse -q --verify "${cand}:${reusable}" 2>/dev/null || echo "")"
  b="$(git rev-parse -q --verify "${prior}:${reusable}" 2>/dev/null || echo "")"
  [ -n "$a" ] && [ "$a" != "$b" ] && { echo 1; return 0; }
  echo 0
}

# _frontier_state <agent> — compute the rollout frontier and graduated gate, echoing:
#   "<cand> <frontier> <transition> <state> <dwell_h> <dwell_floor> <sample> <target> <cum_fail> <cum_startup> <triage>"
# frontier = first ring (after next) not yet on the candidate commit; triage is "-"
# unless state is BLOCKED (then REGRESSION | PRE_EXISTING).
_frontier_state() {
  local agent="$1"
  local cand chans frontier=""
  cand="$(channel_commit "$agent" next)"
  chans="$(ordered_channels "$agent")"

  local chan_array=()
  IFS=, read -r -a chan_array <<< "$chans"
  local ch
  for ch in "${chan_array[@]}"; do
    local c; c="$(channel_commit "$agent" "$ch")"
    if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then :; else frontier="$ch"; break; fi
  done
  if [ -z "$frontier" ]; then
    echo "$cand - - COMPLETE 0 0 0 0 0 0 0 -"; return 0
  fi

  local transition source cut_z now_epoch
  transition="$(transition_key "$frontier" "$chans")"
  source="${transition%%->*}"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  if [ -z "$cut_z" ]; then
    # Cannot determine the per-candidate window start — fail closed to prevent unbounded history queries.
    echo "$cand $frontier $transition BLOCKED 0 0 0 0 0 0 0 -"; return 0
  fi
  now_epoch="$(date -u +%s)"

  # Source-tier repos (the tier currently running the candidate).
  local src_repos=() r
  while IFS= read -r r; do [ -n "$r" ] && src_repos+=("$r"); done < <(resolve_members "$agent" "$source")

  # Sample on the source tier over the per-candidate window.
  local sample earliest
  read -r sample earliest < <(_tier_sample "$agent" "$cut_z" "${src_repos[@]}")

  # Dwell is always measured from the candidate's own cut (tagger date), per #548 spec.
  local dwell_h=0
  local cut_epoch; cut_epoch="$(_epoch "$cut_z")"
  if [ "$cut_epoch" -gt 0 ]; then
    dwell_h=$(( (now_epoch - cut_epoch) / 3600 ))
  fi
  [ "$dwell_h" -lt 0 ] && dwell_h=0

  # Whether the candidate changed the agent's reusable vs the prior channel on the frontier.
  # The known-benign allowlist is applied ONLY when the reusable is byte-identical (differs=0),
  # so it can never mask a candidate-introduced regression (#1025 P2).
  local prior differs apply_benign=1
  prior="$(channel_commit "$agent" "$frontier")"
  differs="$(_reusable_differs "$agent" "$cand" "$prior")"
  if [ "$differs" = "1" ]; then apply_benign=0; fi

  # Cumulative health across EVERY concrete tier repo since the candidate's own cut.
  local all_repos=() ch3
  for ch3 in "${chan_array[@]}"; do
    while IFS= read -r r; do [ -n "$r" ] && [ "$r" != '*' ] && all_repos+=("$r"); done \
      < <(resolve_members "$agent" "$ch3")
  done
  local cum_fail cum_startup cum_benign
  read -r cum_fail cum_startup cum_benign < <(_cumulative_health "$agent" "$cut_z" "$apply_benign" "${all_repos[@]}")

  # Per-transition knobs (registry-configurable; #548 defaults live in the ring SoT).
  local dwell_floor waived="false" target=0
  dwell_floor="$(_gate_knob "$agent" "$transition" dwell_hours)"; dwell_floor="${dwell_floor:-0}"
  if [ "$(_gate_knob "$agent" "$transition" waive_sample)" = "true" ]; then
    waived="true"
  elif [ -n "$(_gate_knob "$agent" "$transition" sample_min)" ]; then
    target="$(_gate_knob "$agent" "$transition" sample_min)"
  else
    local win frac cmin cmax spike_cap daily baseline_total
    win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; win="${win:-14}"
    frac="$(_gate_knob "$agent" "$transition" sample_fraction_permille)"; frac="${frac:-250}"
    cmin="$(_gate_knob "$agent" "$transition" sample_clamp_min)"; cmin="${cmin:-3}"
    cmax="$(_gate_knob "$agent" "$transition" sample_clamp_max)"; cmax="${cmax:-15}"
    spike_cap="$(_gate_field "$agent" baseline_spike_cap_multiple)"; spike_cap="${spike_cap:-3}"
    daily="$(_baseline_daily "$agent" "$win" "${src_repos[@]}")"
    baseline_total=0; for c in $daily; do baseline_total=$(( baseline_total + c )); done
    if [ "$baseline_total" -eq 0 ] && [ "$(_gate_knob "$agent" "$transition" waive_sample_if_no_caller)" = "true" ]; then
      waived="true"   # dwell-only: the source tier has no caller (#548)
    else
      # shellcheck disable=SC2086
      target="$(robust_sample_target "$frac" "$cmin" "$cmax" "$spike_cap" $daily)"
    fi
  fi

  local state; state="$(decide_graduated "$dwell_h" "$dwell_floor" "$sample" "$target" "$waived" "$cum_fail" "$cum_startup")"

  local triage="-"
  if [ "$state" = "BLOCKED" ]; then
    triage="$(classify_failure "$differs" "${CANARY_FAILURE_CATEGORY:-unknown}")"
  fi

  echo "$cand $frontier $transition $state $dwell_h $dwell_floor $sample $target $cum_fail $cum_startup $cum_benign $triage"
}

cmd_evaluate() {
  local agent="$1"
  echo "== canary-rollout evaluate: $agent (gate standard: .github#548) =="
  local cand; cand="$(channel_commit "$agent" next)"
  echo "candidate (next) = ${cand:0:12}  cut=$(candidate_cut_date "$agent" "$cand")"
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  local ch
  for ch in "${chan_array[@]}"; do
    local c; c="$(channel_commit "$agent" "$ch")"
    local mark="  "; [ -n "$cand" ] && [ "$c" = "$cand" ] && mark="* "
    printf '  %s%-7s -> %s\n' "$mark" "$ch" "${c:0:12}"
  done
  read -r _cand frontier transition state dwell floor sample target cum_fail cum_startup cum_benign triage < <(_frontier_state "$agent")
  echo "----"
  if [ "$frontier" = "-" ]; then
    echo "frontier: none — fully rolled out (all rings on candidate)."
  else
    gate_summary_line "$transition" "$state" "$dwell" "$floor" "$sample" "$target" "$cum_fail" "$cum_startup" "$cum_benign"
    echo "decision for next ring '$frontier' [$transition]: $state"
    if [ "$state" = "BLOCKED" ]; then
      if [ "$triage" = "REGRESSION" ]; then
        echo "::error::triage=REGRESSION — candidate changed the reusable and a run failed since cut. HALT + hold; recommend rollback."
      else
        echo "::warning::triage=PRE_EXISTING — failure is pre-existing/environmental. Report only; do NOT rollback, do NOT advance."
      fi
    fi
  fi
}

# cmd_evaluate_all — read-only evaluate for EVERY agent in the ring registry (#1025 P1).
# The 4h schedule runs this so the whole fleet is evaluated on the timer, not just one
# agent. Iterates the registry keys, so newly-registered reusables are picked up with no
# workflow change. Never mutates (evaluate is read-only).
cmd_evaluate_all() {
  local agents rc=0 agent
  agents="$(_jq -r '.agents | keys[]' 2>/dev/null || true)"
  if [ -z "$agents" ]; then
    echo "no agents registered in $CANARY_RINGS — nothing to evaluate."; return 0
  fi
  echo "== canary-rollout evaluate-all: fleet-wide (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    cmd_evaluate "$agent" || rc=$?
  done <<< "$agents"
  return "$rc"
}

cmd_promote() {
  local agent="$1"; shift
  local override=false dry=false allow_pre_flag=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --override) override=true ;;
      --dry-run)  dry=true ;;
      --allow-pre-existing) allow_pre_flag=true ;;
      *) echo "::error::unknown promote flag: $1" >&2; return 2 ;;
    esac; shift
  done
  read -r cand frontier transition state _dwell _floor _sample _target cum_fail _cum_startup _cum_benign triage < <(_frontier_state "$agent")
  if [ "$frontier" = "-" ]; then
    echo "nothing to promote — $agent is fully rolled out."; return 0
  fi
  # allow_pre: advance a BLOCKED frontier ONLY when triage=PRE_EXISTING (never REGRESSION).
  # Sourced from the per-reusable control block or the --allow-pre-existing flag (#1025 P2).
  local allow_pre
  allow_pre="$(_jq -r --arg a "$agent" '.agents[$a].gate?.control?.allow_pre_existing // false')"
  [ "$allow_pre_flag" = true ] && allow_pre=true
  if [ "$state" = "BLOCKED" ] && [ "$triage" = "REGRESSION" ] && [ "$override" != true ]; then
    echo "::error::gate=BLOCKED (triage=REGRESSION) for '$frontier' [$transition] — candidate regression suspected; not promoting. Investigate + rollback, do not --override blindly."
    return 0
  fi
  local advance=false
  [ "$state" = "PROMOTE" ] && advance=true
  [ "$override" = true ] && advance=true
  [ "$state" = "BLOCKED" ] && [ "$triage" = "PRE_EXISTING" ] && [ "$allow_pre" = true ] && advance=true
  if [ "$advance" != true ]; then
    echo "gate=$state for ring '$frontier' [$transition] (cum_fail=$cum_fail, triage=$triage) — not promoting. (use --override, or --allow-pre-existing for a PRE_EXISTING triage, after investigating)"
    return 0
  fi
  [ "$state" != "PROMOTE" ] && echo "::warning::advancing $agent/$frontier despite gate state '$state' (triage=$triage)"
  # Host-aware move: an agent hosted in THIS repo moves its channel tag via local git; a
  # cross-repo agent (host != THIS_REPO, e.g. the #482 reusables on petry-projects/.github)
  # keeps its tags on ITS host and must move them there via gh api — local `git tag -f`
  # fails with "nonexistent object" for a host commit absent from this checkout (#1054).
  local host cross=false
  host="$(_agent_field "$agent" host)"
  [ -n "$host" ] && [ "$host" != "$THIS_REPO" ] && cross=true
  echo "advancing $agent/$frontier -> ${cand:0:12}$( [ "$cross" = true ] && echo " on $host" )"
  if [ "$dry" = true ]; then
    if [ "$cross" = true ]; then
      echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$agent/$frontier sha=$cand (force)"
    else
      echo "[DRY-RUN] would: git tag -f $agent/$frontier $cand && git push --force origin $agent/$frontier"
    fi
    return 0
  fi
  if [ "$cross" = true ]; then
    _gh_move_tag "$host" "$agent/$frontier" "$cand" \
      || { echo "::error::failed to move $agent/$frontier -> ${cand:0:12} on $host" >&2; return 1; }
  else
    git tag -f "$agent/$frontier" "$cand"
    git push --force origin "$agent/$frontier"
  fi
  echo "promoted $agent/$frontier -> ${cand:0:12}"
  # Expose the move so the workflow can record a GitHub Deployment (traceability, #502).
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "promoted_agent=$agent"; echo "promoted_ring=$frontier"; echo "promoted_sha=$cand"; } >> "$GITHUB_OUTPUT"
  fi
}

# cmd_promote_all [--override] [--allow-pre-existing] [--dry-run] — the gated fleet
# auto-promote and the SCHEDULED arm of the automation (#1045 part b). Iterates every
# registry agent and calls cmd_promote for each, so each PROMOTE-ready agent advances
# exactly one ring per run while BLOCKED/REGRESSION agents are left untouched by the gate
# (no --override here). A per-agent failure is logged and skipped so one agent cannot halt
# the fleet sweep. Flags are forwarded verbatim to every cmd_promote.
cmd_promote_all() {
  local agents rc=0 agent
  agents="$(_jq -r '.agents | keys[]' 2>/dev/null || true)"
  if [ -z "$agents" ]; then
    echo "no agents registered in $CANARY_RINGS — nothing to promote."; return 0
  fi
  echo "== canary-rollout promote-all: fleet-wide (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    cmd_promote "$agent" "$@" || { rc=$?; echo "::warning::promote of $agent returned $rc (continuing fleet)"; }
  done <<< "$agents"
  return "$rc"
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
  # Host-aware, mirroring cmd_promote: a cross-repo agent's release + channel tags live on
  # ITS host, so both the target lookup and the move go through gh api, not local git (#1054).
  local host cross=false
  host="$(_agent_field "$agent" host)"
  [ -n "$host" ] && [ "$host" != "$THIS_REPO" ] && cross=true
  local target
  if [ "$cross" = true ]; then
    target="$(_gh_tag_commit "$host" "$agent/$to")"
  else
    target="$(git rev-parse -q --verify "refs/tags/$agent/$to^{commit}" 2>/dev/null || true)"
  fi
  [ -z "$target" ] && { echo "::error::release tag $agent/$to not found" >&2; return 1; }
  echo "rolling back $agent/$ring -> $to (${target:0:12})$( [ "$cross" = true ] && echo " on $host" )"
  if [ "$dry" = true ]; then
    if [ "$cross" = true ]; then
      echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$agent/$ring sha=$target (force)"
    else
      echo "[DRY-RUN] would: git tag -f $agent/$ring $target && git push --force origin $agent/$ring"
    fi
    return 0
  fi
  if [ "$cross" = true ]; then
    _gh_move_tag "$host" "$agent/$ring" "$target" \
      || { echo "::error::failed to move $agent/$ring -> $to on $host" >&2; return 1; }
  else
    git tag -f "$agent/$ring" "$target"
    git push --force origin "$agent/$ring"
  fi
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
  if [ -n "${SOAK_WINDOW_DAYS:-}" ] && ! [[ "${SOAK_WINDOW_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::SOAK_WINDOW_DAYS, when set, must be a positive integer" >&2
    return 2
  fi
  local sub="${1:-}"; shift || true
  case "$sub" in
    evaluate)     [ $# -ge 1 ] || { echo "usage: evaluate <agent>" >&2; return 2; }; cmd_evaluate "$@" ;;
    evaluate-all) cmd_evaluate_all ;;
    promote)      [ $# -ge 1 ] || { echo "usage: promote <agent> [--override] [--allow-pre-existing] [--dry-run]" >&2; return 2; }; cmd_promote "$@" ;;
    promote-all)  cmd_promote_all "$@" ;;
    rollback)     [ $# -ge 2 ] || { echo "usage: rollback <agent> <ring> --to <vX.Y.Z>" >&2; return 2; }; cmd_rollback "$@" ;;
    resolve)      [ $# -ge 2 ] || { echo "usage: resolve <agent> <channel>" >&2; return 2; }; resolve_members "$@" ;;
    *) echo "::error::usage: canary-rollout.sh {evaluate|evaluate-all|promote|promote-all|rollback|resolve} <agent> ..." >&2; return 2 ;;
  esac
}

# Source-guard: tests source this file to exercise resolve_members etc. without running.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
