#!/usr/bin/env bats
# Tests for scripts/auto_rebase_health.sh — pure counting / aggregation / rendering.
# Network I/O (main / repo + run discovery) is not exercised here.
# Run locally: bats tests/auto_rebase_health.bats

setup() {
  # shellcheck source=scripts/auto_rebase_health.sh
  source "${BATS_TEST_DIRNAME}/../scripts/auto_rebase_health.sh"

  # A representative comment set:
  #   4 conflict sentinels fired
  #   3 dev-lead rebase responses (2 applied + 1 failed)
  #   1 unrelated comment (must be ignored)
  COMMENTS_JSON='[
    {"body":"<!-- auto-rebase-conflict: main -->\nNeeds rebase.","created_at":"2026-06-10T01:00:00Z"},
    {"body":"<!-- auto-rebase-conflict: main -->\nNeeds rebase.","created_at":"2026-06-10T02:00:00Z"},
    {"body":"<!-- auto-rebase-conflict: main -->\nNeeds rebase.","created_at":"2026-06-11T03:00:00Z"},
    {"body":"<!-- auto-rebase-conflict: main -->\nNeeds rebase.","created_at":"2026-06-11T04:00:00Z"},
    {"body":"<!-- dev-lead-fix-reviews pr=10 sha=aaa intent=rebase status=applied -->\nRebase completed and pushed.","created_at":"2026-06-10T01:05:00Z"},
    {"body":"<!-- dev-lead-fix-reviews pr=11 sha=bbb intent=rebase status=applied -->\nRebase completed and pushed.","created_at":"2026-06-10T02:05:00Z"},
    {"body":"<!-- dev-lead-fix-reviews pr=12 sha=ccc intent=rebase status=failed -->\nApplication logic conflicts require human resolution.","created_at":"2026-06-11T03:05:00Z"},
    {"body":"LGTM, thanks!","created_at":"2026-06-11T05:00:00Z"}
  ]'

  # Auto-rebase run telemetry: 5 runs (4 success, 1 failure).
  RUNS_JSON='[
    {"conclusion":"success","created_at":"2026-06-10T00:00:00Z"},
    {"conclusion":"success","created_at":"2026-06-10T06:00:00Z"},
    {"conclusion":"failure","created_at":"2026-06-10T12:00:00Z"},
    {"conclusion":"success","created_at":"2026-06-11T00:00:00Z"},
    {"conclusion":"success","created_at":"2026-06-11T06:00:00Z"}
  ]'

  # Open-PR set for merge-state (BEHIND/DIRTY) observability:
  #   2 BEHIND (non-draft, human-authored) — counted
  #   1 DIRTY  (non-draft, human-authored) — counted
  #   1 CLEAN  (non-draft, human-authored) — ignored (not BEHIND/DIRTY)
  #   1 BEHIND but DRAFT                    — excluded
  #   1 DIRTY  but Dependabot-authored      — excluded
  PRS_JSON='[
    {"number":1,"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"don-petry"}},
    {"number":2,"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"alice"}},
    {"number":3,"mergeStateStatus":"DIRTY","isDraft":false,"author":{"login":"bob"}},
    {"number":4,"mergeStateStatus":"CLEAN","isDraft":false,"author":{"login":"carol"}},
    {"number":5,"mergeStateStatus":"BEHIND","isDraft":true,"author":{"login":"dave"}},
    {"number":6,"mergeStateStatus":"DIRTY","isDraft":false,"author":{"login":"dependabot[bot]"}}
  ]'
}

# ---------------------------------------------------------------------------
# count_marker
# ---------------------------------------------------------------------------

@test "count_marker: counts comments whose body contains the substring" {
  run count_marker "$COMMENTS_JSON" "<!-- auto-rebase-conflict:"
  [ "$status" -eq 0 ]
  [ "$output" -eq 4 ]
}

@test "count_marker: substring that appears in no comment returns 0" {
  run count_marker "$COMMENTS_JSON" "no-such-marker"
  [ "$output" -eq 0 ]
}

