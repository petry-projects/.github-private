#!/usr/bin/env bats
# Unit tests for dev-lead-cancellation-metrics.sh (#1741 AC #5).
#
# The measurement must be repeatable, not a one-off manual API sweep: given a
# window of dev-lead workflow runs, compute the cancelled-run share and the
# "never really ran" share (cancelled within a short window of creation), so the
# post-change number can be recorded next to the 42% / 100-runs baseline.
#
# The script guards `main "$@"` behind a BASH_SOURCE check so sourcing exposes
# the pure aggregation helpers without hitting the network.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
METRICS_SCRIPT="$SCRIPT_DIR/scripts/dev-lead-cancellation-metrics.sh"

setup() {
  source "$METRICS_SCRIPT"
}

_run() {
  # _run <conclusion> <created_at> <updated_at>
  jq -nc --arg c "$1" --arg a "$2" --arg b "$3" \
    '{conclusion:$c, created_at:$a, updated_at:$b}'
}

@test "metrics: reproduces the 42%/100-runs shape from the baseline" {
  # 100 runs: 42 cancelled (30 of them within 60s of creation), rest completed.
  local runs='[]'
  local i
  for i in $(seq 1 30); do
    runs=$(jq -c ". += [$(_run cancelled 2026-09-08T11:00:00Z 2026-09-08T11:00:30Z)]" <<<"$runs")
  done
  for i in $(seq 1 12); do
    runs=$(jq -c ". += [$(_run cancelled 2026-09-08T11:00:00Z 2026-09-08T11:05:00Z)]" <<<"$runs")
  done
  for i in $(seq 1 58); do
    runs=$(jq -c ". += [$(_run success 2026-09-08T11:00:00Z 2026-09-08T11:08:00Z)]" <<<"$runs")
  done

  run compute_cancellation_metrics "$runs" 60
  [ "$status" -eq 0 ]
  [ "$(jq -r '.total' <<<"$output")" -eq 100 ]
  [ "$(jq -r '.cancelled' <<<"$output")" -eq 42 ]
  [ "$(jq -r '.cancelled_pct' <<<"$output")" -eq 42 ]
  [ "$(jq -r '.never_ran' <<<"$output")" -eq 30 ]
}

@test "metrics: empty run set yields zeros, no divide-by-zero" {
  run compute_cancellation_metrics '[]' 60
  [ "$status" -eq 0 ]
  [ "$(jq -r '.total' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.cancelled' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.cancelled_pct' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.never_ran' <<<"$output")" -eq 0 ]
}

@test "metrics: a cancelled run that ran a while is NOT counted as never-ran" {
  local runs; runs="[$(_run cancelled 2026-09-08T11:00:00Z 2026-09-08T11:10:00Z)]"
  run compute_cancellation_metrics "$runs" 60
  [ "$status" -eq 0 ]
  [ "$(jq -r '.cancelled' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.never_ran' <<<"$output")" -eq 0 ]
}

@test "metrics: window filter keeps only runs created in [since, until]" {
  local runs; runs="[$(_run cancelled 2026-09-08T10:00:00Z 2026-09-08T10:00:10Z),$(_run cancelled 2026-09-08T11:30:00Z 2026-09-08T11:30:10Z)]"
  run filter_runs_in_window "$runs" 2026-09-08T11:00:00Z 2026-09-08T12:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.[0].created_at' <<<"$output")" = "2026-09-08T11:30:00Z" ]
}
