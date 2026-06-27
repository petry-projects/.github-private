#!/usr/bin/env bats
# Unit tests for the LSP-pilot run driver's PURE helpers (epic #839, story #844).
# The claude/gh calls in run_variant()/main() are CI-only; these pin the helpers
# that shape the run: wall-time math, the navigation-heavy prompt, and the on-leg
# tool allowlist (base + the pilot's read-only LSP nav tools).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RUN="$SCRIPT_DIR/scripts/lsp_pilot_run.sh"

_call() { run bash -c 'source "$1"; shift; "$@"' bash "$RUN" "$@"; }

@test "lpr_wall_seconds: positive delta → seconds (1dp)" {
  _call lpr_wall_seconds 1000000000 4500000000
  [ "$status" -eq 0 ]
  [ "$output" = "3.5" ]
}

@test "lpr_wall_seconds: backwards clock → clamped to 0.0" {
  _call lpr_wall_seconds 5000000000 1000000000
  [ "$output" = "0.0" ]
}

@test "lpr_wall_seconds: non-numeric (e.g. %N unsupported) → 0.0, never crashes" {
  _call lpr_wall_seconds "1234N" "5678N"
  [ "$output" = "0.0" ]
}

@test "lpr_build_prompt: embeds the PR number, verify instruction, and the diff body" {
  printf '%s\n' '+++ b/scripts/x.sh' '+echo CANARY_DIFF_LINE' > "$BATS_TEST_TMPDIR/d.diff"
  _call lpr_build_prompt 917 "$BATS_TEST_TMPDIR/d.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull request #917"* ]]
  [[ "$output" == *"verify every CROSS-FILE claim"* ]]
  [[ "$output" == *"CANARY_DIFF_LINE"* ]]
}

@test "lpr_on_tools: includes the base tools AND the pilot LSP navigation allowlist" {
  _call lpr_on_tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"Grep"* ]]
  [[ "$output" == *"mcp__lsp__find_references"* ]]
  [[ "$output" == *"mcp__lsp__get_diagnostics"* ]]
}
