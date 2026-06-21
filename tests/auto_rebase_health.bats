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

  # PR eligibility metadata: 4 open non-Dependabot PRs, 2 eligible.
  #   approved non-draft        → eligible
  #   ready-labelled non-draft  → eligible
  #   plain non-draft           → not eligible
  #   approved but draft        → not eligible (draft)
  PRS_META_JSON='[
    {"draft":false,"approved":true,"labels":[]},
    {"draft":false,"approved":false,"labels":[{"name":"auto-rebase:ready"}]},
    {"draft":false,"approved":false,"labels":[{"name":"bug"}]},
    {"draft":true,"approved":true,"labels":[]}
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

# ---------------------------------------------------------------------------
# fmt_reduction — behind→eligible multiplier reduction
# ---------------------------------------------------------------------------

@test "fmt_reduction: renders an integer percentage decrease" {
  run fmt_reduction 8 2
  [ "$output" = "75%" ]
}

@test "fmt_reduction: no reduction renders 0%" {
  run fmt_reduction 5 5
  [ "$output" = "0%" ]
}

@test "fmt_reduction: zero base renders n/a (no divide-by-zero)" {
  run fmt_reduction 0 0
  [ "$output" = "n/a" ]
}

# ---------------------------------------------------------------------------
# pr_has_current_approval — current review state wins
# ---------------------------------------------------------------------------

@test "pr_has_current_approval: a lone APPROVED review counts as approved" {
  run pr_has_current_approval '[{"user":{"login":"a"},"state":"APPROVED"}]'
  [ "$status" -eq 0 ]
}

@test "pr_has_current_approval: a later CHANGES_REQUESTED cancels an earlier APPROVED (same user)" {
  run pr_has_current_approval '[{"user":{"login":"a"},"state":"APPROVED"},{"user":{"login":"a"},"state":"CHANGES_REQUESTED"}]'
  [ "$status" -ne 0 ]
}

@test "pr_has_current_approval: one user's APPROVED survives another's CHANGES_REQUESTED" {
  run pr_has_current_approval '[{"user":{"login":"a"},"state":"APPROVED"},{"user":{"login":"b"},"state":"CHANGES_REQUESTED"}]'
  [ "$status" -eq 0 ]
}

@test "pr_has_current_approval: COMMENTED-only reviews are not an approval" {
  run pr_has_current_approval '[{"user":{"login":"a"},"state":"COMMENTED"}]'
  [ "$status" -ne 0 ]
}

@test "pr_has_current_approval: empty/absent reviews are not an approval" {
  run pr_has_current_approval ""
  [ "$status" -ne 0 ]
}

@test "pr_has_current_approval: null-user review is skipped without error" {
  run pr_has_current_approval '[{"user":null,"state":"APPROVED"}]'
  [ "$status" -ne 0 ]
}

@test "pr_has_current_approval: null-user review does not block a valid approval" {
  run pr_has_current_approval '[{"user":null,"state":"CHANGES_REQUESTED"},{"user":{"login":"a"},"state":"APPROVED"}]'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# count_eligible — non-draft AND (approved OR ready label)
# ---------------------------------------------------------------------------

@test "count_eligible: counts non-draft approved-or-labelled PRs" {
  run count_eligible "$PRS_META_JSON" "auto-rebase:ready"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "count_eligible: a different ready label drops the label-only PR" {
  run count_eligible "$PRS_META_JSON" "some-other-label"
  [ "$output" -eq 1 ]
}

@test "count_eligible: empty/absent JSON returns 0 (does not error)" {
  run count_eligible "" "auto-rebase:ready"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# render_report — post-restriction section (eligibility supplied)
# ---------------------------------------------------------------------------

@test "render_report: post-restriction section appears only when eligible is supplied" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 8 2026-06-15
  [[ "$output" != *"Post-restriction"* ]]

  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 8 2026-06-15 2 auto-rebase:ready
  [[ "$output" == *"Post-restriction fan-out"* ]]
}

@test "render_report: post-restriction reports reduction and meets the ≥50% metric" {
  # 8 behind → 2 eligible = 75% reduction (≥50% → met); 5 runs × 2 = 10 restricted re-runs
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 8 2026-06-15 2 auto-rebase:ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"75%"* ]]
  [[ "$output" == *"met"* ]]
  [[ "$output" == *"~10"* ]]
}

@test "render_report: sub-50% reduction is reported as not met" {
  # 4 behind → 3 eligible = 25% reduction (< 50% → not met)
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 4 2026-06-15 3 auto-rebase:ready
  [[ "$output" == *"not met"* ]]
}
