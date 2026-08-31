#!/usr/bin/env bash
# hold-gate.sh — the single source of truth for the fleet's "human hold" labels.
#
# A held issue/PR is one a human has parked pending an explicit decision. It must
# never be auto-released to dev-lead (initiative-driver.sh) nor auto-picked-up by
# the agent (dev-lead-intent.sh). Before #1595 each caller re-implemented its own
# label check, so `needs-human-review` — the label github-actions applies as a
# hold — gated nothing at the release point and #1532 was shipped with the hold
# still attached. This library is that check, consulted by every caller so the
# hold set can never drift between them again.
#
# The default set mirrors the dev-lead interaction contract's `stop_markers`
# (personas/dev-lead/interaction.yml). Callers with additional holds (e.g. the
# driver's `initiative:hold`) override via HOLD_GATE_LABELS.
#
# This file is meant to be SOURCED, not executed.
#
# Env:
#   HOLD_GATE_LABELS  whitespace-separated hold-label set; overrides the default.

# hold_gate_labels — print the active hold-label set, one per line.
hold_gate_labels() {
  if [[ -n "${HOLD_GATE_LABELS:-}" ]]; then
    # Intentional word-splitting: the override is a whitespace-separated list.
    # shellcheck disable=SC2086
    printf '%s\n' ${HOLD_GATE_LABELS}
  else
    printf '%s\n' 'needs-human-review' 'dev-lead:needs-human' 'dev-lead:hands-off'
  fi
}

# hold_gate_first_match <newline-separated-issue-labels>
# Print the first active hold label present on the issue and return 0 (held);
# print nothing and return 1 when none is present (not held). Matching is exact
# per line — a hold label is matched literally, never as a substring or regex, so
# `needs-human` cannot match `needs-humanization` and a metachar in a configured
# label is treated as a literal.
hold_gate_first_match() {
  local issue_labels="$1" hold
  while IFS= read -r hold; do
    [[ -z "$hold" ]] && continue
    if [[ $'\n'"${issue_labels}"$'\n' == *$'\n'"${hold}"$'\n'* ]]; then
      printf '%s\n' "$hold"
      return 0
    fi
  done < <(hold_gate_labels)
  return 1
}
