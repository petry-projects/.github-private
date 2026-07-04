#!/usr/bin/env bash
set -euo pipefail
# canary-rollout.sh — ring-staged, health-gated promotion of agent releases by
# moving channel tags only (initiative #495, issue #501; rollback/observability #502).
#
# The ONLY action this performs is moving a channel tag (via `gh api` on the agent's host
# repo, with the release-manager App token — #1076) — it never writes consumer files. A ring advances
# only when the rings already on the candidate pass the soak/health gate (see
# scripts/lib/canary-rollout.sh for the pure decision core).
#
# Channel tags ARE the rollout state (#502): the frontier is derived from where each
# channel tag resolves; there is no separate state store.
#
# The FRONT END that closes the last manual seam (#1069): `autocut` polls each registered
# reusable and, when its blob on the host's main HEAD differs from the current `next`
# candidate, cuts a new immutable <agent>/vX.Y.Z and moves `next` onto it — seeding the soak/
# promote pipeline with no manual `cut-release.sh`. It is gated by CANARY_AUTO_CUT (the single
# kill-switch), runs BEFORE promote-all on the scheduled tick, and is best-effort.
#
# Usage:
#   canary-rollout.sh autocut      [--dry-run]         # cut+seed new candidates for changed reusables (gated by CANARY_AUTO_CUT)
#   canary-rollout.sh evaluate     <agent>             # read-only gate + health report (also the #502 report)
#   canary-rollout.sh evaluate-all                     # read-only evaluate for EVERY registry agent (fleet-wide; the 4h timer)
#   canary-rollout.sh promote  <agent> [--override] [--allow-pre-existing] [--dry-run]
#   canary-rollout.sh promote-all [--override] [--allow-pre-existing] [--dry-run]  # gated fleet auto-promote (the SCHEDULED arm, #1045b)
#   canary-rollout.sh rollback <agent> <ring> --to <vX.Y.Z> [--dry-run]
#   canary-rollout.sh resolve  <agent> <channel>       # debug: print resolved member repos
#   canary-rollout.sh sync-issues [--dry-run]          # blocker issue per BLOCKED agent + fleet-status table to the job summary (auto-triage)
#   canary-rollout.sh drift    [--emit-stub]           # read-only: report *-reusable.yml on a host but unregistered, + stale registry entries (#1082)
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
#   CANARY_AUTO_CUT     autocut kill-switch — autocut is a no-op unless this == 'true'
#   GH_TOKEN            credential; the workflow mints a GitHub App token and passes it here

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/canary-rollout.sh
source "${_HERE}/lib/canary-rollout.sh"
DEFAULT_RINGS="$(cd "${_HERE}/.." && pwd)/standards/canary-rings.json"
CANARY_RINGS="${CANARY_RINGS:-$DEFAULT_RINGS}"

