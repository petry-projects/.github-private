#!/usr/bin/env bash
# canary-rollout.sh (lib) — pure decision core for the ring-staged, health-gated
# promotion of agent releases (initiative #495, issue #501; rollback/observability #502).
#
# This file is side-effect-free and `source`-able: it defines pure functions only
# (no I/O, no gh/git calls) so the gate logic can be unit-tested deterministically.
# The orchestrator scripts/canary-rollout.sh sources this and feeds it real numbers
# gathered from `gh`.
#
# Gate standard: .github#548 (definitive spec). Per transition, evaluate on the
# SOURCE tier (the tier currently running the candidate), counting EXECUTED runs
# (success+failure; skipped/cancelled excluded) since the candidate's OWN cut:
#   - next->ring0:   dwell >= 4h  + sample >= clamp(round(0.25·avg), 3, 15)
#                    (dwell-only when the source tier has no caller)
#   - ring0->ring1:  dwell >= 8h  + CUMULATIVE-HEALTH-ONLY (fresh sample WAIVED)
#   - ring1->stable: dwell >= 12h + >= 1 ring1 run
#   - ALWAYS:        cumulative health = ZERO failures / ZERO startup_failures
#                    across EVERY tier since the candidate's own first cut.
# The dwell floors and sample fractions are registry-configurable per transition
# (see standards/canary-rings.json .gate); the numbers above are the defaults.

# clamp <value> <lo> <hi> — echo value bounded to [lo, hi].
clamp() {
  local v="$1" lo="$2" hi="$3"
  if [ "$v" -lt "$lo" ]; then echo "$lo"; return 0; fi
  if [ "$v" -gt "$hi" ]; then echo "$hi"; return 0; fi
  echo "$v"
}

# round_div <numerator> <denominator> — integer half-up rounding of n/d.
# Denominator must be > 0. Pure arithmetic, no bc.
round_div() {
  local n="$1" d="$2"
  if [ "${d:-0}" -le 0 ]; then echo 0; return 1; fi
  echo $(( (2 * n + d) / (2 * d) ))
}

# median_x2 <nums...> — echo 2×median as an exact integer (so an even-length set's
# half-integer median stays exact). Empty set → 0.
median_x2() {
  local n=$#
  [ "$n" -eq 0 ] && { echo 0; return 0; }
  local sorted
  sorted=$(printf '%s\n' "$@" | sort -n)
  local arr=()
  local x
  while IFS= read -r x; do arr+=("$x"); done <<< "$sorted"
  local mid=$(( n / 2 ))
  if [ $(( n % 2 )) -eq 1 ]; then
    echo $(( 2 * arr[mid] ))
  else
    echo $(( arr[mid - 1] + arr[mid] ))
  fi
}

# robust_sample_target <fraction_permille> <clamp_lo> <clamp_hi> <daily_counts...>
# Robust baseline: cap each per-day executed count at 3× the median day (neutralising
# spikes like a runaway loop day), take the mean of the capped days, then the sample
# target = clamp(round(fraction · avg), lo, hi). fraction is in per-mille (250 == 0.25).
#
# All arithmetic stays exact in integers by working in "×2" units for the median:
#   capped_x2(c) = min(2c, 3·median_x2)     [3·median compared without rounding]
#   avg          = (Σ capped_x2) / (2·N)
#   target_raw   = round(fraction/1000 · avg) = round(fraction·Σcapped_x2 / (2000·N))
robust_sample_target() {
  local frac="$1" lo="$2" hi="$3" cap_multiple="${4:-3}"; shift 4
  local n=$#
  [ "$n" -eq 0 ] && { clamp 0 "$lo" "$hi"; return 0; }
  local m2 cap3 c c2 sum2=0
  m2=$(median_x2 "$@")
  cap3=$(( cap_multiple * m2 ))
  for c in "$@"; do
    c2=$(( 2 * c ))
    [ "$c2" -gt "$cap3" ] && c2=$cap3
    sum2=$(( sum2 + c2 ))
  done
  # target_raw = round( frac · sum2 / (2000·n) )
  local denom=$(( 2000 * n )) target_raw
  target_raw=$(round_div $(( frac * sum2 )) "$denom")
  clamp "$target_raw" "$lo" "$hi"
}

