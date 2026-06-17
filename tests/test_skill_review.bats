#!/usr/bin/env bats
# Tests for the skill_candidate artifact type (issue #615, epic #610 Phase 2).
#
# This registers a THIRD review artifact_type, skill_candidate, additively beside
# pr_diff and plan_json. It binds a skill-eval rubric (prompts/skill-review.md,
# aligned to Epic #581's strict-improvement eval criteria) to a pass/score output
# channel (scripts/post-skill-score.sh) that emits a gate-consumable pass/fail +
# numeric score — NOT a GitHub PR review. A content_ref adapter
# (scripts/evals/review-skill.sh) feeds a candidate skill edit (diff or file) into
# the rubric via engine.sh's existing model routing.
#
# These tests lock the wiring without running the LLM rubric (which needs a live
# engine): registry resolution, the additive guard over pr_diff/plan_json, driver
# dispatch wiring, and the deterministic output-channel behavior over a sample
# score JSON.
#
# Run with: bats tests/test_skill_review.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/review-registry.sh"
  RUBRIC_PROMPT="$REPO_ROOT/prompts/skill-review.md"
  OUTPUT_CHANNEL="$REPO_ROOT/scripts/post-skill-score.sh"
  DRIVER="$REPO_ROOT/scripts/evals/review-skill.sh"
  SCORE_FILE="$BATS_TEST_TMPDIR/score.json"
}

# write_score <verdict> <score>
#   Materialize a pass/score JSON in the documented skill_candidate output shape
#   (see scripts/post-skill-score.sh header).
write_score() {
  local verdict="${1:-pass}" score="${2:-0.9}"
  jq -n --arg v "$verdict" --argjson s "$score" '{
    artifact_type: "skill_candidate",
    verdict: $v,
    score: $s,
    summary: "Sample skill-edit review.",
    findings: [
      { severity: "minor", category: "grounding", message: "Edit clarifies the HIGH-risk taxonomy.", location: "prompts/triage.md" }
    ]
  }' > "$SCORE_FILE"
}

# ---------------------------------------------------------------------------
# Registry — skill_candidate is registered (AC #1)
# ---------------------------------------------------------------------------

@test "skill_candidate is registered" {
  run review_registry_types
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "skill_candidate"
}

@test "skill_candidate rubric resolves to the skill-review rubric" {
  run review_registry_lookup skill_candidate rubric
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/skill-review.md" ]
}

@test "skill_candidate output_channel resolves to the pass/score channel" {
  run review_registry_lookup skill_candidate output_channel
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/post-skill-score.sh" ]
}

@test "skill_candidate output_channel is NOT post-pr-review.sh (gate signal, not a PR review)" {
  run review_registry_lookup skill_candidate output_channel
  [ "$status" -eq 0 ]
  [ "$output" != "scripts/post-pr-review.sh" ]
}

@test "every skill_candidate referenced rubric/channel file exists on disk" {
  run review_registry_lookup skill_candidate rubric
  [ "$status" -eq 0 ]
  IFS=',' read -ra rubric_files <<< "$output"
  for f in "${rubric_files[@]}"; do
    [ -f "$REPO_ROOT/$f" ] || { echo "missing rubric file: $f"; false; }
  done
  run review_registry_lookup skill_candidate output_channel
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/$output" ]
}

# ---------------------------------------------------------------------------
# Additive guard — pr_diff and plan_json are untouched (AC #4)
# ---------------------------------------------------------------------------

