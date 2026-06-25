#!/usr/bin/env bats
# Tests for scripts/lsp_pilot_report.sh — the LSP-pilot report renderer (#844).
#
# This story (Phase 3) consumes the story-2 comparison harness
# (scripts/lsp_pilot_compare.sh) and renders ONE comparison report across every
# candidate LSP server against the FROZEN LSP-off baseline. On top of the
# per-candidate harness it adds the three things the success metric needs that the
# harness alone does not produce:
#   * cold-start P50/P95 vs the 30s SLA (AC2),
#   * a per-candidate success-metric GO/NO-GO verdict — >=2x navigation-token
#     reduction AND no quality regression AND P95 <= 30s — with a data-favored
#     pick only when >=2 candidates are competitive (AC3),
#   * honest annotation of SLA auto-skip / degraded-MCP runs and a corpus-coverage
#     smoke check so a partial corpus can never read as a clean sweep (AC4).
#
# All functions are PURE (no network); these tests exercise them directly.
# Run locally: bats tests/lsp_pilot_report.bats

setup() {
  # shellcheck source=scripts/lsp_pilot_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lsp_pilot_report.sh"

  BASELINE="$(mktemp)" || { echo "Failed to create temp file"; exit 1; }
  CORPUS="$(mktemp)" || { echo "Failed to create temp file"; exit 1; }
  CAND_GOOD="$(mktemp)" || { echo "Failed to create temp file"; exit 1; }
  CAND_BAD="$(mktemp)" || { echo "Failed to create temp file"; exit 1; }

  # Frozen LSP-off baseline: three corpus PRs pinned by repo#number@sha.
  cat > "$BASELINE" <<'JSONL'
{"pr":"petry-projects/.github-private#801@aaa","variant":"lsp-off","candidate":"baseline","model":"claude-opus-4-7","input_tokens":40000,"cache_read_tokens":0,"output_tokens":3000,"nav_tokens":20000,"tool_calls":40,"findings":5,"false_positives":1,"cold_start_s":null,"wall_time_s":180.0}
{"pr":"petry-projects/.github-private#802@bbb","variant":"lsp-off","candidate":"baseline","model":"claude-opus-4-7","input_tokens":20000,"cache_read_tokens":0,"output_tokens":1500,"nav_tokens":10000,"tool_calls":20,"findings":3,"false_positives":0,"cold_start_s":null,"wall_time_s":120.0}
{"pr":"petry-projects/.github-private#803@ccc","variant":"lsp-off","candidate":"baseline","model":"claude-opus-4-7","input_tokens":10000,"cache_read_tokens":0,"output_tokens":800,"nav_tokens":5000,"tool_calls":10,"findings":2,"false_positives":0,"cold_start_s":null,"wall_time_s":60.0}
JSONL

  # The frozen corpus (cases.jsonl shape) — repo + pr_number + head_sha.
  cat > "$CORPUS" <<'JSONL'
{"id":"c-801","repo":"petry-projects/.github-private","pr_number":801,"head_sha":"aaa","description":"x","tags":[]}
{"id":"c-802","repo":"petry-projects/.github-private","pr_number":802,"head_sha":"bbb","description":"x","tags":[]}
{"id":"c-803","repo":"petry-projects/.github-private","pr_number":803,"head_sha":"ccc","description":"x","tags":[]}
JSONL

  # GOOD candidate: >=2x nav reduction, no FP regression, cold start within SLA.
  cat > "$CAND_GOOD" <<'JSONL'
{"pr":"petry-projects/.github-private#801@aaa","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":18000,"cache_read_tokens":0,"output_tokens":3000,"nav_tokens":8000,"tool_calls":12,"findings":5,"false_positives":1,"cold_start_s":8.0,"wall_time_s":90.0}
{"pr":"petry-projects/.github-private#802@bbb","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":9000,"cache_read_tokens":0,"output_tokens":1500,"nav_tokens":4000,"tool_calls":8,"findings":3,"false_positives":0,"cold_start_s":9.0,"wall_time_s":60.0}
{"pr":"petry-projects/.github-private#803@ccc","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":5000,"cache_read_tokens":0,"output_tokens":800,"nav_tokens":2000,"tool_calls":5,"findings":2,"false_positives":0,"cold_start_s":7.0,"wall_time_s":30.0}
JSONL

  # BAD candidate: one PR SLA-skipped (cold start 34s > 30), one PR MCP-degraded,
  # net nav reduction below 2x and a P95 SLA breach.
  cat > "$CAND_BAD" <<'JSONL'
{"pr":"petry-projects/.github-private#801@aaa","variant":"lsp-on","candidate":"serena","model":"claude-opus-4-7","input_tokens":38000,"cache_read_tokens":0,"output_tokens":3000,"nav_tokens":20000,"tool_calls":40,"findings":5,"false_positives":1,"cold_start_s":34.0,"wall_time_s":180.0,"lsp_skipped":true,"skip_reason":"cold-start 34.0s exceeded 30s P95 SLA"}
{"pr":"petry-projects/.github-private#802@bbb","variant":"lsp-on","candidate":"serena","model":"claude-opus-4-7","input_tokens":9000,"cache_read_tokens":0,"output_tokens":1500,"nav_tokens":5000,"tool_calls":10,"findings":3,"false_positives":0,"cold_start_s":12.0,"wall_time_s":70.0}
{"pr":"petry-projects/.github-private#803@ccc","variant":"lsp-on","candidate":"serena","model":"claude-opus-4-7","input_tokens":10000,"cache_read_tokens":0,"output_tokens":800,"nav_tokens":5000,"tool_calls":10,"findings":2,"false_positives":0,"cold_start_s":null,"wall_time_s":60.0,"mcp_degraded":true,"skip_reason":"MCP server init failed; review continued on base capabilities"}
JSONL
}