# ── version-bump math (autocut front end, #1069) ──────────────────────────────
# Pure semver helpers used by `canary-rollout.sh autocut` to compute the next
# immutable release version from the highest existing <agent>/vX.Y.Z on the host.

# bump_version <version> <patch|minor|major> — echo MAJOR.MINOR.PATCH bumped by one
# level. Unknown/absent level defaults to patch (the v1 default). Input must be a
# strict MAJOR.MINOR.PATCH; callers validate the tag before calling.
bump_version() {
  local ver="$1" level="${2:-patch}" major=0 minor=0 patch=0
  IFS=. read -r major minor patch <<< "$ver"
  case "$level" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    *)     echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

# _semver_gt <a> <b> — return 0 iff semver a is strictly greater than b (compared
# by major, then minor, then patch). Equal is NOT greater.
_semver_gt() {
  local a1=0 a2=0 a3=0 b1=0 b2=0 b3=0
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

# max_semver <version...> — echo the highest strict MAJOR.MINOR.PATCH among the
# args, ignoring any token that is not a strict semver. Empty if none are valid.
max_semver() {
  local v hi=""
  for v in "$@"; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [ -z "$hi" ] || _semver_gt "$v" "$hi"; then hi="$v"; fi
  done
  echo "$hi"
}

# dwell_met <dwell_hours> <floor_hours> — echo 1 if the candidate has dwelled at
# least floor_hours on the source tier, else 0.
dwell_met() {
  local dwell="${1:-0}" floor="${2:-0}"
  if [ "$dwell" -ge "$floor" ]; then echo 1; else echo 0; fi
}

# iso_after <a> <b> — echo "yes" if ISO-8601 UTC timestamp a is at or after b, else
# "no". Zulu ISO-8601 strings sort lexically, so a per-candidate window is a string
# comparison against the candidate's cut date (excludes pre-cut runs of prior versions).
iso_after() {
  local a="$1" b="$2"
  if [[ "$a" > "$b" || "$a" == "$b" ]]; then echo "yes"; else echo "no"; fi
}

# decide_graduated <dwell_h> <dwell_floor> <sample> <sample_target> <sample_waived> \
#                  <cum_failures> <cum_startup_failures>
# Pure graduated gate for one transition. Echoes exactly one of:
#   BLOCKED — cumulative health breached (>=1 failure or startup_failure across any
#             tier since the candidate's cut). Never advances; a human/triage
#             classifies it as REGRESSION (rollback) or PRE_EXISTING (report only).
#   PROMOTE — clean AND dwell floor met AND (sample target met OR sample waived).
#   SOAKING — clean but dwell floor or sample target not yet met → wait.
# Health is checked first: a cumulative breach is never masked by dwell/sample.
decide_graduated() {
  local dwell="${1:-0}" floor="${2:-0}" sample="${3:-0}" target="${4:-0}"
  local waived="${5:-false}" cum_fail="${6:-0}" cum_startup="${7:-0}"
  if [ "$cum_fail" -gt 0 ] || [ "$cum_startup" -gt 0 ]; then
    echo "BLOCKED"; return 0
  fi
  local dwell_ok sample_ok
  dwell_ok=$(dwell_met "$dwell" "$floor")
  if [ "$waived" = "true" ] || [ "$sample" -ge "$target" ]; then sample_ok=1; else sample_ok=0; fi
  if [ "$dwell_ok" -eq 1 ] && [ "$sample_ok" -eq 1 ]; then
    echo "PROMOTE"; return 0
  fi
  echo "SOAKING"
}

# classify_failure <reusable_differs 0|1> <category> — triage an in-window failure
# (called only when decide_graduated returns BLOCKED). Echoes:
#   REGRESSION   — the candidate changed the reusable (differs=1) AND the failure is
#                  not a known environmental class → HALT, auto-hold, recommend rollback.
#   PRE_EXISTING — the reusable is byte-identical to the prior channel (differs=0), OR
#                  the failure is environmental (comment-cap / rate-limit / infra / data)
#                  → report, do NOT rollback, do NOT advance.
classify_failure() {
  local differs="${1:-0}" category="${2:-unknown}"
  case "$category" in
    comment-cap|rate-limit|infra|data) echo "PRE_EXISTING"; return 0 ;;
  esac
  if [ "$differs" = "1" ]; then echo "REGRESSION"; else echo "PRE_EXISTING"; fi
}

