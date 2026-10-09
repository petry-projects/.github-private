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

# Structural lookup (yq) so indentation/quoting changes cannot break the assertions.
_env_val() { yq -r "[.. | select(tag == \"!!map\" and has(\"$1\")) | .$1] | .[0]" "$WF"; }

@test "FORCE_REVIEW is exactly the explicit client_payload.force_review expression" {
  run _env_val FORCE_REVIEW
  [ "$status" -eq 0 ]
  [ "$output" = "\${{ github.event_name == 'repository_dispatch' && (github.event.client_payload.force_review == true || github.event.client_payload.force_review == 'true') && 'true' || 'false' }}" ]
}

@test "FORCE_REVIEW is never derived from the event name alone" {
  run _env_val FORCE_REVIEW
  [ "$status" -eq 0 ]
  [[ "$output" != *"github.event_name == 'repository_dispatch' && 'true'"* ]]
}

@test "a repository_dispatch without the flag gets only the narrow FORCE_RE_REVIEW bypass" {
  run _env_val FORCE_RE_REVIEW
  [ "$status" -eq 0 ]
  [ "$output" = "\${{ inputs.force_review || (github.event_name == 'repository_dispatch' && 'true') || 'false' }}" ]
}
