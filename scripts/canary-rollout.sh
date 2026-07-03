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
#   canary-rollout.sh evaluate-all                     # read-only evaluate for EVERY registry agent (fleet-wide)
#   canary-rollout.sh promote  <agent> [--override] [--allow-pre-existing] [--dry-run]
#   canary-rollout.sh promote-all [--dry-run]          # gated fleet-wide promote (the 4h timer, #1045):
#                                                      # advance EACH agent one ring iff its gate is PROMOTE,
#                                                      # skipping gate.control.hold agents, honouring
#                                                      # gate.control.allow_pre_existing, hard-stopping on
#                                                      # REGRESSION. Never --override (autonomous-through-stable,
#                                                      # override-only stays a human decision).
#   canary-rollout.sh rollback <agent> <ring> --to <vX.Y.Z> [--dry-run]
#   canary-rollout.sh resolve  <agent> <channel>       # debug: print resolved member repos
#
# Env (promotion journal, #1045):
#   CANARY_PROMOTIONS_LOG  if set, each REAL (non-dry) promotion appends one JSON line
#                          {agent,ring,sha} so the workflow can record a GitHub Deployment
#                          per move even when promote-all advances several agents at once.
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

_jq()  { jq "$@" "$CANARY_RINGS"; }
_agent_field() { _jq -r --arg a "$1" ".agents[\$a].$2"; }

# _require_agent <agent> — fail with a clear error if <agent> is not a key in the ring
# registry. Guards the dispatch surface: even a free-text agent (typo, or an input that
# outran the choice list) is validated against canary-rings.json rather than silently
# resolving to an empty frontier (#1045).
_require_agent() {
  if [ "$(_jq -r --arg a "$1" '.agents | has($a)')" != "true" ]; then
    echo "::error::unknown agent '$1' — not in $CANARY_RINGS. Known: $(_jq -r '.agents | keys | join(", ")')" >&2
    return 1
  fi
}

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

# candidate_cut_date <agent> <candidate_commit> — ISO-8601 Zulu tagger date of the
# immutable release tag <agent>/vX.Y.Z that points at the candidate commit. This is the
# per-candidate cumulative-window start (#548): health is measured since the candidate's
# OWN cut, NOT a rolling window — so a pre-cut failure of a prior version is excluded.
candidate_cut_date() {
  local agent="$1" commit="$2" obj deref cdate c
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
  _require_agent "$agent" || return 1
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
  agents="$(_jq -r '.agents? | keys[]' 2>/dev/null || true)"
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
  _require_agent "$agent" || return 1
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
    return 1
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
  echo "advancing $agent/$frontier -> ${cand:0:12}"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: git tag -f $agent/$frontier $cand && git push --force origin $agent/$frontier"
    return 0
  fi
  git tag -f "$agent/$frontier" "$cand"
  git push --force origin "$agent/$frontier"
  echo "promoted $agent/$frontier -> ${cand:0:12}"
  # Journal the move so the workflow records a GitHub Deployment per agent (traceability,
  # #502) — a journal (not a single GITHUB_OUTPUT triple) so a fleet-wide promote-all that
  # advances several agents in one tick records a Deployment for each, not just the last (#1045).
  if [ -n "${CANARY_PROMOTIONS_LOG:-}" ]; then
    jq -nc --arg a "$agent" --arg r "$frontier" --arg s "$cand" \
      '{agent:$a, ring:$r, sha:$s}' >> "$CANARY_PROMOTIONS_LOG"
  fi
}

# cmd_promote_all [--dry-run] — gated fleet-wide promote (#1045). The 4h timer runs this so
# the rollout completes autonomously: for EVERY agent in the registry, advance one ring iff
# its #548 gate is PROMOTE. It NEVER passes --override (a forced advance past a suspected
# regression stays a human decision) and honours the per-agent control block:
#   - gate.control.hold == true          → skip scheduled promotion (manual dispatch only)
#   - gate.control.allow_pre_existing     → cmd_promote already advances a BLOCKED+PRE_EXISTING
#                                           frontier (never REGRESSION)
# A BLOCKED+REGRESSION agent hard-stops (cmd_promote refuses without --override).
cmd_promote_all() {
  local agents agent hold
  agents="$(_jq -r '.agents? | keys[]' 2>/dev/null || true)"
  if [ -z "$agents" ]; then
    echo "no agents registered in $CANARY_RINGS — nothing to promote."; return 0
  fi
  echo "== canary-rollout promote-all: fleet-wide gated promote (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    hold="$(_jq -r --arg a "$agent" '.agents[$a].gate?.control?.hold // false')"
    if [ "$hold" = "true" ]; then
      echo "gate.control.hold=true — skipping scheduled promotion for $agent (manual dispatch only)."
      continue
    fi
    if ! cmd_promote "$agent" "$@"; then
      echo "::error::promote-all: hard-stop — '$agent' returned an error; aborting fleet promotion."
      return 1
    fi
  done <<< "$agents"
  return 0
}

cmd_rollback() {
  local agent="$1" ring="$2"; shift 2
  _require_agent "$agent" || return 1
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