# benign_match <workflow_name> <failure_signature> <workflow_regex> <step_regex>
# Decide whether ONE in-window failure matches ONE known-benign failure-class allowlist
# entry (#1025 P2). A match requires a non-empty <step_regex> (guards against a match-all
# entry) that matches the failure signature (the failed step/error names), AND — when
# <workflow_regex> is non-empty — the run's workflow name. Echoes "yes" or "no".
# Pure: bash ERE only, no I/O. (Author regexes with explicit char classes, e.g. [Pp]ush,
# since ERE has no inline case-insensitivity flag.)
benign_match() {
  local wf="$1" sig="$2" wf_re="$3" step_re="$4"
  [ -z "$step_re" ] && { echo "no"; return 0; }
  if [ -n "$wf_re" ] && ! [[ "$wf" =~ $wf_re ]]; then echo "no"; return 0; fi
  if [[ "$sig" =~ $step_re ]]; then echo "yes"; else echo "no"; fi
}

# next_channel_in_order <current_channel> <ordered_channels_csv>
# Given the frontier channel and the ordered channel list (e.g. "next,ring0,ring1,stable"),
# echo the channel that a PROMOTE advances next, or empty if already at the last ring.
next_channel_in_order() {
  local current="$1" csv="$2"
  local prev="" ch found=""
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$csv"
  for ch in "${chan_array[@]}"; do
    if [ "$prev" = "$current" ]; then found="$ch"; break; fi
    prev="$ch"
  done
  echo "$found"
}

# transition_key <frontier_channel> <ordered_channels_csv>
# Echo the per-transition registry key "<source>-><frontier>", where source is the
# ring immediately below the frontier in ring order (the tier running the candidate).
# Empty if the frontier is the first channel (no source below it).
transition_key() {
  local frontier="$1" csv="$2"
  local prev="" ch
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$csv"
  for ch in "${chan_array[@]}"; do
    if [ "$ch" = "$frontier" ] && [ -n "$prev" ]; then echo "${prev}->${frontier}"; return 0; fi
    prev="$ch"
  done
  echo ""
}

# ── set-diff core (drift detection, #1082) ────────────────────────────────────
# The registry (.agents{}) is the MANUAL source of truth for what the canary pipeline
# manages; drift detection diffs it against the *-reusable.yml actually present on each
# host. Both sides of that diff are a plain set difference over whole-line strings.

# set_difference <set_a_newlines> <set_b_newlines> — echo each line of A that is NOT
# present in B (whole-line match; order + duplicates of A preserved, blank lines dropped).
# Pure: bash only (associative-array lookup), no gh/git I/O — deterministically unit-testable.
set_difference() {
  local a="$1" b="$2" line
  declare -A b_map
  while IFS= read -r line; do
    [ -n "$line" ] && b_map["$line"]=1
  done <<< "$b"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ -z "${b_map["$line"]:-}" ]]; then
      printf '%s\n' "$line"
    fi
  done <<< "$a"
}

# gate_summary_line <transition> <state> <dwell_h> <dwell_floor> <sample> <sample_target> <cum_fail> <cum_startup> [cum_benign]
# One-line human/observability row (used by `evaluate`, doubling as the #502 report).
# cum_benign (allowlisted failures excluded from cum_fail) is shown when provided.
gate_summary_line() {
  printf '%-14s %-9s dwell=%sh/%sh  sample=%s/%s  cum_fail=%s startup=%s benign=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-0}"
}