teardown() {
  rm -f "$BASELINE" "$CORPUS" "$CAND_GOOD" "$CAND_BAD"
}

# ---------------------------------------------------------------------------
# lpr_coldstart_stats — cold-start P50/P95/max over a candidate run (AC2)
# ---------------------------------------------------------------------------

@test "lpr_coldstart_stats: computes P50/P95/max over non-null cold starts" {
  run lpr_coldstart_stats "$CAND_GOOD"
  [ "$status" -eq 0 ]
  # cold starts 7,8,9 -> p50=8.0 p95=9.0 max=9.0 n=3
  [[ "$output" == "8.0	9.0	9.0	3" ]]
}

@test "lpr_coldstart_stats: emits NA columns when no cold-start data" {
  run lpr_coldstart_stats "$BASELINE"
  [ "$status" -eq 0 ]
  [[ "$output" == "NA	NA	NA	0" ]]
}

# ---------------------------------------------------------------------------
# lpr_within_sla — P95 cold-start vs the 30s SLA (AC2)
# ---------------------------------------------------------------------------

@test "lpr_within_sla: passes when P95 is within the 30s SLA" {
  run lpr_within_sla "$CAND_GOOD"
  [ "$status" -eq 0 ]
}

@test "lpr_within_sla: fails (non-zero) when P95 exceeds the 30s SLA" {
  run lpr_within_sla "$CAND_BAD"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# lpr_skip_annotations — SLA-skip / MCP-degraded runs are surfaced (AC4)
# ---------------------------------------------------------------------------

@test "lpr_skip_annotations: surfaces SLA-skip and MCP-degraded runs with reasons" {
  run lpr_skip_annotations "$CAND_BAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#801@aaa"* ]]
  [[ "$output" == *"sla-skip"* ]]
  [[ "$output" == *"#803@ccc"* ]]
  [[ "$output" == *"mcp-degraded"* ]]
}

@test "lpr_skip_annotations: emits nothing for a clean run" {
  run lpr_skip_annotations "$CAND_GOOD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# lpr_coverage — every corpus PR covered or an explicit skip reason (AC4 smoke)
# ---------------------------------------------------------------------------

@test "lpr_coverage: reports a clean candidate as fully covered" {
  run lpr_coverage "$CORPUS" "$CAND_GOOD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#801@aaa"*"COVERED"* ]]
}

@test "lpr_coverage: a skipped/degraded run is annotated, not dropped" {
  run lpr_coverage "$CORPUS" "$CAND_BAD"
  [ "$status" -eq 0 ]
  # The SLA-skip and the MCP-degraded PRs must be visible with a reason.
  [[ "$output" == *"SKIPPED"* ]]
}

@test "lpr_coverage: a corpus PR with no candidate run is flagged MISSING and fails" {
  # Drop PR #803 from the candidate so a corpus PR is uncovered.
  grep -v '#803@ccc' "$CAND_GOOD" > "${CAND_GOOD}.partial"
  run lpr_coverage "$CORPUS" "${CAND_GOOD}.partial"
  rm -f "${CAND_GOOD}.partial"
  [ "$status" -ne 0 ]
  [[ "$output" == *"#803@ccc"*"MISSING"* ]]
}

# ---------------------------------------------------------------------------
# lpr_token_ratio — overall navigation-token reduction vs the frozen baseline
# ---------------------------------------------------------------------------

@test "lpr_token_ratio: reports the aggregate nav-token reduction ratio" {
  run lpr_token_ratio "$BASELINE" "$CAND_GOOD"
  [ "$status" -eq 0 ]
  # baseline nav 35000 / candidate nav 14000 = 2.50
  [[ "$output" == "2.50" ]]
}

# ---------------------------------------------------------------------------
# lpr_quality_regressed — false-positive precision proxy vs the frozen baseline
# ---------------------------------------------------------------------------

@test "lpr_quality_regressed: clean run does not regress quality" {
  run lpr_quality_regressed "$BASELINE" "$CAND_GOOD"
  [ "$status" -eq 0 ]
}

