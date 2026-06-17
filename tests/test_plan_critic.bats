#!/usr/bin/env bats
# Tests for the bounded adversarial plan-critic pass (issue #603, epic #597 Phase 2).
#
# The critic reviews Bob's draft plan.json against the FIXED six-check rubric that
# lives ONCE in prompts/bmad/scrum-master.md (consumed verbatim — no forked
# rubric), emits structured findings, and Bob revises once: resolvable findings
# fold back into plan.json; unresolved ones become open_questions carrying
# affected_story_ids so they gate per #682.
#
# The LLM pass itself cannot run deterministically in CI, so these tests lock the
# regression contract instead: the #581 plan fixture is structurally valid (so the
# structural validator could not have caught the six semantic defects), the rubric
# is single-sourced, the golden findings cover all six rubric checks, and the
# deterministic routing helper folds unresolved findings into the gating
# open_questions shape.
#
# Run with: bats tests/test_plan_critic.bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PLANNER_DIR="$ROOT/scripts/initiative-planner"
  VALIDATE="$PLANNER_DIR/validate-plan.py"
  ROUTE="$PLANNER_DIR/route-findings.sh"
  RUBRIC="$ROOT/prompts/bmad/scrum-master.md"
  CRITIC_PROMPT="$ROOT/prompts/plan-review.md"
  FIXTURE_DIR="$ROOT/tests/fixtures/initiative-planner"
  PLAN_581="$FIXTURE_DIR/plan-581.json"
  FINDINGS_581="$FIXTURE_DIR/plan-581.expected-findings.json"
  WORKFLOW="$ROOT/.github/workflows/initiative-planner.yml"
  TMP="$(mktemp -d)"
  # The six rubric check ids, mirroring scrum-master.md's six-item rubric and the
  # six hand-review findings named in issue #603 AC #4.
  EXPECTED_CHECKS=(contested_ac success_metric cost_cap eval_safeguards untracked_prereq reviewability)
}

teardown() { rm -rf "$TMP"; }

# ---------------------------------------------------------------------------
# Single-source rubric — no forked second copy (AC #1, Dev Notes)
# ---------------------------------------------------------------------------

@test "the fixed rubric lives in prompts/bmad/scrum-master.md" {
  [ -f "$RUBRIC" ]
  run grep -qE 'Quality rubric' "$RUBRIC"
  [ "$status" -eq 0 ]
}

@test "scrum-master.md rubric enumerates the six checks the critic scores" {
  grep -qiE 'contested' "$RUBRIC"
  grep -qiE 'success metric' "$RUBRIC"
  grep -qiE 'cost cap' "$RUBRIC"
  grep -qiE 'prerequisite' "$RUBRIC"
  grep -qiE 'reviewable' "$RUBRIC"
  grep -qiE 'overfitting|reward.hacking' "$RUBRIC"
}

@test "the critic prompt consumes the scrum-master.md rubric (does not fork a second rubric)" {
  [ -f "$CRITIC_PROMPT" ]
  run grep -qE 'prompts/bmad/scrum-master\.md' "$CRITIC_PROMPT"
  [ "$status" -eq 0 ]
}

@test "the critic prompt documents the structured findings shape {check, story_id?, severity, finding}" {
  grep -qE '"check"' "$CRITIC_PROMPT"
  grep -qE '"finding"' "$CRITIC_PROMPT"
  grep -qE '"severity"' "$CRITIC_PROMPT"
  grep -qE '"story_id"' "$CRITIC_PROMPT"
}

# ---------------------------------------------------------------------------
# #581 regression fixture (AC #4)
# ---------------------------------------------------------------------------

@test "the #581 plan fixture exists and is valid JSON" {
  [ -s "$PLAN_581" ]
  run jq empty "$PLAN_581"
  [ "$status" -eq 0 ]
}