@test "pr_diff is still registered alongside skill_candidate" {
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

@test "plan_json is still registered alongside skill_candidate" {
  run review_registry_types
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "plan_json"
}

@test "plan_json still resolves to its rubric and structured-findings channel" {
  run review_registry_lookup plan_json rubric
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/plan-review.md" ]
  run review_registry_lookup plan_json output_channel
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/post-plan-findings.sh" ]
}

@test "schema version is still a non-empty integer after the additive registration" {
  run review_registry_version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# Content_ref adapter / driver wiring (AC #2)
# ---------------------------------------------------------------------------

@test "driver dispatches on artifact_type=skill_candidate" {
  run grep -qE 'skill_candidate' "$DRIVER"
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

@test "driver presents a candidate skill edit (diff or file) to the rubric as content_ref" {
  # The adapter exports a candidate path so the rubric prompt can read it.
  run grep -qE 'CANDIDATE' "$DRIVER"
  [ "$status" -eq 0 ]
}

@test "driver delivers via the resolved output channel variable, not a hard-coded path" {
  run grep -qE 'bash[[:space:]].*REVIEW_OUTPUT_CHANNEL' "$DRIVER"
  [ "$status" -eq 0 ]
  run grep -nE 'bash[[:space:]]+scripts/post-skill-score\.sh' "$DRIVER"
  [ "$status" -ne 0 ]
}

@test "driver never calls post-pr-review.sh (skill_candidate is not a PR review)" {
  # Ignore comment lines (the header documents the prohibition); a real
  # invocation would be on a non-comment line.
  run bash -c "grep -vE '^[[:space:]]*#' '$DRIVER' | grep -qE 'post-pr-review\\.sh'"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Pass/score output channel — a sample produces a score (AC #3, #5)
# ---------------------------------------------------------------------------

@test "output channel emits a pass/score signal to the destination path" {
  write_score pass 0.9
  DEST="$BATS_TEST_TMPDIR/out.json"
  run env SKILL_SCORE_OUTPUT="$DEST" bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -eq 0 ]
  [ -s "$DEST" ]
  run jq -r '.verdict' "$DEST"
  [ "$output" = "pass" ]
  run jq -r '.score' "$DEST"
  [ "$output" = "0.9" ]
}

@test "output channel surfaces the verdict and score for the gate" {
  write_score pass 0.85
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'verdict: pass'
  echo "$output" | grep -qE 'score: 0\.85'
}

@test "output channel accepts a fail verdict" {
  write_score fail 0.2
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'verdict: fail'
}

@test "output channel rejects a missing score file" {
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$BATS_TEST_TMPDIR/nope.json" true
  [ "$status" -ne 0 ]
}

@test "output channel rejects malformed (non-JSON) score output" {
  echo "not json {" > "$SCORE_FILE"
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -ne 0 ]
}

@test "output channel rejects an unknown verdict value" {
  write_score frobnicate 0.9
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'verdict'
}

@test "output channel rejects an out-of-range score (> 1)" {
  write_score pass 1.5
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'score'
}

@test "output channel rejects a negative score" {
  write_score pass -0.1
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'score'
}

@test "output channel rejects a non-numeric score" {
  jq -n '{artifact_type:"skill_candidate", verdict:"pass", score:"high", summary:"x", findings:[]}' > "$SCORE_FILE"
  run bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" true
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'score'
}

@test "output channel does NOT call the GitHub PR review API or post-pr-review.sh" {
  # Static guard: the pass/score channel must never deliver a PR review.
  # Ignore comment lines (the header documents the prohibition).
  run bash -c "grep -vE '^[[:space:]]*#' '$OUTPUT_CHANNEL' | grep -qE 'post-pr-review\\.sh|gh pr review|/pulls/.*/reviews'"
  [ "$status" -ne 0 ]
}

@test "output channel creates parent directories when SKILL_SCORE_OUTPUT has a missing parent" {
  write_score pass 1
  DEST="$BATS_TEST_TMPDIR/nested/deep/out.json"
  run env SKILL_SCORE_OUTPUT="$DEST" bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" false
  [ "$status" -eq 0 ]
  [ -s "$DEST" ]
}

@test "output channel does not truncate when SKILL_SCORE_OUTPUT is the same file as the score JSON" {
  write_score pass 0.7
  run env SKILL_SCORE_OUTPUT="$SCORE_FILE" bash "$OUTPUT_CHANNEL" "/tmp/candidate.diff" "$SCORE_FILE" false
  [ "$status" -eq 0 ]
  run jq -r '.verdict' "$SCORE_FILE"
  [ "$output" = "pass" ]
}
