#!/usr/bin/env bats
# Unit tests for scripts/lib/shadow-compare.sh
#
# Shadow-mode dual-run (#605, prerequisite for the self-improving-skills proposer
# #587; part of the Safe Release Strategy #495 alongside health-gated promotion
# #501). The library logs + compares a shadow (`next`-channel) agent run against
# the `stable` run on the same PR, classifies a quality-regression signal, and
# emits it in a machine-readable form the #501 promotion gate consumes.
#
# These tests exercise the PURE classification/signal logic — no network, no
# agent dispatch. Run with: bats tests/test_shadow_compare.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/shadow-compare.sh"
}

# ---------------------------------------------------------------------------
# sc_normalize — output normalization for comparison
# ---------------------------------------------------------------------------

@test "sc_normalize strips leading and trailing whitespace" {
  run sc_normalize "$(printf '  \n hello world \n\n ')"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "sc_normalize leaves interior content intact" {
  run sc_normalize "$(printf 'line one\nline two')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'line one\nline two')" ]
}

@test "sc_normalize of empty input is empty" {
  run sc_normalize ""
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# sc_classify — the core stable-vs-shadow decision
# ---------------------------------------------------------------------------

@test "MATCH: both succeed with identical output" {
  run sc_classify "success" "success" "approved: LGTM" "approved: LGTM"
  [ "$status" -eq 0 ]
  [ "$output" = "MATCH" ]
}

@test "MATCH: outputs differ only by surrounding whitespace" {
  run sc_classify "success" "success" "approved" "  approved  "
  [ "$output" = "MATCH" ]
}

@test "DIVERGED: both succeed but outputs differ" {
  run sc_classify "success" "success" "approved: LGTM" "requested changes: nit"
  [ "$output" = "DIVERGED" ]
}

@test "REGRESSION: stable succeeds but shadow fails" {
  run sc_classify "success" "failure" "approved" ""
  [ "$output" = "REGRESSION" ]
}

@test "REGRESSION: stable succeeds but shadow cancelled" {
  run sc_classify "success" "cancelled" "approved" ""
  [ "$output" = "REGRESSION" ]
}

@test "REGRESSION: stable succeeds, shadow succeeds but produced empty output" {
  # A shadow that concludes 'success' yet emits nothing where stable produced a
  # review is a silent quality regression, not a MATCH.
  run sc_classify "success" "success" "approved: LGTM" ""
  [ "$output" = "REGRESSION" ]
}

@test "SHADOW_ONLY_OK: stable fails but shadow succeeds (candidate may be a fix)" {
  run sc_classify "failure" "success" "" "approved"
  [ "$output" = "SHADOW_ONLY_OK" ]
}

@test "SHADOW_ONLY_OK: stable has no run but shadow succeeds" {
  run sc_classify "" "success" "" "approved"
  [ "$output" = "SHADOW_ONLY_OK" ]
}

@test "BOTH_FAILED: neither succeeds (environmental / PR-specific)" {
  run sc_classify "failure" "failure" "" ""
  [ "$output" = "BOTH_FAILED" ]
}

@test "NO_SHADOW: no shadow run observed (empty shadow conclusion)" {
  run sc_classify "success" "" "approved" ""
  [ "$output" = "NO_SHADOW" ]
}

@test "NO_SHADOW: shadow conclusion is the literal null string" {
  run sc_classify "success" "null" "approved" ""
  [ "$output" = "NO_SHADOW" ]
}

# ---------------------------------------------------------------------------
# sc_is_blocking — only a REGRESSION blocks promotion
# ---------------------------------------------------------------------------

@test "sc_is_blocking is true only for REGRESSION" {
  run sc_is_blocking "REGRESSION"
  [ "$status" -eq 0 ]
}

@test "sc_is_blocking is false for MATCH" {
  run sc_is_blocking "MATCH"
  [ "$status" -ne 0 ]
}

@test "sc_is_blocking is false for DIVERGED (advisory only, quality is not objectively worse)" {
  run sc_is_blocking "DIVERGED"
  [ "$status" -ne 0 ]
}

@test "sc_is_blocking is false for SHADOW_ONLY_OK / BOTH_FAILED / NO_SHADOW (inconclusive)" {
  run sc_is_blocking "SHADOW_ONLY_OK"
  [ "$status" -ne 0 ]
  run sc_is_blocking "BOTH_FAILED"
  [ "$status" -ne 0 ]
  run sc_is_blocking "NO_SHADOW"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# sc_signal_json — machine-readable signal for the #501 promotion gate
# ---------------------------------------------------------------------------

@test "sc_signal_json emits the shadow_dual_run signal type" {
  json="$(sc_signal_json "MATCH" "dev-lead" "next" "111" "222")"
  run jq -er '.signal' <<< "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "shadow_dual_run" ]
}

@test "sc_signal_json carries reusable, channel and status" {
  json="$(sc_signal_json "DIVERGED" "dev-lead" "next" "111" "222")"
  [ "$(printf '%s' "$json" | jq -r '.reusable')" = "dev-lead" ]
  [ "$(printf '%s' "$json" | jq -r '.channel')" = "next" ]
  [ "$(printf '%s' "$json" | jq -r '.status')" = "DIVERGED" ]
}

@test "sc_signal_json marks REGRESSION as blocking with regression=true" {
  json="$(sc_signal_json "REGRESSION" "dev-lead" "next" "111" "222")"
  [ "$(printf '%s' "$json" | jq -r '.blocks_promotion')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.regression')" = "true" ]
}

@test "sc_signal_json marks MATCH as non-blocking with regression=false" {
  json="$(sc_signal_json "MATCH" "dev-lead" "next" "111" "222")"
  [ "$(printf '%s' "$json" | jq -r '.blocks_promotion')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.regression')" = "false" ]
}

@test "sc_signal_json emits run ids as numbers and null when absent" {
  json="$(sc_signal_json "MATCH" "dev-lead" "next" "111" "")"
  [ "$(printf '%s' "$json" | jq -r '.stable_run_id')" = "111" ]
  [ "$(printf '%s' "$json" | jq -r '.shadow_run_id')" = "null" ]
}

@test "sc_signal_json output is valid JSON" {
  json="$(sc_signal_json "MATCH" "dev-lead" "next" "111" "222")"
  run jq -e . <<< "$json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# sc_report — human-readable Markdown for logs / step summary (never the PR)
# ---------------------------------------------------------------------------

@test "sc_report renders the status and channel" {
  run sc_report "REGRESSION" "dev-lead" "next" "http://x/1" "http://x/2" "2026-07-15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGRESSION"* ]]
  [[ "$output" == *"next"* ]]
}

@test "sc_report states the shadow output is not posted to the PR" {
  run sc_report "MATCH" "dev-lead" "next" "http://x/1" "http://x/2" "2026-07-15"
  [[ "$output" == *"not posted"* ]]
}
