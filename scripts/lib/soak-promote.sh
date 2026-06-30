#!/usr/bin/env bash
# soak-promote.sh (lib) — pure decision core for the autonomous fleet-wide
# soak-and-promote loop (#993; successor to the single-agent #501 canary core in
# scripts/lib/canary-rollout.sh).
#
# This file is side-effect-free and `source`-able: pure functions only (no I/O, no
# gh/git calls) so the override × gate × ceiling state machine can be unit-tested
# deterministically. The orchestrator scripts/soak-promote.sh sources this and feeds
# it the gate verdict + ring state it gathers from git/gh, plus the declarative
# overrides it reads from release/control.yml.
#
# The gate verdict tokens (PROMOTE | SOAKING | INVESTIGATE) come from the existing
# decide_gate core in scripts/lib/canary-rollout.sh — this layer maps them through
# the human overrides into the final per-reusable action.

# ring_index <ring> <ordered_csv> — echo the 0-based position of <ring> in the
# ordered channel list, or nothing + nonzero rc if not present.
ring_index() {
  local target="$1" csv="$2" i=0 ch
  local IFS=,
  for ch in $csv; do
    if [ "$ch" = "$target" ]; then echo "$i"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# version_gt <a> <b> — return 0 iff semver <a> is strictly greater than <b>.
# A leading "v" is tolerated on either side. Non-numeric components compare as 0.
version_gt() {
  local a="${1#v}" b="${2#v}"
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$a"
  IFS=. read -r b1 b2 b3 <<< "$b"
  a1=$((10#${a1:-0})); a2=$((10#${a2:-0})); a3=$((10#${a3:-0}))
  b1=$((10#${b1:-0})); b2=$((10#${b2:-0})); b3=$((10#${b3:-0}))
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

# plan_action <paused> <rollback_ver> <force_ring> <advance_ring>
#             <hold_at> <pin> <candidate_ver> <gate> <ordered_csv>
#
# Pure decision for ONE reusable. <advance_ring> is the ring the loop would move
# onto the candidate next (the first ring not yet aligned); empty ⇒ nothing to do.
# Echoes exactly one action token:
#   PAUSED            — global kill switch (control.pause) — wins over everything.
#   ROLLBACK <ver>    — one-shot human "move the channel back now".
#   FORCE <ring>      — one-shot human "advance now, bypass the gate".
#   COMPLETE          — no ring to advance: every ring already on the candidate.
#   HALT              — gate detected a regression (INVESTIGATE): fail-safe, the
#                       orchestrator auto-writes a hold + alerts.
#   PINNED            — candidate version is past control.pin: never auto-advance.
#   HOLD              — advance_ring is past control.hold_at: human ceiling reached.
#   WAIT              — gate is SOAKING: not enough healthy candidate volume yet.
#   ADVANCE <ring>    — gate PROMOTE and nothing blocks: advance advance_ring.
#
# Precedence rationale: pause is the strongest safety (loop does nothing). Explicit
# one-shot human directives (rollback, force) come next. A regression (HALT) is a
# fail-safe that overrides the human ceilings (pin/hold) — you always want to stop
# on a regression. Ceilings then gate an otherwise-eligible advance.
plan_action() {
  local paused="$1" rollback="$2" force_ring="$3" advance_ring="$4"
  local hold_at="$5" pin="$6" candidate_ver="$7" gate="$8" ord="$9"

  [ "$paused" = "true" ] && { echo "PAUSED"; return 0; }
  [ -n "$rollback" ]    && { echo "ROLLBACK $rollback"; return 0; }
  [ -n "$force_ring" ]  && { echo "FORCE $force_ring"; return 0; }
  [ -z "$advance_ring" ] && { echo "COMPLETE"; return 0; }
  [ "$gate" = "INVESTIGATE" ] && { echo "HALT"; return 0; }

  if [ -n "$pin" ] && [ -n "$candidate_ver" ] && version_gt "$candidate_ver" "$pin"; then
    echo "PINNED"; return 0
  fi
  if [ -n "$hold_at" ]; then
    local ni hi
    ni="$(ring_index "$advance_ring" "$ord" 2>/dev/null || echo -1)"
    hi="$(ring_index "$hold_at" "$ord" 2>/dev/null || echo -1)"
    if [ "$ni" -ge 0 ] && [ "$hi" -ge 0 ] && [ "$ni" -gt "$hi" ]; then
      echo "HOLD"; return 0
    fi
  fi

  case "$gate" in
    PROMOTE) echo "ADVANCE $advance_ring" ;;
    *)       echo "WAIT" ;;
  esac
}

# status_row <reusable> <frontier> <candidate_ver> <gate> <action> — render one
# markdown table row for release/STATUS.md / the job summary.
status_row() {
  printf '| %s | %s | %s | %s | %s |\n' \
    "$1" "${2:-—}" "${3:-—}" "${4:-—}" "${5:-—}"
}
