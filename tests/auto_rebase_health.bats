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

  # Branch-rules JSON as returned by `gh api repos/{repo}/rules/branches/main`.
  # Contains a required_status_checks rule with strict=false (matches the current
  # post-#1864 state: the ruleset no longer demands up-to-date branches).
  RULES_STRICT_OFF_JSON='[
    {"type":"pull_request","parameters":{}},
    {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"lint"}]}}
  ]'
  # Same shape but strict re-armed (the #1864 one-field revert).
  RULES_STRICT_ON_JSON='[
    {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"lint"}]}}
  ]'

  # Base-merge-necessity PR set. Open non-draft non-Dependabot BEHIND PRs:
  #   #1 plain BEHIND (no queue, no label)                 → skippable when strict off
  #   #2 BEHIND + queued to merge (autoMergeRequest set)    → required always
  #   #3 BEHIND + carries the explicit request label        → required always
  #   #4 DIRTY (conflict path — never a base-merge candidate, AC #3)
  #   #5 BEHIND but DRAFT                                    → excluded
  #   #6 BEHIND but Dependabot-authored                     → excluded
  #   #7 CLEAN                                              → excluded (not BEHIND)
  BASE_MERGE_PRS_JSON='[
    {"number":1,"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"alice"},"labels":[],"autoMergeRequest":null},
    {"number":2,"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"bob"},"labels":[],"autoMergeRequest":{"enabledAt":"2026-09-20T00:00:00Z"}},
    {"number":3,"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"carol"},"labels":[{"name":"auto-rebase:ready"}],"autoMergeRequest":null},
    {"number":4,"mergeStateStatus":"DIRTY","isDraft":false,"author":{"login":"dan"},"labels":[],"autoMergeRequest":null},
    {"number":5,"mergeStateStatus":"BEHIND","isDraft":true,"author":{"login":"eve"},"labels":[],"autoMergeRequest":null},
    {"number":6,"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"dependabot[bot]"},"labels":[],"autoMergeRequest":null},
    {"number":7,"mergeStateStatus":"CLEAN","isDraft":false,"author":{"login":"frank"},"labels":[],"autoMergeRequest":null}
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
# strict_from_branch_rules — reads strict flag from repo config (AC #2)
# ---------------------------------------------------------------------------

@test "strict_from_branch_rules: strict policy on yields true" {
  run strict_from_branch_rules "$RULES_STRICT_ON_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "strict_from_branch_rules: strict policy off yields false" {
  run strict_from_branch_rules "$RULES_STRICT_OFF_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "strict_from_branch_rules: no required_status_checks rule yields false" {
  run strict_from_branch_rules '[{"type":"pull_request","parameters":{}}]'
  [ "$output" = "false" ]
}

@test "strict_from_branch_rules: empty/absent JSON yields false (no error)" {
  run strict_from_branch_rules ""
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "strict_from_branch_rules: unparseable input yields false (no error)" {
  run strict_from_branch_rules "not-json"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# ---------------------------------------------------------------------------
# summarize_base_merges — required vs skippable base merges (#1881 AC #4)
# ---------------------------------------------------------------------------

@test "summarize_base_merges: strict off — only queued/labelled PRs are required" {
  run summarize_base_merges "$BASE_MERGE_PRS_JSON" false
  [ "$status" -eq 0 ]
  # #2 queued + #3 labelled = 2 required; #1 plain BEHIND = 1 skippable.
  # DIRTY(#4), draft(#5), dependabot(#6), CLEAN(#7) all excluded.
  [ "$output" = "$(printf '2\t1')" ]
}

@test "summarize_base_merges: strict on — every eligible BEHIND PR is required" {
  run summarize_base_merges "$BASE_MERGE_PRS_JSON" true
  [ "$status" -eq 0 ]
  # #1,#2,#3 all required; 0 skippable.
  [ "$output" = "$(printf '3\t0')" ]
}

@test "summarize_base_merges: strict off, plain BEHIND PRs are all skippable" {
  run summarize_base_merges '[
    {"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"a"},"labels":[],"autoMergeRequest":null},
    {"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"b"},"labels":[],"autoMergeRequest":null}
  ]' false
  [ "$output" = "$(printf '0\t2')" ]
}

@test "summarize_base_merges: queued-to-merge PR is required even when strict off" {
  run summarize_base_merges '[
    {"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"a"},"labels":[],"autoMergeRequest":{"enabledAt":"x"}}
  ]' false
  [ "$output" = "$(printf '1\t0')" ]
}

@test "summarize_base_merges: explicit request label makes a PR required when strict off" {
  run summarize_base_merges '[
    {"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"a"},"labels":[{"name":"auto-rebase:ready"}],"autoMergeRequest":null}
  ]' false
  [ "$output" = "$(printf '1\t0')" ]
}

@test "summarize_base_merges: DIRTY PRs are not counted (conflict path unchanged, AC #3)" {
  run summarize_base_merges '[
    {"mergeStateStatus":"DIRTY","isDraft":false,"author":{"login":"a"},"labels":[],"autoMergeRequest":null}
  ]' false
  [ "$output" = "$(printf '0\t0')" ]
}

@test "summarize_base_merges: excludes draft and Dependabot BEHIND PRs" {
  run summarize_base_merges '[
    {"mergeStateStatus":"BEHIND","isDraft":true,"author":{"login":"a"},"labels":[],"autoMergeRequest":null},
    {"mergeStateStatus":"BEHIND","isDraft":false,"author":{"login":"dependabot[bot]"},"labels":[],"autoMergeRequest":null}
  ]' false
  [ "$output" = "$(printf '0\t0')" ]
}

@test "summarize_base_merges: empty/absent JSON returns zeros (no error)" {
  run summarize_base_merges "" false
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\t0')" ]
}

@test "summarize_base_merges: handles null/missing labels and author safely" {
  run summarize_base_merges '[
    {"mergeStateStatus":"BEHIND","isDraft":false,"author":null},
    {"mergeStateStatus":"BEHIND","isDraft":false}
  ]' false
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\t2')" ]
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

@test "render_report: truncation flag renders capped-count warning in merge-state section" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15 "$PRS_JSON" true 1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR list capped at 1000"* ]]
  [[ "$output" == *"undercount"* ]]
}

@test "render_report: no truncation flag suppresses capped-count warning" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15 "$PRS_JSON" false 1000
  [ "$status" -eq 0 ]
  [[ "$output" != *"PR list capped"* ]]
}

@test "render_report: surfaces base-merge necessity section and machine counters" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15 "$BASE_MERGE_PRS_JSON" false 1000 false
  [ "$status" -eq 0 ]
  [[ "$output" == *"Base-merge necessity"* ]]
  # strict off → #2 queued + #3 labelled required, #1 skippable
  [[ "$output" == *"base_merges_required=2"* ]]
  [[ "$output" == *"base_merges_skippable=1"* ]]
}

@test "render_report: base-merge section reflects strict re-armed (all required)" {
  run render_report "$COMMENTS_JSON" "$RUNS_JSON" 7 3 2026-06-15 "$BASE_MERGE_PRS_JSON" false 1000 true
  [ "$status" -eq 0 ]
  [[ "$output" == *"base_merges_required=3"* ]]
  [[ "$output" == *"base_merges_skippable=0"* ]]
}
