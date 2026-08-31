#!/usr/bin/env bash
# hold-release-audit.sh — pure scanner for the bounded "released while held" audit
# (#1595 AC #5).
#
# Given ONE issue's label-event stream (the `labeled`/`unlabeled` events from
# repos/<repo>/issues/<n>/events, as a JSON array on stdin), decide whether the
# `dev-lead` label was applied WHILE `needs-human-review` was attached — a silent
# release like #1532. The scan is bounded to releases at/after a --since date so
# it stays an audit, not a full-history sweep.
#
# This file is meant to be SOURCED. `jq` must be on PATH.
#
# Env / labels (overridable for reuse):
#   HOLD_RELEASE_AUDIT_HOLD_LABEL     default: needs-human-review
#   HOLD_RELEASE_AUDIT_RELEASE_LABEL  default: dev-lead

# hold_release_audit_scan <since-iso>  (events JSON array on stdin)
# Print one line per detected silent release:
#   held_since=<iso> released_at=<iso>
# Prints nothing when there is no violation. Always returns 0; callers test for
# non-empty output.
hold_release_audit_scan() {
  local since="$1"
  local hold="${HOLD_RELEASE_AUDIT_HOLD_LABEL:-needs-human-review}"
  local rel="${HOLD_RELEASE_AUDIT_RELEASE_LABEL:-dev-lead}"

  # Fold over the events in chronological order. ISO-8601 UTC (…Z) timestamps
  # sort chronologically as plain strings, so `sort_by(.ts)` is correct. Track
  # whether the hold label is currently attached and when it was applied; on a
  # `dev-lead` labeling event that lands while held and at/after --since, emit.
  jq -r \
    --arg since "$since" \
    --arg hold "$hold" \
    --arg rel "$rel" '
    ( [ .[] | {event: .event, name: (.label.name // ""), ts: (.created_at // "")} ]
      | map(select(.ts != ""))
      | sort_by(.ts) ) as $evs
    | reduce $evs[] as $e ({held: false, since_ts: "", out: []};
        if   $e.name == $hold and $e.event == "labeled"   then .held = true  | .since_ts = $e.ts
        elif $e.name == $hold and $e.event == "unlabeled" then .held = false
        elif $e.name == $rel  and $e.event == "labeled" and .held and ($e.ts >= $since)
          then .out += ["held_since=" + .since_ts + " released_at=" + $e.ts]
        else . end)
    | .out[]
  '
}