# CUT_RELEASE — the cut-release.sh invoked by `autocut` to cut a new candidate. A
# sibling of this script by default; overridable so tests can stub the cut (#1069).
CUT_RELEASE="${CUT_RELEASE:-${_HERE}/cut-release.sh}"

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
# refs/tags/<tag> on <repo> to <sha> via the GitHub API. THE channel-tag mover for every
# agent (promote + rollback), this-repo and cross-repo alike (#1076): the API path is
# granted the release-manager App's ruleset bypass for tag UPDATEs, whereas a local
# `git push --force` is not (013 on protected channel tags) and also fails with
# "nonexistent object" for a cross-repo host commit absent from this checkout (#1054).
# Tries PATCH (existing ref) then falls back to POST (create the ref).
_gh_move_tag() {
  [ $# -lt 3 ] && return 1
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
  # Consistent move (#1076): EVERY agent moves its channel tag via `gh api` on its HOST
  # repo — never a local `git push`. A local force-push is NOT granted the release-manager
  # App's ruleset bypass for a tag UPDATE, so it 013s on a protected channel tag such as
  # dev-lead/next; the API path (same App token) IS honored as a bypass actor. host
  # defaults to THIS_REPO for an agent whose registry entry omits it.
  local host
  host="$(_jq -r --arg a "$agent" '.agents[$a].host // "" | tostring')"
  host="${host:-$THIS_REPO}"
  echo "advancing $agent/$frontier -> ${cand:0:12} on $host"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$agent/$frontier sha=$cand (force)"
    return 0
  fi
  _gh_move_tag "$host" "$agent/$frontier" "$cand" \
    || { echo "::error::failed to move $agent/$frontier -> ${cand:0:12} on $host" >&2; return 1; }
  echo "promoted $agent/$frontier -> ${cand:0:12}"
  # Expose the move for the workflow's GitHub Deployment (traceability, #502). The
  # deployment must be created on the repo that OWNS the moved commit: a cross-repo agent's
  # candidate SHA lives on its host, NOT on THIS_REPO — creating the deployment against
  # GITHUB_REPOSITORY 422s with "No ref found" (#1059). So emit the owning repo too.
  local deploy_repo="$host"   # the repo that OWNS the moved commit (#1059); host==THIS_REPO for this-repo agents
  # GITHUB_OUTPUT is single-valued (last write wins), fine for a single `promote`. For
  # `promote-all` (many promotions per run) the workflow reads CANARY_PROMOTIONS_LOG — one
  # TSV line per promotion — so it can record a deployment for EVERY move, not just the last.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "promoted_agent=$agent"; echo "promoted_ring=$frontier"
      echo "promoted_sha=$cand";   echo "promoted_host=$deploy_repo"; } >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${CANARY_PROMOTIONS_LOG:-}" ]; then
    printf '%s\t%s\t%s\t%s\n' "$agent" "$frontier" "$cand" "$deploy_repo" >> "$CANARY_PROMOTIONS_LOG"
  fi
}

# cmd_promote_all [--override] [--allow-pre-existing] [--dry-run] — the gated fleet
# auto-promote and the SCHEDULED arm of the automation (#1045 part b). Iterates every
# registry agent and calls cmd_promote for each, so each PROMOTE-ready agent advances
# exactly one ring per run while BLOCKED/REGRESSION agents are left untouched by the gate
# unless --override is passed (the scheduled workflow never passes it). A per-agent
# failure is logged and skipped so one agent cannot halt the fleet sweep. Flags are
# forwarded verbatim to every cmd_promote.
cmd_promote_all() {
  local agents rc=0 agent
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
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
  # Consistent path (#1076), mirroring cmd_promote: the target lookup AND the move both go
  # through gh api on the agent's HOST repo for every agent — never local git. host defaults
  # to THIS_REPO for an agent whose registry entry omits it.
  local host
  host="$(_jq -r --arg a "$agent" '.agents[$a].host // "" | tostring')"
  host="${host:-$THIS_REPO}"
  local target
  target="$(_gh_tag_commit "$host" "$agent/$to")"
  [ -z "$target" ] && { echo "::error::release tag $agent/$to not found on $host" >&2; return 1; }
  echo "rolling back $agent/$ring -> $to (${target:0:12}) on $host"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$agent/$ring sha=$target (force)"
    return 0
  fi
  _gh_move_tag "$host" "$agent/$ring" "$target" \
    || { echo "::error::failed to move $agent/$ring -> $to on $host" >&2; return 1; }
  echo "rolled back $agent/$ring -> $to"
}

# ── blocker-issue + fleet-status automation (auto-triage of held promotions) ────
# The gate detects + classifies a BLOCKED promotion; sync-issues turns that signal into
# a tracked work item: one idempotent issue per BLOCKED agent (with the failing-run
# evidence pre-attached), auto-closed when the gate clears, plus the whole-fleet status
# table rendered into the run's job summary (a read-only snapshot — not an issue). Runs on
# the schedule after promote-all. All GitHub writes are best-effort — a failure here never
# fails the promotion run.
ISSUE_REPO="${ISSUE_REPO:-$THIS_REPO}"

# _issue_find <label> <marker> — "<number>\t<STATE>" of the newest issue carrying <marker>
# in its body (matched locally over the label's issues, not GitHub search — HTML-comment
# markers are not reliably indexed). Empty if none.
_issue_find() {
  local label="$1" marker="$2"
  gh issue list --repo "$ISSUE_REPO" --label "$label" --state all -L 100 \
      --json number,state,body 2>/dev/null \
    | jq -r --arg m "$marker" \
        '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | last
         | if . == null then "" else "\(.number)\t\(.state | ascii_upcase)" end' 2>/dev/null \
    || echo ""
}

