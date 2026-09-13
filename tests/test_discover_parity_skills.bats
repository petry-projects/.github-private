#!/usr/bin/env bats
# Tests for scripts/evals/discover-parity-skills.sh (#1702 AC #3).
#
# The weekly persona-parity cadence must DISCOVER which skills to score from
# each skill's evals/<skill>/scorer.json (`engine == "persona"`), never from a
# hardcoded list — the same derive-don't-enumerate rule as the `<id>:hands-off`
# label family (#756). Adding a persona to the parity cadence must require no
# edit to the workflow. These tests pin that contract against a fixture EVALS_DIR
# so they stay offline (no model, no network).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DISCOVER="$ROOT/scripts/evals/discover-parity-skills.sh"
  TMP="$BATS_TEST_TMPDIR"

  # Two persona-tier skills (engine == "persona").
  mkdir -p "$TMP/evals/alpha-lead/holdout" "$TMP/evals/bravo-lead/holdout"
  cat >"$TMP/evals/alpha-lead/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "alpha-lead/judge.md", "engine": "persona"}
JSON
  cat >"$TMP/evals/bravo-lead/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "bravo-lead/judge.md", "engine": "persona"}
JSON

  # A skill declaring an llm-judge scorer but NO engine field — defaults to
  # triage tier, so it must NOT be discovered (mirrors deep-review on main).
  mkdir -p "$TMP/evals/charlie-review/holdout"
  cat >"$TMP/evals/charlie-review/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "judge.md", "pass_threshold": 0.7}
JSON

  # A skill with NO scorer.json at all — deterministic/triage default (mirrors
  # triage on main). Must not be discovered.
  mkdir -p "$TMP/evals/delta-triage/holdout"
}

@test "emits a JSON array" {
  EVALS_DIR="$TMP/evals" run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  jq -e 'type == "array"' <<<"$output" >/dev/null
}

@test "includes every skill whose scorer.json declares engine == persona" {
  EVALS_DIR="$TMP/evals" run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'index("alpha-lead") | . != null' <<<"$output")" = "true" ]
  [ "$(jq -r 'index("bravo-lead") | . != null' <<<"$output")" = "true" ]
}

@test "excludes a skill with a scorer.json but no engine field (triage default)" {
  EVALS_DIR="$TMP/evals" run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'index("charlie-review")' <<<"$output")" = "null" ]
}

@test "excludes a skill with no scorer.json at all (triage default)" {
  EVALS_DIR="$TMP/evals" run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'index("delta-triage")' <<<"$output")" = "null" ]
}

@test "output is sorted and unique" {
  EVALS_DIR="$TMP/evals" run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '. == (. | sort | unique)' <<<"$output")" = "true" ]
}

@test "an empty evals tree yields an empty JSON array (never a crash)" {
  mkdir -p "$TMP/empty"
  EVALS_DIR="$TMP/empty" run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "adding a new persona scorer.json extends the list with no script edit" {
  mkdir -p "$TMP/evals/echo-lead/holdout"
  cat >"$TMP/evals/echo-lead/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "echo-lead/judge.md", "engine": "persona"}
JSON
  EVALS_DIR="$TMP/evals" run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'index("echo-lead") | . != null' <<<"$output")" = "true" ]
}

@test "against the real repo evals tree, discovers the nine live personas" {
  run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  # deep-review declares no engine -> must be absent; the nine parity personas present.
  [ "$(jq -r 'index("deep-review")' <<<"$output")" = "null" ]
  for s in business-analyst dev-lead devops-lead pr-review qa-lead \
           scrum-master security-lead solution-architect sre-lead; do
    [ "$(jq -r --arg s "$s" 'index($s) | . != null' <<<"$output")" = "true" ]
  done
}
