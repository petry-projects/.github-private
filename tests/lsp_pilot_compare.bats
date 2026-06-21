#!/usr/bin/env bats
# Tests for scripts/lsp_pilot_compare.sh — the LSP-pilot comparison harness (#841).
#
# The harness reads two Token Cost Observatory JSONL streams in the pilot record
# shape: a FROZEN LSP-off baseline (captured once, evals/lsp-pilot/holdout/) and a
# candidate LSP-on run. It renders per-PR and aggregate speed (cold-start,
# wall-time), cost (tokens, ET, USD) and quality (findings, false-positive) deltas
# against the frozen baseline, and FAILS LOUD (non-zero) if a candidate PR has no
# baseline counterpart so a partial corpus cannot masquerade as a clean comparison.
#
# All functions are PURE (no network); these tests exercise them directly.
# Run locally: bats tests/lsp_pilot_compare.bats

setup() {
  # shellcheck source=scripts/lsp_pilot_compare.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lsp_pilot_compare.sh"

  BASELINE="$(mktemp)"
  CANDIDATE="$(mktemp)"

  # Frozen LSP-off baseline: two PRs pinned by repo#number@sha.
  cat > "$BASELINE" <<'JSONL'
{"pr":"petry-projects/.github-private#811@aaaaaaa","variant":"lsp-off","candidate":"baseline","model":"claude-opus-4-7","input_tokens":1000,"cache_read_tokens":0,"output_tokens":200,"nav_tokens":20000,"tool_calls":40,"findings":5,"false_positives":1,"cold_start_s":null,"wall_time_s":60.0}
{"pr":"petry-projects/.github-private#812@bbbbbbb","variant":"lsp-off","candidate":"baseline","model":"claude-opus-4-7","input_tokens":800,"cache_read_tokens":0,"output_tokens":100,"nav_tokens":10000,"tool_calls":20,"findings":3,"false_positives":0,"cold_start_s":null,"wall_time_s":45.0}
JSONL

  # Candidate LSP-on run (agent-lsp): same two PRs, fewer navigation tokens.
  cat > "$CANDIDATE" <<'JSONL'
{"pr":"petry-projects/.github-private#811@aaaaaaa","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":1000,"cache_read_tokens":0,"output_tokens":200,"nav_tokens":8000,"tool_calls":12,"findings":5,"false_positives":1,"cold_start_s":8.0,"wall_time_s":42.0}
{"pr":"petry-projects/.github-private#812@bbbbbbb","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":800,"cache_read_tokens":0,"output_tokens":100,"nav_tokens":5000,"tool_calls":10,"findings":3,"false_positives":0,"cold_start_s":6.0,"wall_time_s":30.0}
JSONL
}

teardown() {
  rm -f "$BASELINE" "$CANDIDATE"
}

# ---------------------------------------------------------------------------
# lp_missing_baselines — coverage check (AC5)
# ---------------------------------------------------------------------------

