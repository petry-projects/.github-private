#!/usr/bin/env bats
# Unit tests for scripts/lib/pr-review-outcomes.sh — the pure run-outcome-by-event
# breakdown surfaced on the pr-review health report (#1422 AC #1).
#
# These functions take run telemetry JSON on argv and write to stdout; no network.
# Run locally: bats tests/pr_review_outcomes.bats

setup() {
  # shellcheck source=scripts/lib/pr-review-outcomes.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/pr-review-outcomes.sh"

  # Representative run telemetry mirroring the 2026-08-02 3-hour observation
  # shape: cancellations dominated by pull_request_review and repository_dispatch,
  # with a mix of success/skipped. Conclusions/events use the exact strings the
  # GitHub Actions runs API returns.
  RUNS_JSON='[
    {"event":"pull_request_review","conclusion":"cancelled"},
    {"event":"pull_request_review","conclusion":"cancelled"},
    {"event":"pull_request_review","conclusion":"success"},
    {"event":"repository_dispatch","conclusion":"cancelled"},
    {"event":"repository_dispatch","conclusion":"success"},
    {"event":"pull_request","conclusion":"success"},
    {"event":"pull_request","conclusion":"skipped"},
    {"event":"check_suite","conclusion":"cancelled"},
    {"event":"check_suite","conclusion":"skipped"},
    {"event":"workflow_dispatch","conclusion":"failure"}
  ]'
}

# ---------------------------------------------------------------------------
# pr_review_outcomes_by_event — TSV aggregation
# ---------------------------------------------------------------------------

@test "outcomes_by_event: emits one sorted row per event plus a TOTAL row" {
  run pr_review_outcomes_by_event "$RUNS_JSON"
  [ "$status" -eq 0 ]
  # 5 distinct events + TOTAL
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 6 ]
  # Events are sorted; first data row is check_suite, last data row workflow_dispatch
  first_event=$(printf '%s\n' "$output" | head -n1 | cut -f1)
  [ "$first_event" = "check_suite" ]
  last_line=$(printf '%s\n' "$output" | tail -n1 | cut -f1)
  [ "$last_line" = "TOTAL" ]
}

@test "outcomes_by_event: per-event columns are success/cancelled/skipped/failure/total" {
  run pr_review_outcomes_by_event "$RUNS_JSON"
  # pull_request_review: 1 success, 2 cancelled, 0 skipped, 0 failure, 3 total
  row=$(printf '%s\n' "$output" | awk -F'\t' '$1=="pull_request_review"')
  [ "$row" = "$(printf 'pull_request_review\t1\t2\t0\t0\t3')" ]
}

@test "outcomes_by_event: TOTAL row aggregates every event" {
  run pr_review_outcomes_by_event "$RUNS_JSON"
  # totals: success 3, cancelled 4, skipped 2, failure 1, total 10
  total=$(printf '%s\n' "$output" | awk -F'\t' '$1=="TOTAL"')
  [ "$total" = "$(printf 'TOTAL\t3\t4\t2\t1\t10')" ]
}

@test "outcomes_by_event: #1421 regression — a cancelled pull_request_review run counts as cancelled, never failure" {
  # PR #1421: the review run conclusion was `cancelled` (evicted while pending),
  # but gh pr checks rendered it `fail`. The breakdown must classify it as
  # cancelled and must NOT inflate the failure column.
  local one_run='[{"event":"pull_request_review","conclusion":"cancelled"}]'
  run pr_review_outcomes_by_event "$one_run"
  [ "$status" -eq 0 ]
  row=$(printf '%s\n' "$output" | awk -F'\t' '$1=="pull_request_review"')
  # success 0, cancelled 1, skipped 0, failure 0, total 1
  [ "$row" = "$(printf 'pull_request_review\t0\t1\t0\t0\t1')" ]
}

@test "outcomes_by_event: empty array yields a zeroed TOTAL row only" {
  run pr_review_outcomes_by_event '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'TOTAL\t0\t0\t0\t0\t0')" ]
}

@test "outcomes_by_event: absent/empty argument is treated as empty (no error)" {
  run pr_review_outcomes_by_event ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'TOTAL\t0\t0\t0\t0\t0')" ]
}

@test "outcomes_by_event: runs with a null event fold into an 'unknown' bucket" {
  run pr_review_outcomes_by_event '[{"conclusion":"success"}]'
  [ "$status" -eq 0 ]
  row=$(printf '%s\n' "$output" | awk -F'\t' '$1=="unknown"')
  [ "$row" = "$(printf 'unknown\t1\t0\t0\t0\t1')" ]
}

# ---------------------------------------------------------------------------
# pr_review_render_outcome_mix — Markdown section
# ---------------------------------------------------------------------------

@test "render_outcome_mix: renders a table with a cancel-rate column and every event" {
  run pr_review_render_outcome_mix "$RUNS_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run-outcome mix by triggering event"* ]]
  [[ "$output" == *"cancelled"* ]]
  [[ "$output" == *"cancel %"* ]]
  [[ "$output" == *"pull_request_review"* ]]
  [[ "$output" == *"repository_dispatch"* ]]
  [[ "$output" == *"TOTAL"* ]]
}

@test "render_outcome_mix: TOTAL cancel-rate reflects 4 of 10 cancelled" {
  run pr_review_render_outcome_mix "$RUNS_JSON"
  # 4/10 = 40%
  [[ "$output" == *"40%"* ]]
}

@test "render_outcome_mix: empty telemetry renders the section with an n/a cancel rate (no divide-by-zero)" {
  run pr_review_render_outcome_mix '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run-outcome mix by triggering event"* ]]
  [[ "$output" == *"n/a"* ]]
}