@test "the #581 fixture passes validate-plan.py — the structural validator can NOT catch the six semantic defects" {
  run python3 "$VALIDATE" "$PLAN_581"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "the golden findings cover all six rubric checks (the six hand-review findings)" {
  [ -s "$FINDINGS_581" ]
  for check in "${EXPECTED_CHECKS[@]}"; do
    run jq -e --arg c "$check" '.findings | map(.check) | index($c) != null' "$FINDINGS_581"
    [ "$status" -eq 0 ] || { echo "missing finding for check: $check"; false; }
  done
}

@test "every golden finding carries the structured shape and a known severity" {
  run jq -e '
    .findings | length == 6 and all(.[];
      has("check") and has("severity") and has("finding")
      and (.severity | IN("info","minor","major","critical")))
  ' "$FINDINGS_581"
  [ "$status" -eq 0 ]
}

@test "the golden findings verdict is revise (at least one major/critical finding)" {
  run jq -r '.verdict' "$FINDINGS_581"
  [ "$output" = "revise" ]
}

# ---------------------------------------------------------------------------
# open_questions.affected_story_ids — schema + validator (AC #3)
# ---------------------------------------------------------------------------

@test "validate-plan accepts an open_question object carrying affected_story_ids" {
  jq '.open_questions = [{"question":"Settle the tie-vs-strict gate before planning","affected_story_ids":[1],"blocking":true}]' \
    "$PLAN_581" > "$TMP/withaffected.json"
  run python3 "$VALIDATE" "$TMP/withaffected.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "validate-plan rejects affected_story_ids that reference a non-existent story id" {
  jq '.open_questions = [{"question":"dangles","affected_story_ids":[99]}]' \
    "$PLAN_581" > "$TMP/dangling.json"
  run python3 "$VALIDATE" "$TMP/dangling.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"99"* ]]
}

# ---------------------------------------------------------------------------
# route-findings.sh — fold unresolved findings into gating open_questions (AC #3)
# ---------------------------------------------------------------------------

@test "route-findings folds unresolved findings into open_questions with affected_story_ids" {
  run bash "$ROUTE" "$PLAN_581" "$FINDINGS_581"
  [ "$status" -eq 0 ]
  echo "$output" > "$TMP/routed.json"
  # Six findings -> six open questions, each carrying the affected story id(s).
  run jq -e '(.open_questions | length) == 6' "$TMP/routed.json"
  [ "$status" -eq 0 ]
  run jq -e '.open_questions | all(.[]; has("question") and has("affected_story_ids"))' "$TMP/routed.json"
  [ "$status" -eq 0 ]
}

@test "route-findings output re-validates against validate-plan.py" {
  bash "$ROUTE" "$PLAN_581" "$FINDINGS_581" > "$TMP/routed.json"
  run python3 "$VALIDATE" "$TMP/routed.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan OK"* ]]
}

@test "route-findings marks major/critical findings blocking so they gate per #682" {
  bash "$ROUTE" "$PLAN_581" "$FINDINGS_581" > "$TMP/routed.json"
  # The fixture's findings are all major/critical -> all routed questions block.
  run jq -e '[.open_questions[] | select(.blocking == true)] | length == 6' "$TMP/routed.json"
  [ "$status" -eq 0 ]
}

@test "route-findings maps a finding's story_id into its question's affected_story_ids" {
  bash "$ROUTE" "$PLAN_581" "$FINDINGS_581" > "$TMP/routed.json"
  # The eval_safeguards finding is about story 2; its routed question must name story 2.
  run jq -e '[.open_questions[] | select(.affected_story_ids | index(2))] | length >= 1' "$TMP/routed.json"
  [ "$status" -eq 0 ]
}

@test "route-findings routes an epic-level (null story_id) finding to an empty affected_story_ids" {
  bash "$ROUTE" "$PLAN_581" "$FINDINGS_581" > "$TMP/routed.json"
  # success_metric + cost_cap are epic-level (story_id null) -> empty affected_story_ids.
  run jq -e '[.open_questions[] | select(.affected_story_ids | length == 0)] | length == 2' "$TMP/routed.json"
  [ "$status" -eq 0 ]
}

@test "route-findings is a pure transform: it does not drop or rewrite existing stories" {
  bash "$ROUTE" "$PLAN_581" "$FINDINGS_581" > "$TMP/routed.json"
  run jq -e '.stories == input.stories' "$TMP/routed.json" "$PLAN_581"
  [ "$status" -eq 0 ]
}

@test "route-findings preserves pre-existing open_questions and appends to them" {
  jq '.open_questions = ["pre-existing advisory note"]' "$PLAN_581" > "$TMP/withexisting.json"
  bash "$ROUTE" "$TMP/withexisting.json" "$FINDINGS_581" > "$TMP/routed.json"
  run jq -e '(.open_questions | length) == 7' "$TMP/routed.json"
  [ "$status" -eq 0 ]
  run jq -e '.open_questions | index("pre-existing advisory note") != null' "$TMP/routed.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Bounded wiring — single review + one revise, no loop; gate untouched (AC #2, #5)
# ---------------------------------------------------------------------------

@test "the workflow wires the bounded plan-critic pass into Bob's prompt" {
  run grep -qE 'plan-critic' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "the workflow critic consumes the single-source rubric and routes via route-findings.sh" {
  grep -qE 'prompts/bmad/scrum-master\.md' "$WORKFLOW"
  grep -qE 'route-findings\.sh' "$WORKFLOW"
}

@test "the workflow documents the single-review/one-revise (no-loop) bound" {
  grep -qiE 'no loop|one revise' "$WORKFLOW"
}

@test "the workflow still creates the epic inert (never applies initiative:auto)" {
  run grep -qE 'initiative:auto' "$WORKFLOW"
  [ "$status" -eq 0 ]
  # The human gate language must remain.
  grep -qiE 'human|inert' "$WORKFLOW"
}
