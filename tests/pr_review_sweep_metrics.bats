#!/usr/bin/env bats
# Unit tests for scripts/lib/pr-review-sweep-metrics.sh — the pure sweep-hit-rate
# metric surfaced on the pr-review health report (#1408, epic #1402).
#
# The scheduled pr-review-sweep path is narrowed to genuinely un-eventable cases
# (GitHub-App / cross-repo checks like SonarCloud that emit no workflow_run). The
# sweep-hit-rate = scheduled ticks that re-dispatched a review ÷ total scheduled
# ticks. A low rate confirms the timer stays exception-only; a rising rate signals
# an eventable case leaking onto the timer.
#
# These functions are PURE: they take telemetry / log text on argv and write to
# stdout. No network. Run locally: bats tests/pr_review_sweep_metrics.bats

setup() {
  # shellcheck source=scripts/lib/pr-review-sweep-metrics.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/pr-review-sweep-metrics.sh"

  # Representative sweep run telemetry: 4 scheduled ticks (2 of which dispatched a
  # review) plus event-fast-path (workflow_run) runs that must be excluded from the
  # scheduled-tick metric entirely.
  SWEEP_JSON='[
    {"event":"schedule","dispatched":1},
    {"event":"schedule","dispatched":0},
    {"event":"schedule","dispatched":2},
    {"event":"schedule","dispatched":0},
    {"event":"workflow_run","dispatched":1},
    {"event":"workflow_run","dispatched":0}
  ]'
}

# ---------------------------------------------------------------------------
# pr_review_sweep_hit_rate — TSV: ticks<TAB>hits<TAB>rate
# ---------------------------------------------------------------------------

@test "sweep_hit_rate: counts only scheduled ticks, hits = scheduled with dispatched>0" {
  run pr_review_sweep_hit_rate "$SWEEP_JSON"
  [ "$status" -eq 0 ]
  # 4 scheduled ticks, 2 hits, 50%
  [ "$output" = "$(printf '4\t2\t50%%')" ]
}

@test "sweep_hit_rate: workflow_run (fast-path) runs never count as scheduled ticks" {
  local only_fast='[{"event":"workflow_run","dispatched":3},{"event":"workflow_run","dispatched":0}]'
  run pr_review_sweep_hit_rate "$only_fast"
  [ "$status" -eq 0 ]
  # No scheduled ticks → n/a rate
  [ "$output" = "$(printf '0\t0\tn/a')" ]
}

@test "sweep_hit_rate: all-zero dispatched scheduled ticks yield 0% (healthy exception-only)" {
  local none='[{"event":"schedule","dispatched":0},{"event":"schedule","dispatched":0}]'
  run pr_review_sweep_hit_rate "$none"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2\t0\t0%%')" ]
}

@test "sweep_hit_rate: a dispatched field that is absent is treated as no-hit" {
  local absent='[{"event":"schedule"},{"event":"schedule","dispatched":1}]'
  run pr_review_sweep_hit_rate "$absent"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2\t1\t50%%')" ]
}

@test "sweep_hit_rate: empty array yields 0 ticks and n/a rate (no divide-by-zero)" {
  run pr_review_sweep_hit_rate '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\t0\tn/a')" ]
}

@test "sweep_hit_rate: absent/empty argument is treated as empty (no error)" {
  run pr_review_sweep_hit_rate ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\t0\tn/a')" ]
}

# ---------------------------------------------------------------------------
# pr_review_sweep_dispatched_from_log — parse the sweep summary line
# ---------------------------------------------------------------------------

@test "dispatched_from_log: parses the review-dispatch count from the summary line" {
  local log='=== PR Review Sweep ===
Sweep summary: inspected 12 candidate(s), 3 stuck-green, 2 review(s) dispatched.'
  run pr_review_sweep_dispatched_from_log "$log"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "dispatched_from_log: a zero-dispatch summary parses as 0" {
  local log='Sweep summary: inspected 5 candidate(s), 0 stuck-green, 0 review(s) dispatched.'
  run pr_review_sweep_dispatched_from_log "$log"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "dispatched_from_log: no summary line yields 0" {
  run pr_review_sweep_dispatched_from_log "no sweep summary here"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# pr_review_render_sweep_hit_rate — Markdown section + interpretation note
# ---------------------------------------------------------------------------

@test "render_sweep_hit_rate: emits the metric field and its documented interpretation" {
  run pr_review_render_sweep_hit_rate "$SWEEP_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sweep hit-rate"* ]]
  [[ "$output" == *"50%"* ]]
  # AC #3 interpretation must be documented alongside the metric.
  [[ "$output" == *"exception-only"* ]]
  [[ "$output" == *"leaking"* ]]
}

@test "render_sweep_hit_rate: empty telemetry renders the section with an n/a rate" {
  run pr_review_render_sweep_hit_rate '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sweep hit-rate"* ]]
  [[ "$output" == *"n/a"* ]]
}

@test "render_sweep_hit_rate: partial label when total_in_window exceeds measured ticks" {
  # 1 tick in telemetry, 3 total scheduled in window → cap or fetch errors omitted 2.
  local partial='[{"event":"schedule","dispatched":1}]'
  run pr_review_render_sweep_hit_rate "$partial" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"partial"* ]]
  [[ "$output" == *"1 of 3"* ]]
}

@test "render_sweep_hit_rate: no partial label when total_in_window matches measured ticks" {
  local partial='[{"event":"schedule","dispatched":1}]'
  run pr_review_render_sweep_hit_rate "$partial" 1
  [ "$status" -eq 0 ]
  [[ "$output" != *"partial"* ]]
}

@test "render_sweep_hit_rate: no partial label when total_in_window is 0 (not provided)" {
  run pr_review_render_sweep_hit_rate "$SWEEP_JSON" 0
  [ "$status" -eq 0 ]
  [[ "$output" != *"partial"* ]]
}
