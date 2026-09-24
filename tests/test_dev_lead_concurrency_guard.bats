#!/usr/bin/env bats
# Regression guard for petry-projects/.github#443 (and #402/#450).
#
# The dev-lead issue-pickup race: GitHub fires one issues:labeled event per label
# added in a single API call. If the reusable's per-issue concurrency used
# cancel-in-progress:true, a later (non-dev-lead) labeled event could CANCEL the
# run triggered by the dev-lead label before it dispatched — a "successful"
# workflow that opened no PR. The fix (#450) is separate per-issue/per-PR lanes
# with cancel-in-progress: false, so same-lane events queue behind the active run
# and the pickup always finishes. These asserts fail loudly if anyone flips it back.

REUSABLE=".github/workflows/dev-lead-reusable.yml"

# concurrency_block: emit the lines of the `concurrency:` YAML block only, with
# comment-only lines stripped. Scoping the routing greps to this block means a
# routing string that drifts into a comment, or lands after the unconditional
# format('dev-lead-run-{0}', …) catch-all (where it is dead code), no longer
# keeps these guards green.
concurrency_block() {
  awk '/^concurrency:/{found=1} found && /^[a-z]/ && !/^concurrency:/{found=0} found{print}' "$REUSABLE" \
    | grep -Ev '^[[:space:]]*#' || true
}

# grep_concurrency <fixed-string>: succeed only if the string is present in the
# concurrency block (comments stripped). A bats function, so `run` can invoke it.
grep_concurrency() {
  concurrency_block | grep -F "$1"
}

@test "dev-lead reusable concurrency is cancel-in-progress: false (#443/#450)" {
  run grep -E '^[[:space:]]*cancel-in-progress:[[:space:]]*false[[:space:]]*$' "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "dev-lead reusable has NO cancel-in-progress: true (would re-open the #443 race)" {
  run grep -E '^[[:space:]]*cancel-in-progress:[[:space:]]*true[[:space:]]*$' "$REUSABLE"
  [ "$status" -eq 1 ]
}

@test "dev-lead reusable routes issue events to a per-issue lane (#402 lanes)" {
  run grep_concurrency "format('dev-lead-issue-{0}', github.event.issue.number)"
  [ "$status" -eq 0 ]
}

@test "dev-lead reusable routes repository_dispatch relays to a survivable retry lane (#1741)" {
  # A dropped-work re-dispatch must not land in the ordinary (cancellable) PR
  # lane, or concurrent PR traffic can cancel it while pending — the exact
  # defect that made the backstop unreliable (#1741 AC #3).
  run grep_concurrency "format('dev-lead-retry-pr-{0}', github.event.client_payload.pr_number)"
  [ "$status" -eq 0 ]
}

@test "dev-lead reusable routes repository_dispatch issue relays to a survivable retry lane (#1741)" {
  run grep_concurrency "format('dev-lead-retry-issue-{0}', github.event.client_payload.issue_number)"
  [ "$status" -eq 0 ]
}
