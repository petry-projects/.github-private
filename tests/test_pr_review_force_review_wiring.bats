#!/usr/bin/env bats
# #2034: FORCE_REVIEW (the human break-glass that bypasses every review gate) must
# come from an explicit client_payload.force_review flag, never from the event
# name alone. The mention listener also dispatches for machine-added
# `review_requested: donpetry-bot` events; when the event name alone set
# FORCE_REVIEW, those runs approved past the maintainer-comment gate and the next
# run dismissed the approval — a loop until the per-PR budget ran out.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/.github/workflows/pr-review.yml"
}

_env_line() { grep -E "^[[:space:]]+$1:[[:space:]]" "$WF"; }

@test "FORCE_REVIEW requires an explicit client_payload.force_review flag" {
  run _env_line FORCE_REVIEW
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"github.event.client_payload.force_review == true"* ]]
  [[ "$output" == *"github.event.client_payload.force_review == 'true'"* ]]
}

@test "FORCE_REVIEW is never derived from the event name alone" {
  run _env_line FORCE_REVIEW
  [ "$status" -eq 0 ]
  [[ "$output" != *"github.event_name == 'repository_dispatch' && 'true'"* ]]
}

@test "a repository_dispatch without the flag gets only the narrow FORCE_RE_REVIEW bypass" {
  run _env_line FORCE_RE_REVIEW
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"inputs.force_review"* ]]
  [[ "$output" == *"github.event_name == 'repository_dispatch' && 'true'"* ]]
}
