#!/usr/bin/env bats
# Tests for the plan_json artifact type (issue #614, epic #610 Phase 2).
#
# Phase 2 registers a SECOND review artifact_type, plan_json, additively beside
# pr_diff. It binds a fixed adversarial/semantic plan rubric (prompts/plan-review.md)
# to a structured-findings output channel (scripts/post-plan-findings.sh) that
# emits machine-readable findings for the initiative planner — NOT a GitHub PR
# review. A content_ref adapter (scripts/initiative-planner/review-plan.sh) feeds
# a plan.json into the rubric via engine.sh's existing model routing.
#
# These tests lock the wiring without running the LLM cascade (which needs a live
# engine): registry resolution, driver dispatch wiring, and the deterministic
# output-channel behavior over a sample plan's findings JSON.
#
# Run with: bats tests/test_plan_review.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/review-registry.sh"
  RUBRIC_PROMPT="$REPO_ROOT/prompts/plan-review.md"
  OUTPUT_CHANNEL="$REPO_ROOT/scripts/post-plan-findings.sh"
  DRIVER="$REPO_ROOT/scripts/initiative-planner/review-plan.sh"
  FINDINGS_FILE="$BATS_TEST_TMPDIR/findings.json"
}

# write_findings — materialize a structured-findings JSON in the documented
# plan_json output shape (see scripts/post-plan-findings.sh header).
write_findings() {
  local verdict="${1:-revise}"
  jq -n --arg v "$verdict" '{
    artifact_type: "plan_json",
    verdict: $v,
    summary: "Sample critique of the plan.",
    findings: [
      { severity: "major", category: "ac_quality", message: "AC 1 is not testable.", story_id: 1, location: "stories[0].acceptance_criteria[0]" },
      { severity: "minor", category: "grounding", message: "Dev note lacks a source citation.", story_id: 2, location: "stories[1].dev_notes" }
    ]
  }' > "$FINDINGS_FILE"
}

# ---------------------------------------------------------------------------
# Registry — plan_json is registered (AC #1)
# ---------------------------------------------------------------------------

@test "plan_json is registered" {
  run review_registry_types
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "plan_json"
}

@test "plan_json rubric resolves to the plan-review rubric" {
  run review_registry_lookup plan_json rubric
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/plan-review.md" ]
}

@test "plan_json output_channel resolves to the structured-findings channel" {
  run review_registry_lookup plan_json output_channel
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/post-plan-findings.sh" ]
}

@test "plan_json output_channel is NOT post-pr-review.sh (structured findings, not a PR review)" {
  run review_registry_lookup plan_json output_channel
  [ "$status" -eq 0 ]
  [ "$output" != "scripts/post-pr-review.sh" ]
}

@test "every plan_json referenced rubric/channel file exists on disk" {
  run review_registry_lookup plan_json rubric
  [ "$status" -eq 0 ]
  IFS=',' read -ra rubric_files <<< "$output"
  for f in "${rubric_files[@]}"; do
    [ -f "$REPO_ROOT/$f" ] || { echo "missing rubric file: $f"; false; }
  done
  run review_registry_lookup plan_json output_channel
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/$output" ]
}

# ---------------------------------------------------------------------------
# Additive guard — pr_diff is untouched (AC #4)
# ---------------------------------------------------------------------------

@test "pr_diff is still registered alongside plan_json" {
  run review_registry_types
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "pr_diff"
}

@test "pr_diff still resolves to its existing cascade and channel" {
  run review_registry_lookup pr_diff rubric
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/triage.md,prompts/deep-review.md,prompts/synthesize.md" ]
  run review_registry_lookup pr_diff output_channel
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/post-pr-review.sh" ]
}

# ---------------------------------------------------------------------------
# Content_ref adapter / driver wiring (AC #2)
# ---------------------------------------------------------------------------

@test "driver dispatches on artifact_type=plan_json" {
  run grep -qE 'plan_json' "$DRIVER"
  [ "$status" -eq 0 ]
}

@test "driver sources the rubric registry helper" {
  run grep -qE 'lib/review-registry\.sh' "$DRIVER"
  [ "$status" -eq 0 ]
}

@test "driver reuses engine.sh model routing (sources engine.sh, calls run_agentic)" {
  run grep -qE 'engine\.sh' "$DRIVER"
  [ "$status" -eq 0 ]
  run grep -qE 'run_agentic' "$DRIVER"
  [ "$status" -eq 0 ]
}