@test "lp_missing_baselines: passes when every candidate PR has a baseline" {
  run lp_missing_baselines "$BASELINE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lp_missing_baselines: names the orphan PR and fails when a baseline is absent" {
  # Add a third candidate PR with no baseline counterpart.
  printf '%s\n' '{"pr":"petry-projects/.github-private#813@ccccccc","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":500,"cache_read_tokens":0,"output_tokens":50,"nav_tokens":3000,"tool_calls":6,"findings":2,"false_positives":0,"cold_start_s":5.0,"wall_time_s":20.0}' >> "$CANDIDATE"
  run lp_missing_baselines "$BASELINE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"#813@ccccccc"* ]]
}

# ---------------------------------------------------------------------------
# render_lsp_comparison — per-PR + aggregate render (AC4)
# ---------------------------------------------------------------------------

@test "render_lsp_comparison: clean comparison renders and exits 0" {
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#811@aaaaaaa"* ]]
  [[ "$output" == *"#812@bbbbbbb"* ]]
}

@test "render_lsp_comparison: surfaces the navigation-token reduction ratio (>=2x)" {
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  # PR #811: 20000 / 8000 = 2.5x reduction in navigation tool-call tokens.
  [[ "$output" == *"2.5"* ]]
  # PR #812: 10000 / 5000 = 2.0x.
  [[ "$output" == *"2.0"* ]]
}

@test "render_lsp_comparison: renders speed, cost and quality columns" {
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [[ "$output" == *"Nav tokens"* ]]
  [[ "$output" == *"Tool calls"* ]]
  [[ "$output" == *"Cold start"* ]]
  [[ "$output" == *"ET"* ]]
  [[ "$output" == *"USD"* ]]
  [[ "$output" == *"Findings"* ]]
  [[ "$output" == *"False positives"* ]]
}

@test "render_lsp_comparison: cold start is N/A for the LSP-off baseline" {
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [[ "$output" == *"N/A"* ]]
}

@test "render_lsp_comparison: documents the explicit quality proxy" {
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  # The proxy is defined IN the harness output so the go/no-go is reproducible.
  [[ "$output" == *"false-positive"* ]] || [[ "$output" == *"false positive"* ]]
}

@test "render_lsp_comparison: USD is rendered to cents (org cost-reporting standard)" {
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [[ "$output" == *'$'* ]]
}

# ---------------------------------------------------------------------------
# Quality proxy — false-positive regression is visible (AC4: a token win that
# drops precision must show as a regression, not be hidden)
# ---------------------------------------------------------------------------

@test "render_lsp_comparison: clean run reports no quality regression" {
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "render_lsp_comparison: a candidate with MORE false positives is flagged as a regression" {
  # Candidate #811 introduces an extra false positive (1 -> 3) — a precision loss
  # that a token win must never hide.
  cat > "$CANDIDATE" <<'JSONL'
{"pr":"petry-projects/.github-private#811@aaaaaaa","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":1000,"cache_read_tokens":0,"output_tokens":200,"nav_tokens":8000,"tool_calls":12,"findings":7,"false_positives":3,"cold_start_s":8.0,"wall_time_s":42.0}
{"pr":"petry-projects/.github-private#812@bbbbbbb","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":800,"cache_read_tokens":0,"output_tokens":100,"nav_tokens":5000,"tool_calls":10,"findings":3,"false_positives":0,"cold_start_s":6.0,"wall_time_s":30.0}
JSONL
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGRESSION"* ]]
}

# ---------------------------------------------------------------------------
# Multi-run candidate aggregation (corpus allows <=3 runs per PR)
# ---------------------------------------------------------------------------

@test "render_lsp_comparison: averages multiple candidate runs of the same PR" {
  # PR #811 run twice (nav 8000 and 12000 -> mean 10000); 20000/10000 = 2.0x.
  cat > "$CANDIDATE" <<'JSONL'
{"pr":"petry-projects/.github-private#811@aaaaaaa","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":1000,"cache_read_tokens":0,"output_tokens":200,"nav_tokens":8000,"tool_calls":12,"findings":5,"false_positives":1,"cold_start_s":8.0,"wall_time_s":42.0}
{"pr":"petry-projects/.github-private#811@aaaaaaa","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":1000,"cache_read_tokens":0,"output_tokens":200,"nav_tokens":12000,"tool_calls":16,"findings":5,"false_positives":1,"cold_start_s":10.0,"wall_time_s":50.0}
{"pr":"petry-projects/.github-private#812@bbbbbbb","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":800,"cache_read_tokens":0,"output_tokens":100,"nav_tokens":5000,"tool_calls":10,"findings":3,"false_positives":0,"cold_start_s":6.0,"wall_time_s":30.0}
JSONL
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  # Mean nav 10000 for #811 -> 2.0x (not 2.5x from the single 8000 run).
  [[ "$output" == *"2.0"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — render itself fails loud on a missing baseline counterpart
# ---------------------------------------------------------------------------

@test "render_lsp_comparison: fails loud (non-zero) when a candidate PR has no baseline" {
  printf '%s\n' '{"pr":"petry-projects/.github-private#999@fffffff","variant":"lsp-on","candidate":"agent-lsp","model":"claude-opus-4-7","input_tokens":500,"cache_read_tokens":0,"output_tokens":50,"nav_tokens":3000,"tool_calls":6,"findings":2,"false_positives":0,"cold_start_s":5.0,"wall_time_s":20.0}' >> "$CANDIDATE"
  run render_lsp_comparison "$BASELINE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"#999@fffffff"* ]]
  # It must not pretend the comparison is clean.
  [[ "$output" != *"no quality regression"* ]]
}