@test "count_marker: empty/absent JSON returns 0 (does not error)" {
  run count_marker "" "<!-- auto-rebase-conflict:"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# summarize_sentinels — sentinels / responses / applied
# ---------------------------------------------------------------------------

@test "summarize_sentinels: counts sentinels, rebase responses, applied" {
  run summarize_sentinels "$COMMENTS_JSON"
  [ "$status" -eq 0 ]
  # TSV: sentinels<TAB>responses<TAB>applied
  [ "$output" = "$(printf '4\t3\t2')" ]
}

# ---------------------------------------------------------------------------
# summarize_runs — total / success / failed
# ---------------------------------------------------------------------------

@test "summarize_runs: totals success and failure conclusions" {
  run summarize_runs "$RUNS_JSON"
  [ "$status" -eq 0 ]
  # TSV: total<TAB>success<TAB>failed
  [ "$output" = "$(printf '5\t4\t1')" ]
}

@test "summarize_runs: empty telemetry yields all zeros" {
  run summarize_runs "[]"
  [ "$output" = "$(printf '0\t0\t0')" ]
}

# ---------------------------------------------------------------------------
# summarize_merge_states — BEHIND / DIRTY over open non-draft non-Dependabot PRs
# ---------------------------------------------------------------------------

@test "summarize_merge_states: counts BEHIND and DIRTY over eligible PRs" {
  run summarize_merge_states "$PRS_JSON"
  [ "$status" -eq 0 ]
  # TSV: behind<TAB>dirty — 2 BEHIND, 1 DIRTY (draft + dependabot excluded)
  [ "$output" = "$(printf '2\t1')" ]
}

@test "summarize_merge_states: excludes draft PRs" {
  run summarize_merge_states '[
    {"mergeStateStatus":"BEHIND","isDraft":true,"author":{"login":"alice"}}
  ]'
  [ "$output" = "$(printf '0\t0')" ]
}

@test "summarize_merge_states: excludes Dependabot-authored PRs" {
  run summarize_merge_states '[
    {"mergeStateStatus":"DIRTY","isDraft":false,"author":{"login":"dependabot[bot]"}}
  ]'
  [ "$output" = "$(printf '0\t0')" ]
}

@test "summarize_merge_states: empty/absent JSON returns zeros (no error)" {
  run summarize_merge_states ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\t0')" ]
}

@test "summarize_merge_states: handles null or missing author safely" {
  run summarize_merge_states '[
    {"mergeStateStatus":"BEHIND","isDraft":false,"author":null},
    {"mergeStateStatus":"DIRTY","isDraft":false}
  ]'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\t1')" ]
}

# ---------------------------------------------------------------------------
# estimate_fanout — run_count × behind_prs
# ---------------------------------------------------------------------------

@test "estimate_fanout: multiplies run count by behind-PR estimate" {
  run estimate_fanout 5 3
  [ "$output" -eq 15 ]
}

@test "estimate_fanout: zero behind-PRs yields zero" {
  run estimate_fanout 5 0
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# fmt_rate — percentage with zero-denominator guard
# ---------------------------------------------------------------------------

@test "fmt_rate: renders an integer percentage" {
  run fmt_rate 3 4
  [ "$output" = "75%" ]
}

@test "fmt_rate: zero denominator renders n/a (no divide-by-zero)" {
  run fmt_rate 0 0
  [ "$output" = "n/a" ]
}

# ---------------------------------------------------------------------------
# render_report — full markdown
# ---------------------------------------------------------------------------

@test "render_report: includes both report sections" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == *"Agentic conflict-resolution rate"* ]]
  [[ "$output" == *"fan-out"* ]]
}

@test "render_report: surfaces sentinel and resolution counts" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15
  [[ "$output" == *"Sentinels fired"* ]]
  # 4 sentinels, 3 responses → 75% resolution rate
  [[ "$output" == *"75%"* ]]
}

@test "render_report: surfaces fan-out estimate and labels it an estimate" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15
  # 5 runs × 3 behind-PRs = 15 estimated re-runs
  [[ "$output" == *"15"* ]]
  [[ "$output" == *"estimate"* ]]
}

@test "render_report: zero sentinels renders n/a rate without erroring" {
  run render_report "[]" "[]" 7 0 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == *"n/a"* ]]
}

@test "render_report: surfaces BEHIND/DIRTY merge-state observability section" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15 "$PRS_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge-state"* ]]
  [[ "$output" == *"BEHIND"* ]]
  [[ "$output" == *"DIRTY"* ]]
}

@test "render_report: absent PR JSON renders merge-state counts as zero" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 0 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEHIND"* ]]
}