@test "driver runs the rubric at the deep tier (no separate model selector)" {
  run grep -qE 'run_agentic[^#]*(ENGINE_DEEP_MODEL|"deep")' "$DRIVER"
  [ "$status" -eq 0 ]
}

@test "driver resolves rubric and output_channel via the registry helper" {
  run grep -qE 'review_registry_lookup[^|]*rubric' "$DRIVER"
  [ "$status" -eq 0 ]
  run grep -qE 'review_registry_lookup[^|]*output_channel' "$DRIVER"
  [ "$status" -eq 0 ]
}

@test "driver presents the plan.json path to the rubric as content_ref" {
  # The adapter exports the plan path so the rubric prompt can read it.
  run grep -qE 'PLAN_PATH' "$DRIVER"
  [ "$status" -eq 0 ]
}

@test "driver delivers via the resolved output channel variable, not a hard-coded path" {
  # The verdict is delivered through the registry-resolved channel variable, so
  # no literal output-channel script path is invoked at the bash call site.
  run grep -qE 'bash[[:space:]].*REVIEW_OUTPUT_CHANNEL' "$DRIVER"
  [ "$status" -eq 0 ]
  run grep -nE 'bash[[:space:]]+scripts/post-plan-findings\.sh' "$DRIVER"
  [ "$status" -ne 0 ]
}

@test "driver never calls post-pr-review.sh (plan_json is not a PR review)" {
  # Ignore comment lines (the header documents the prohibition); a real
  # invocation would be on a non-comment line.
  run bash -c "grep -vE '^[[:space:]]*#' '$DRIVER' | grep -qE 'post-pr-review\\.sh'"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Structured-findings output channel — a sample plan produces findings (AC #3, #5)
# ---------------------------------------------------------------------------

@test "output channel emits machine-readable findings to the destination path" {
  write_findings revise
  DEST="$BATS_TEST_TMPDIR/out.json"
  run env PLAN_FINDINGS_OUTPUT="$DEST" bash "$OUTPUT_CHANNEL" "/tmp/plan.json" "$FINDINGS_FILE" true
  [ "$status" -eq 0 ]
  [ -s "$DEST" ]
  run jq -e '.findings | length == 2' "$DEST"
  [ "$status" -eq 0 ]
  run jq -r '.verdict' "$DEST"
  [ "$output" = "revise" ]
}

@test "output channel surfaces the verdict and finding count for the planner" {
  write_findings revise
  run bash "$OUTPUT_CHANNEL" "/tmp/plan.json" "$FINDINGS_FILE" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'verdict: revise'
  echo "$output" | grep -qE 'findings: 2'
}

@test "output channel accepts a clean pass verdict (zero findings)" {
  jq -n '{artifact_type:"plan_json", verdict:"pass", summary:"No blocking issues.", findings:[]}' > "$FINDINGS_FILE"
  run bash "$OUTPUT_CHANNEL" "/tmp/plan.json" "$FINDINGS_FILE" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'verdict: pass'
}

@test "output channel rejects a missing findings file" {
  run bash "$OUTPUT_CHANNEL" "/tmp/plan.json" "$BATS_TEST_TMPDIR/nope.json" true
  [ "$status" -ne 0 ]
}

@test "output channel rejects malformed (non-JSON) findings" {
  echo "not json {" > "$FINDINGS_FILE"
  run bash "$OUTPUT_CHANNEL" "/tmp/plan.json" "$FINDINGS_FILE" true
  [ "$status" -ne 0 ]
}

@test "output channel rejects an unknown verdict value" {
  write_findings frobnicate
  run bash "$OUTPUT_CHANNEL" "/tmp/plan.json" "$FINDINGS_FILE" true
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'verdict'
}

@test "output channel does NOT call the GitHub PR review API or post-pr-review.sh" {
  # Static guard: the structured-findings channel must never deliver a PR review.
  # Ignore comment lines (the header documents the prohibition).
  run bash -c "grep -vE '^[[:space:]]*#' '$OUTPUT_CHANNEL' | grep -qE 'post-pr-review\\.sh|gh pr review|/pulls/.*/reviews'"
  [ "$status" -ne 0 ]
}
