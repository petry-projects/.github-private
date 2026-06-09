#!/usr/bin/env bash
#
# initiative-driver.sh — dependency-aware label dispatcher for initiative epics.
#
# Turns an epic's sub-issue dependency graph (native GitHub "blocked by"
# relationships) into dev-lead pickups: it applies the `dev-lead` label to each
# OPEN sub-issue whose blockers are ALL closed, bounded by a max-in-flight cap.
# The dev-lead agent triggers on issues:[labeled]; this script is the only thing
# that decides WHEN that label goes on, so the per-item agent stays unchanged.
#
# Event-driven chain: dev-lead merges a PR -> "Closes #N" closes the issue ->
# this driver (on issues:[closed]) re-evaluates the DAG -> labels the now-ready
# successors. The schedule cron is only a safety net for missed close events.
#
# IMPORTANT — the trigger requires a PAT, not GITHUB_TOKEN:
#   GitHub does not start new workflow runs from events created by the default
#   GITHUB_TOKEN (loop prevention). The `dev-lead` label MUST be applied with a
#   PAT (GH_PAT_WORKFLOWS) or the resulting issues:[labeled] event will NOT
#   trigger dev-lead.yml. (Same class of bug as pr-review #463.)
#
# Safety gates:
#   - The epic must carry GATE_LABEL (default: initiative:auto). Without it the
#     driver no-ops, so Phase 1 stays human-driven until you opt in.
#   - Issues carrying HANDS_OFF_LABEL (dev-lead:hands-off) or HOLD_LABEL
#     (initiative:hold) are never released — they need a human.
#   - MAX_IN_FLIGHT bounds how many sub-issues run at once (cost / blast radius).
#
# The pure decision helpers (has_label, release_decision, slots_available) are
# defined at the top level so tests can `source` this file without executing it
# (see the source-guard at the bottom and tests/test_initiative_driver.bats).
#
set -euo pipefail

# ── pure decision helpers (sourced by tests; no side effects) ─────────────────

# has_label <csv-labels> <name> — exact match on a label name.
has_label() { printf '%s' "$1" | tr ',' '\n' | grep -qx "$2"; }

# release_decision <labels-csv> <open-blockers-csv> <hands_off> <hold>
# Echoes exactly one verdict and returns 0 iff the issue should be released:
#   ready                — releasable now
#   hands-off            — carries the hands-off label (needs a human)
#   hold                 — carries the hold label (human pause)
#   blocked:<csv>        — has open blockers (the listed issue numbers)
release_decision() {
  local labels="$1" open_blockers="$2" hands_off="$3" hold="$4"
  if has_label "$labels" "$hands_off"; then echo "hands-off"; return 1; fi
  if has_label "$labels" "$hold"; then echo "hold"; return 1; fi
  if [ -n "$open_blockers" ]; then echo "blocked:$open_blockers"; return 1; fi
  echo "ready"
}

# slots_available <max_in_flight> <in_flight> — echoes max(0, max - in_flight).
slots_available() {
  local s=$(("$1" - "$2"))
  [ "$s" -lt 0 ] && s=0
  echo "$s"
}

# ── gh-backed helpers ─────────────────────────────────────────────────────────

# labels_of <issue-number> — comma-joined label names.
labels_of() { gh api "repos/$REPO/issues/$1" --jq '[.labels[].name] | join(",")'; }

# open_blockers_of <issue-number> — comma-joined OPEN blocker issue numbers.
open_blockers_of() {
  gh api "repos/$REPO/issues/$1/dependencies/blocked_by" \
    --jq '[.[] | select(.state=="open") | .number] | join(",")'
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  REPO="${REPO:-petry-projects/.github-private}"
  EPIC="${EPIC:?EPIC issue number required}"
  CLOSED_ISSUE="${CLOSED_ISSUE:-}"
  DEV_LEAD_LABEL="${DEV_LEAD_LABEL:-dev-lead}"
  GATE_LABEL="${GATE_LABEL:-initiative:auto}"
  HANDS_OFF_LABEL="${HANDS_OFF_LABEL:-dev-lead:hands-off}"
  HOLD_LABEL="${HOLD_LABEL:-initiative:hold}"
  MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-2}"
  DRY_RUN="${DRY_RUN:-false}"

  log() { printf '%s\n' "$*"; }

  # gate: the epic must opt in
  if ! has_label "$(labels_of "$EPIC")" "$GATE_LABEL"; then
    log "Gate '$GATE_LABEL' not on epic #$EPIC — no-op (Phase-1 human-driven). Add the label to activate."
    return 0
  fi

  # enumerate sub-issues (all states) for the close-event membership check
  mapfile -t all_children < <(
    gh api --paginate "repos/$REPO/issues/$EPIC/sub_issues" --jq '.[].number'
  )
  if [ "${#all_children[@]}" -eq 0 ]; then
    log "Epic #$EPIC has no sub-issues — nothing to drive."
    return 0
  fi

  # on a close event, only act if the closed issue belongs to this epic
  if [ -n "$CLOSED_ISSUE" ]; then
    local in_epic=false n
    for n in "${all_children[@]}"; do
      [ "$n" = "$CLOSED_ISSUE" ] && in_epic=true && break
    done
    if [ "$in_epic" != true ]; then
      log "Closed issue #$CLOSED_ISSUE is not a sub-issue of epic #$EPIC — no-op."
      return 0
    fi
  fi

  # open sub-issues; count those already released (labeled, not yet closed)
  mapfile -t open_children < <(
    gh api --paginate "repos/$REPO/issues/$EPIC/sub_issues" \
      --jq '.[] | select(.state=="open") | .number'
  )
  declare -A released
  local in_flight=0 n
  for n in "${open_children[@]}"; do
    if has_label "$(labels_of "$n")" "$DEV_LEAD_LABEL"; then
      released[$n]=1
      in_flight=$((in_flight + 1))
    fi
  done
  log "Epic #$EPIC: ${#open_children[@]} open sub-issue(s); in-flight=$in_flight; cap=$MAX_IN_FLIGHT."

  # release ready sub-issues up to the available slots
  local slots released_now=0 verdict
  slots="$(slots_available "$MAX_IN_FLIGHT" "$in_flight")"
  for n in "${open_children[@]}"; do
    [ "$slots" -le 0 ] && break
    [ -n "${released[$n]:-}" ] && continue

    verdict="$(release_decision \
      "$(labels_of "$n")" "$(open_blockers_of "$n")" \
      "$HANDS_OFF_LABEL" "$HOLD_LABEL")" || true

    if [ "$verdict" != "ready" ]; then
      log "  #$n — skip: $verdict."
      continue
    fi

    if [ "$DRY_RUN" = "true" ]; then
      log "  #$n — READY (dry-run, not labeling)."
    else
      gh issue edit "$n" --repo "$REPO" --add-label "$DEV_LEAD_LABEL" >/dev/null
      log "  #$n — RELEASED: applied '$DEV_LEAD_LABEL'."
    fi
    slots=$((slots - 1))
    released_now=$((released_now + 1))
  done

  log "Released this run: $released_now."
}

# Run main only when executed directly, so tests can source the helpers.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