@test "lpr_quality_regressed: a run with more false positives regresses" {
  printf '%s\n' '{"pr":"petry-projects/.github-private#801@aaa","variant":"lsp-on","candidate":"x","model":"claude-opus-4-7","input_tokens":18000,"cache_read_tokens":0,"output_tokens":3000,"nav_tokens":8000,"tool_calls":12,"findings":7,"false_positives":3,"cold_start_s":8.0,"wall_time_s":90.0}' > "$CAND_GOOD"
  run lpr_quality_regressed "$BASELINE" "$CAND_GOOD"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# lpr_candidate_verdict — the success-metric GO/NO-GO (AC3)
# ---------------------------------------------------------------------------

@test "lpr_candidate_verdict: GO when token target met, quality held, within SLA" {
  run lpr_candidate_verdict "$BASELINE" "$CAND_GOOD" agent-lsp
  [ "$status" -eq 0 ]
  [[ "$output" == "GO"* ]]
}

@test "lpr_candidate_verdict: NO-GO on an SLA breach even with a token win" {
  run lpr_candidate_verdict "$BASELINE" "$CAND_BAD" serena
  [ "$status" -ne 0 ]
  [[ "$output" == "NO-GO"* ]]
  [[ "$output" == *"SLA"* ]]
}

# ---------------------------------------------------------------------------
# render_pilot_report — the single multi-candidate report (AC2/AC3/AC4)
# ---------------------------------------------------------------------------

@test "render_pilot_report: renders each candidate against the frozen baseline" {
  run render_pilot_report "$BASELINE" "$CORPUS" "agent-lsp=$CAND_GOOD" "serena=$CAND_BAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-lsp"* ]]
  [[ "$output" == *"serena"* ]]
}

@test "render_pilot_report: states the success metric and the 30s SLA verbatim target" {
  run render_pilot_report "$BASELINE" "$CORPUS" "agent-lsp=$CAND_GOOD"
  [[ "$output" == *"2x"* || "$output" == *"2×"* ]]
  [[ "$output" == *"30s"* ]]
}

@test "render_pilot_report: surfaces cold-start P50/P95 per candidate" {
  run render_pilot_report "$BASELINE" "$CORPUS" "agent-lsp=$CAND_GOOD"
  [[ "$output" == *"P50"* ]]
  [[ "$output" == *"P95"* ]]
}

@test "render_pilot_report: reports a per-candidate GO/NO-GO verdict" {
  run render_pilot_report "$BASELINE" "$CORPUS" "agent-lsp=$CAND_GOOD" "serena=$CAND_BAD"
  [[ "$output" == *"GO"* ]]
  [[ "$output" == *"NO-GO"* ]]
}

@test "render_pilot_report: annotates SLA-skipped and degraded runs (no silent omission)" {
  run render_pilot_report "$BASELINE" "$CORPUS" "serena=$CAND_BAD"
  [[ "$output" == *"sla-skip"* || "$output" == *"SLA"* ]]
  [[ "$output" == *"degraded"* ]]
}

@test "render_pilot_report: does NOT pick a favored candidate when only one is GO" {
  # agent-lsp GO, serena NO-GO -> a single passing candidate, no head-to-head pick.
  run render_pilot_report "$BASELINE" "$CORPUS" "agent-lsp=$CAND_GOOD" "serena=$CAND_BAD"
  [[ "$output" != *"Data favored:"* ]]
}

@test "render_pilot_report: picks the data-favored candidate only when two are competitive" {
  # A second GO candidate with a smaller token win than agent-lsp.
  local cand2; cand2="$(mktemp)" || { echo "Failed to create temp file"; exit 1; }
  cat > "$cand2" <<'JSONL'
{"pr":"petry-projects/.github-private#801@aaa","variant":"lsp-on","candidate":"serena","model":"claude-opus-4-7","input_tokens":20000,"cache_read_tokens":0,"output_tokens":3000,"nav_tokens":9000,"tool_calls":14,"findings":5,"false_positives":1,"cold_start_s":10.0,"wall_time_s":95.0}
{"pr":"petry-projects/.github-private#802@bbb","variant":"lsp-on","candidate":"serena","model":"claude-opus-4-7","input_tokens":10000,"cache_read_tokens":0,"output_tokens":1500,"nav_tokens":4500,"tool_calls":9,"findings":3,"false_positives":0,"cold_start_s":11.0,"wall_time_s":65.0}
{"pr":"petry-projects/.github-private#803@ccc","variant":"lsp-on","candidate":"serena","model":"claude-opus-4-7","input_tokens":5000,"cache_read_tokens":0,"output_tokens":800,"nav_tokens":2200,"tool_calls":6,"findings":2,"false_positives":0,"cold_start_s":9.0,"wall_time_s":32.0}
JSONL
  run render_pilot_report "$BASELINE" "$CORPUS" "agent-lsp=$CAND_GOOD" "serena=$cand2"
  rm -f "$cand2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Data favored: agent-lsp"* ]]
}