# _gh_issue_create <title> <body> <labels_csv> — create an issue, echo its number.
_gh_issue_create() {
  gh issue create --repo "$ISSUE_REPO" --title "$1" --body "$2" --label "$3" 2>/dev/null \
    | grep -oE '[0-9]+$' | tail -1
}

# _blocker_evidence <agent> <candidate_commit> — markdown bullets for the in-window failing
# runs (repo + run link + failed-step signature), capped at 8. Uses the SAME per-candidate
# window + tier repos the gate counts, so the evidence matches cum_fail.
_blocker_evidence() {
  local agent="$1" cand="$2" wf cut_z repo json r n=0 out=""
  wf="$(_agent_field "$agent" run_workflow)"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  [ -z "$cut_z" ] && { printf '_(no candidate cut date resolved — cannot list failing runs)_\n'; return 0; }
  local chan_array=() ch all=() seen=" " dedup=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  for ch in "${chan_array[@]}"; do
    while IFS= read -r r; do [ -n "$r" ] && [ "$r" != '*' ] && all+=("$r"); done < <(resolve_members "$agent" "$ch")
  done
  for r in "${all[@]}"; do case "$seen" in *" $r "*) ;; *) dedup+=("$r"); seen+="$r ";; esac; done
  for repo in "${dedup[@]}"; do
    json="$(_run_json "$repo" "$wf" "$cut_z")"
    local rid sig
    while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      if [ "$n" -ge 8 ]; then out+="- _(…more failing runs; truncated at 8)_"$'\n'; printf '%s' "$out"; return 0; fi
      sig="$(_run_signature "$repo" "$rid" | tr '\n' ';' | sed 's/;$//')"
      out+="- \`$repo\` — run [$rid](https://github.com/$repo/actions/runs/$rid); failed steps: ${sig:-unknown}"$'\n'
      n=$((n+1))
    done < <(jq -r '.[]?|select(.conclusion=="failure" or .conclusion=="startup_failure")|(.databaseId|tostring)' 2>/dev/null <<< "$json")
  done
  [ -z "$out" ] && out="_(no failing runs in the per-candidate window — cum_fail may be startup_failures or a transient count)_"$'\n'
  printf '%s' "$out"
}

# _blocker_body <agent> <transition> <cand> <cum_fail> <cum_startup> <triage> <host> <evidence>
_blocker_body() {
  local agent="$1" transition="$2" cand="$3" cum_fail="$4" cum_startup="$5" triage="$6" host="$7" evidence="$8" note
  if [ "$triage" = "REGRESSION" ]; then
    note="> ⛔ **REGRESSION** — the candidate changed the reusable and a run failed since its cut. HALT + hold; investigate and roll back rather than \`--override\`. (labelled \`needs-human\`)"
  else
    note="> ⚠️ **PRE_EXISTING** — the failure is pre-existing/environmental (reusable byte-identical to the prior channel). Report only; the gate will not roll back or advance. Fix-forward, and the armed timer auto-promotes once clean."
  fi
  cat <<EOF
<!-- canary-blocker:$agent -->
**Automated canary-rollout blocker.** The release gate is holding \`$agent\` and will not promote it until this clears. Filed + maintained by the Canary Rollout workflow (gate standard: .github#548); this issue is **regenerated each run and auto-closes** when the gate passes — do not edit the table below by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| transition | \`$transition\` |
| candidate | \`${cand:0:12}\` |
| host repo | \`$host\` |
| cumulative failures | **$cum_fail** (startup_failures: $cum_startup) |
| triage | **$triage** |

$note

### Failing runs in the per-candidate window
$evidence
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
}

# _dashboard_md <rows_md> <timestamp> — the fleet-status table. This is a read-only snapshot
# (not a work item), so it is rendered into the GitHub Actions run's job summary — NOT filed
# as an issue: it needs no Issues:write, spawns no synthetic pinned issue, and shows on the
# run's Summary page every tick. The per-agent BLOCKED issues remain issues (they are
# trackable, assignable, closable work items).
_dashboard_md() {
  cat <<EOF
# Canary Rollout — fleet status

Last updated: \`$2\` · auto-promote armed: \`${CANARY_AUTO_PROMOTE:-unset}\` · gate standard: .github#548.

| agent | state | transition | cum_fail | triage | blocker |
|---|---|---|---|---|---|
$1

\`PROMOTE\`/\`COMPLETE\`/\`SOAKING\` need no action. \`BLOCKED\` opens a per-agent issue (label \`canary-blocker\`) with the failing-run evidence; it auto-closes when the gate clears.
EOF
}

# cmd_sync_issues [--dry-run] — upsert one blocker issue per BLOCKED agent, and render the
# fleet-status table into the run's job summary (GITHUB_STEP_SUMMARY). Blocker issues are
# idempotent (marker-keyed) and auto-close when the gate clears. Best-effort: never fails the
# run. Reads ISSUE_REPO (default THIS_REPO).
cmd_sync_issues() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  local agents; agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  [ -z "$agents" ] && { echo "no agents registered in $CANARY_RINGS — nothing to sync."; return 0; }
  echo "== canary-rollout sync-issues: repo=$ISSUE_REPO dry=$dry (gate standard: .github#548) =="
  if [ "$dry" != true ]; then
    gh label create canary-blocker --repo "$ISSUE_REPO" --color ededed --description "canary-rollout automation" >/dev/null 2>&1 || true
  fi
  local rows="" agent
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    local cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage host
    read -r cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage < <(_frontier_state "$agent")
    host="$(_agent_field "$agent" host)"
    local blk="—" num_state num istate
    # Best-effort (#1081): these substitutions call gh/jq. Under `set -euo pipefail`
    # a bare assignment propagates a non-zero exit and would abort the whole step —
    # before the fleet dashboard renders and before the intended fallback warnings
    # below. `|| true` keeps sync-issues degrading gracefully (empty → handled).
    num_state="$(_issue_find canary-blocker "<!-- canary-blocker:$agent -->" || true)"
    num="${num_state%%$'\t'*}"; istate="${num_state##*$'\t'}"
    if [ "$state" = "BLOCKED" ]; then
      local evidence body title
      evidence="$(_blocker_evidence "$agent" "$cand" || true)"
      body="$(_blocker_body "$agent" "$transition" "$cand" "$cum_fail" "$cum_startup" "$triage" "$host" "$evidence")"
      title="Canary blocker: $agent $transition (cum_fail=$cum_fail, $triage)"
      if [ -z "$num" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN blocker issue for $agent ($triage)"; blk="(new)"; else
          num="$(_gh_issue_create "$title" "$body" "canary-blocker" || true)"
          if [ -n "$num" ]; then
            [ "$triage" = "REGRESSION" ] && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened blocker issue #$num for $agent"; blk="#$num"
          else echo "::warning::could not open blocker issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE blocker issue #$num for $agent"; blk="#$num"; else
          [ "$istate" = "OPEN" ] || gh issue reopen "$num" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$num" --repo "$ISSUE_REPO" --title "$title" --body "$body" >/dev/null 2>&1 \
            || echo "::warning::could not update blocker issue #$num for $agent"
          [ "$triage" = "REGRESSION" ] && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
          echo "  updated blocker issue #$num for $agent"; blk="#$num"
        fi
      fi
    else
      # Not blocked — close a stale open blocker issue (the gate cleared).
      if [ -n "$num" ] && [ "$istate" = "OPEN" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE cleared blocker issue #$num for $agent ($state)"; else
          gh issue close "$num" --repo "$ISSUE_REPO" \
            --comment "✅ Gate cleared — \`$agent\` is now \`$state\`. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed cleared blocker issue #$num for $agent"
        fi
        blk="#$num (closed)"
      fi
    fi
    rows+="| \`$agent\` | $state | \`$transition\` | $cum_fail | $triage | $blk |"$'\n'
  done <<< "$agents"

  # Render the fleet-status table into the run's job summary (a read-only snapshot, not a
  # work item). Falls back to stdout when GITHUB_STEP_SUMMARY is unset (local/manual runs).
  local ts dmd
  ts="$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo unknown)"
  dmd="$(_dashboard_md "${rows%$'\n'}" "$ts")"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '\n%s\n' "$dmd" >> "$GITHUB_STEP_SUMMARY"; then
      echo "  wrote fleet-status table to the job summary"
    else
      echo "::warning::could not write the fleet-status job summary"
    fi
  else
    echo "──── fleet status ────"
    printf '%s\n' "$dmd"
  fi
  return 0
}

# ── autocut: cut a new candidate when a reusable changes on main (#1069) ────────
# The FRONT END of the canary pipeline (the promoter's counterpart). At each scheduled
# tick — gated by CANARY_AUTO_CUT — for each registered agent it compares the reusable
# blob at the host's default-branch HEAD against the blob at the current `next` candidate;
# if they differ it cuts a new immutable <agent>/vX.Y.Z (patch bump by default) and moves
# `next` onto it via cut-release.sh, seeding the candidate into the existing soak/promote
# pipeline. Detection is done here in .github-private via the App token (which reads every
# host), so no cross-repo Actions plumbing is needed. Best-effort: never fails the run.
#
# Scope/limitation (v1): detection is on the reusable FILE blob only (the registry
# `reusable` path). A change to a shared library the reusable sources — without the
# reusable file itself changing — is not detected. Acceptable for v1; could extend to a
# path-set later.

# _gh_default_branch <repo> — the repo's default branch name (empty on error).
_gh_default_branch() { gh api "repos/$1" --jq '.default_branch' 2>/dev/null || echo ""; }

# _gh_head_sha <repo> <branch> — the commit SHA at <branch> HEAD (empty on error).
_gh_head_sha() { gh api "repos/$1/commits/$2" --jq '.sha' 2>/dev/null || echo ""; }

# _gh_blob_sha <repo> <path> <ref> — the git blob SHA of <path> at <ref> (empty on error).
_gh_blob_sha() { gh api "repos/$1/contents/$2?ref=$3" --jq '.sha' 2>/dev/null || echo ""; }

# _host_release_versions <agent> — echo every MAJOR.MINOR.PATCH (one per line) that has an
# immutable <agent>/vX.Y.Z tag on the agent's host, via the API (the App token reads every
# host; release tags are on the remote for both this-repo and cross-repo agents).
_host_release_versions() {
  local agent="$1" host
  host="$(_agent_field "$agent" host)"
  [ -z "$host" ] && return 0
  gh api "repos/$host/git/matching-refs/tags/$agent/v" --jq '.[]?.ref' 2>/dev/null \
    | sed -n "s#^refs/tags/${agent}/v##p" || true
}

# _autocut_bump <agent> — the configured bump level for the agent (registry knob
# .agents[a].autocut.bump), defaulting to patch. Anything but minor/major → patch.
_autocut_bump() {
  local b
  b="$(_jq -r --arg a "$1" '.agents[$a]?.autocut?.bump // "patch"')"
  case "$b" in major|minor|patch) echo "$b" ;; *) echo "patch" ;; esac
}

# _next_release_version <agent> <bump> — compute the next release version: bump the highest
# existing <agent>/vX.Y.Z on the host by <bump>. No existing tags → seed from 0.0.0.
_next_release_version() {
  local agent="$1" bump="$2" versions highest
  versions="$(_host_release_versions "$agent")"
  # shellcheck disable=SC2086
  highest="$(max_semver $versions)"
  [ -z "$highest" ] && highest="0.0.0"
  bump_version "$highest" "$bump"
}

# _autocut_agent <agent> <dry:true|false> — cut a new candidate for ONE agent if its reusable
# blob on the host default-branch HEAD differs from the blob at the current `next` candidate.
# Idempotent: no-op when the blobs match or main HEAD already equals the next candidate.
# Best-effort: any resolution gap is a ::warning + skip, never a hard failure.
_autocut_agent() {
  local agent="$1" dry="$2"
  local host reusable defbranch mainsha next_commit main_blob next_blob bump newver
  host="$(_agent_field "$agent" host)"
  reusable="$(_agent_field "$agent" reusable)"
  if [ -z "$host" ] || [ -z "$reusable" ]; then
    echo "::warning::autocut $agent: missing host/reusable in registry — skipping"; return 0
  fi
  defbranch="$(_gh_default_branch "$host")"; [ -z "$defbranch" ] && defbranch="main"
  mainsha="$(_gh_head_sha "$host" "$defbranch")"
  if [ -z "$mainsha" ]; then
    echo "::warning::autocut $agent: could not resolve $host $defbranch HEAD — skipping"; return 0
  fi
  main_blob="$(_gh_blob_sha "$host" "$reusable" "$mainsha")"
  if [ -z "$main_blob" ]; then
    echo "::warning::autocut $agent: reusable '$reusable' not found at $host@${mainsha:0:12} — skipping"; return 0
  fi
  next_commit="$(channel_commit "$agent" next)"
  next_blob=""
  [ -n "$next_commit" ] && next_blob="$(_gh_blob_sha "$host" "$reusable" "$next_commit")"
  # Idempotency: nothing to cut when main HEAD already IS the candidate, or the reusable blob
  # is byte-identical between main and the current next candidate.
  if [ "$mainsha" = "$next_commit" ] || { [ -n "$next_blob" ] && [ "$main_blob" = "$next_blob" ]; }; then
    echo "autocut $agent: reusable unchanged on $host (next candidate up to date) — no cut."
    return 0
  fi
  bump="$(_autocut_bump "$agent")"
  newver="$(_next_release_version "$agent" "$bump")"
  echo "autocut $agent: reusable changed on $host ($defbranch ${mainsha:0:12}) vs next ${next_commit:0:12} — cutting v$newver (bump=$bump), moving next."
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: cut-release.sh $agent $newver --ref $mainsha --channel next --push"
    return 0
  fi
  bash "$CUT_RELEASE" "$agent" "$newver" --ref "$mainsha" --channel next --push \
    || { echo "::warning::autocut $agent: cut-release failed for v$newver (best-effort, continuing)"; return 0; }
  echo "autocut $agent: cut v$newver from ${mainsha:0:12} and moved next."
}

# cmd_autocut [--dry-run] — the scheduled front end. Gated by CANARY_AUTO_CUT (the single
# kill-switch): a clean no-op unless CANARY_AUTO_CUT == 'true'. Iterates every registry agent;
# a per-agent failure is logged and skipped so one agent cannot halt the fleet sweep. Runs
# BEFORE promote-all so a freshly cut candidate begins soaking the same tick (dwell=0 < floor
# → it SOAKS, does not promote).
cmd_autocut() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  if [ "${CANARY_AUTO_CUT:-}" != "true" ]; then
    echo "== canary-rollout autocut: DISABLED (CANARY_AUTO_CUT != 'true') — no-op. =="
    return 0
  fi
  local agents agent
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  [ -z "$agents" ] && { echo "no agents registered in $CANARY_RINGS — nothing to autocut."; return 0; }
  echo "== canary-rollout autocut: fleet-wide dry=$dry (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    _autocut_agent "$agent" "$dry" || echo "::warning::autocut of $agent failed (continuing fleet)"
  done <<< "$agents"
  return 0
}

# ── drift: registry vs host reusables (read-only audit, #1082) ──────────────────
# canary-rings.json's .agents{} is the MANUAL source of truth for what the canary
# pipeline manages — both autocut and evaluate-all iterate `.agents | keys`, so ANY
# reusable not registered is covered by nothing (no cut, no soak, no gate, no dashboard).
# There is otherwise no scan of the hosts' .github/workflows/*-reusable.yml, so a
# first-party reusable that was added/renamed but never registered ships with ZERO staged
# rollout until a human remembers to register it.
#
# `drift` closes that observability gap: it enumerates the *-reusable.yml on every
# registered host repo, diffs against the registry's reusable paths, and REPORTS (stdout +
# job summary) two classes of drift. It is read-only — it never registers anything (ring
# topology/members need human intent); `--emit-stub` optionally prints a scaffold
# .agents[<name>] block for a maintainer to fill in.
#   - unregistered: a *-reusable.yml present on a host but absent from canary-rings.json.
#   - missing-file: a registry entry whose reusable file no longer exists on its host.

# _registered_hosts — the set of host repos to scan: the union of every agent's `host`
# and the org_infra_repos list, deduped (one repo per line).
_registered_hosts() {
  _jq -r '([.agents[]?.host // empty] + (.org_infra_repos // []))
          | map(select(. != "")) | unique | .[]'
}

# _gh_list_reusables <repo> — the full paths of *-reusable.yml files under the repo's
# .github/workflows (one per line). Reads the directory listing via the contents API and
# filters locally (mirrors _run_json: raw fetch, jq in the caller). Returns non-zero when
# the listing could NOT be enumerated (the API errored or did not return a JSON array), so
# the caller can distinguish "no reusables here" from "could not read the host" — the latter
# must NOT be treated as every registered reusable having been deleted (a false missing-file
# avalanche). A genuinely empty (but readable) workflows dir returns success with no output.
_gh_list_reusables() {
  local repo="$1" json
  json="$(gh api "repos/$repo/contents/.github/workflows" 2>/dev/null)" || return 1
  jq -e 'type=="array"' >/dev/null 2>&1 <<< "$json" || return 1
  jq -r '[.[]? | select(.type=="file") | select((.name // "") | endswith("-reusable.yml")) | .path] | .[]' \
    2>/dev/null <<< "$json" || true
  return 0
}

# _registered_reusables_for_host <host> — the reusable paths registered to <host> (one
# per line, deduped).
_registered_reusables_for_host() {
  _jq -r --arg h "$1" '[.agents[]? | select(.host==$h) | .reusable // empty] | unique | .[]'
}

# _agents_for_reusable <host> <path> — the registry agent name(s) whose (host,reusable)
# match, joined by ", " (for the missing-file finding message).
_agents_for_reusable() {
  _jq -r --arg h "$1" --arg p "$2" \
    '[.agents | to_entries[] | select(.value.host==$h and .value.reusable==$p) | .key] | join(", ")'
}

# _drift_scaffold <host> <path> — a scaffold .agents[<name>] JSON block for an unregistered
# reusable, keyed by the name derived from the filename (foo-reusable.yml → foo). Clones an
# existing agent's ring topology + gate defaults as a starting point (members need human
# intent), resets host/reusable/run_workflow, and empties the per-reusable benign allowlist
# so a new reusable does not silently inherit another agent's benign classes. --emit-stub only.
_drift_scaffold() {
  local host="$1" path="$2" name
  name="${path##*/}"; name="${name%-reusable.yml}"
  _jq --arg h "$host" --arg p "$path" --arg n "$name" '
    (.agents | to_entries | (map(select(.value.host==$h)) + .) | .[0].value) as $tpl
    | { ($n): ($tpl
        | .host = $h
        | .reusable = $p
        | .run_workflow = "TODO: set to the reusable workflow name (the name: value)"
        | (.gate.benign_failure_classes) = []) }'
}

# cmd_drift [--emit-stub] — the read-only registry/host drift audit. Exits 0 (report-only);
# each finding is a ::warning:: annotation and a job-summary row. --emit-stub additionally
# prints a scaffold .agents[<name>] block per unregistered reusable.
cmd_drift() {
  local emit_stub=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --emit-stub) emit_stub=true ;;
      *) echo "::error::unknown drift flag: $1" >&2; return 2 ;;
    esac; shift
  done
  echo "== canary-rollout drift: registry vs host reusables (read-only; gate standard: .github#548) =="
  local hosts host rows="" stubs="" u_total=0 m_total=0
  hosts="$(_registered_hosts)"
  if [ -z "$hosts" ]; then
    echo "no host repos resolved from $CANARY_RINGS — nothing to audit."; return 0
  fi
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    echo "──────── host: $host ────────"
    local present registered unregistered missing p agents
    if ! present="$(_gh_list_reusables "$host")"; then
      # Could not read the host's workflows dir — skip it rather than false-flag every
      # registered reusable as missing-file. Read-only + best-effort: a warning, not a failure.
      echo "::warning::drift $host: could not enumerate .github/workflows (API error / no access) — skipping host this cycle"
      continue
    fi
    registered="$(_registered_reusables_for_host "$host")"
    local reg_arr=() pres_arr=() reg_str="" pres_str=""
    if [ -n "$registered" ]; then mapfile -t reg_arr <<< "$registered"; fi
    if [ -n "$present" ]; then mapfile -t pres_arr <<< "$present"; fi
    [ "${#reg_arr[@]}" -gt 0 ] && reg_str=" ${reg_arr[*]}"
    [ "${#pres_arr[@]}" -gt 0 ] && pres_str=" ${pres_arr[*]}"
    echo "  registered reusables (${#reg_arr[@]}):$reg_str"
    echo "  present *-reusable.yml (${#pres_arr[@]}):$pres_str"
    # unregistered = present on the host but not in the registry.
    unregistered="$(set_difference "$present" "$registered")"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      echo "::warning::DRIFT[unregistered] $host: $p present on host but absent from canary-rings.json (no cut/soak/gate/dashboard until registered)"
      rows+="| \`$host\` | unregistered | \`$p\` | not in \`.agents{}\` — register it or delete the file |"$'\n'
      u_total=$((u_total + 1))
      if [ "$emit_stub" = true ]; then stubs+="$(_drift_scaffold "$host" "$p")"$'\n'; fi
    done <<< "$unregistered"
    # missing-file = registered in the registry but the file is gone from the host.
    missing="$(set_difference "$registered" "$present")"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      agents="$(_agents_for_reusable "$host" "$p")"
      echo "::warning::DRIFT[missing-file] $host: registry agent '${agents:-?}' -> $p not found on host (deleted/renamed reusable; stale registry entry)"
      rows+="| \`$host\` | missing-file | \`$p\` | registry agent \`${agents:-?}\` points at a file that no longer exists |"$'\n'
      m_total=$((m_total + 1))
    done <<< "$missing"
  done <<< "$hosts"

  echo "----"
  local total=$((u_total + m_total))
  echo "drift summary: $u_total unregistered, $m_total missing-file ($total total findings)"
  if [ "$total" -eq 0 ]; then
    echo "no reusable drift detected — the registry and host reusables are in sync."
  fi
  if [ "$emit_stub" = true ] && [ -n "$stubs" ]; then
    echo "---- scaffold .agents[<name>] stubs for unregistered reusables (--emit-stub) ----"
    echo "Paste into standards/canary-rings.json under .agents, then set run_workflow + review ring members:"
    printf '%s' "$stubs"
  fi

  # Render the fleet-drift table into the run's job summary (a read-only snapshot). Falls
  # back to stdout when GITHUB_STEP_SUMMARY is unset (local/manual runs).
  local ts dmd
  ts="$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo unknown)"
  if [ "$total" -eq 0 ]; then
    dmd="$(printf '# Canary Rollout — reusable drift\n\nLast updated: `%s` · gate standard: .github#548.\n\n_No reusable drift — the registry and host `*-reusable.yml` are in sync._\n' "$ts")"
  else
    dmd="$(printf '# Canary Rollout — reusable drift\n\nLast updated: `%s` · gate standard: .github#548 · findings: **%s** (%s unregistered, %s missing-file).\n\n| host | class | reusable | note |\n|---|---|---|---|\n%s\n> `unregistered` ships with ZERO staged rollout until added to `.agents{}`; `missing-file` is a stale registry entry pointing at a deleted reusable. Report-only — no auto-registration.\n' "$ts" "$total" "$u_total" "$m_total" "${rows%$'\n'}")"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '\n%s\n' "$dmd" >> "$GITHUB_STEP_SUMMARY"; then
      echo "  wrote reusable-drift table to the job summary"
    else
      echo "::warning::could not write the reusable-drift job summary"
    fi
  fi
  return 0
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
    sync-issues)  cmd_sync_issues "$@" ;;   # upsert blocker issues + dashboard for held promotions
    autocut)      cmd_autocut "$@" ;;       # cut a new candidate when a reusable changes on main (#1069)
    drift)        cmd_drift "$@" ;;         # report reusables present on a host but unregistered, + stale registry entries (#1082)
    *) echo "::error::usage: canary-rollout.sh {autocut|drift|evaluate|evaluate-all|promote|promote-all|rollback|resolve|sync-issues} [args]" >&2; return 2 ;;
  esac
}

# Source-guard: tests source this file to exercise resolve_members etc. without running.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
