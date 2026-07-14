#!/usr/bin/env bats
# Tests for scripts/spec-drift.sh — the spec-drift detector's PURE classifier
# and its I/O split (#1144, epic #1142).
#
# The pure helpers (classify_drift / parse_acceptance_criteria /
# story_is_initiative / drift_verdict_envelope) are unit-tested directly with
# no network or LLM call. main() is exercised with a mocked `gh` on PATH and a
# pre-defined `run_triage` so no engine/model call is made; the inert no-ACs
# path is asserted to emit INDETERMINATE and exit 0.
#
# Run with: bats tests/test_spec_drift.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/spec-drift.sh"

setup() {
  # shellcheck source=scripts/spec-drift.sh
  source "$SCRIPT"
  unset SPEC_DRIFT_PR SPEC_DRIFT_STORY SPEC_DRIFT_REPO SPEC_DRIFT_OUT 2>/dev/null || true
}

# A representative initiative-story issue body as rendered by
# scripts/initiative-planner/apply-plan.sh (BMAD create-story template order).
_story_body() {
  cat <<'BODY'
## Story
As a maintainer,
I want a drift detector,
so that shipped code cannot silently diverge from the plan.

## Acceptance Criteria
1. A new script exposes a pure classifier.
2. The classifier maps analysis into DRIFT / ALIGNED / INDETERMINATE.
3. The no-ACs case is inert.

## Tasks / Subtasks
- [ ] Implement the classifier (AC: #1, #2)

## Dev Notes
- Reuse the plan schema.

_Story prepared by the BMAD Scrum Master (Bob) for epic #1142. Status: ready-for-dev._
BODY
}

# ---------------------------------------------------------------------------
# classify_drift <analysis>
# ---------------------------------------------------------------------------

@test "classify_drift: an explicit DRIFT verdict token is DRIFT" {
  run classify_drift $'reasoning about the diff\nDRIFT_VERDICT: DRIFT'
  [ "$status" -eq 0 ]
  [ "$output" = "DRIFT" ]
}

@test "classify_drift: an explicit ALIGNED verdict token is ALIGNED" {
  run classify_drift $'the diff matches the ACs\nDRIFT_VERDICT: ALIGNED'
  [ "$status" -eq 0 ]
  [ "$output" = "ALIGNED" ]
}

@test "classify_drift: the verdict token is matched case-insensitively" {
  run classify_drift 'drift_verdict: aligned'
  [ "$output" = "ALIGNED" ]
}

@test "classify_drift: garbled output with no verdict token is INDETERMINATE" {
  run classify_drift 'some unrelated chatter with no verdict at all'
  [ "$output" = "INDETERMINATE" ]
}

@test "classify_drift: empty output (e.g. a timeout kill) is INDETERMINATE" {
  run classify_drift ""
  [ "$output" = "INDETERMINATE" ]
}

@test "classify_drift: DRIFT wins when both tokens are present (fail toward drift)" {
  run classify_drift $'DRIFT_VERDICT: DRIFT\nDRIFT_VERDICT: ALIGNED'
  [ "$output" = "DRIFT" ]
}

# ---------------------------------------------------------------------------
# parse_acceptance_criteria <body>
# ---------------------------------------------------------------------------

@test "parse_acceptance_criteria: extracts the numbered ACs, stripped of numbering" {
  run parse_acceptance_criteria "$(_story_body)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"A new script exposes a pure classifier."* ]]
  [[ "$output" == *"The classifier maps analysis into DRIFT / ALIGNED / INDETERMINATE."* ]]
  [[ "$output" == *"The no-ACs case is inert."* ]]
  # The numbering prefix must be stripped.
  [[ "$output" != *"1. A new script"* ]]
  # It must not bleed into the following section.
  [[ "$output" != *"Implement the classifier"* ]]
}

@test "parse_acceptance_criteria: a body with no AC section yields empty output" {
  run parse_acceptance_criteria $'## Story\nsome prose\n\n## Dev Notes\n- note'
  [ -z "$output" ]
}

@test "parse_acceptance_criteria: empty body yields empty output" {
  run parse_acceptance_criteria ""
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# story_is_initiative <body>
# ---------------------------------------------------------------------------

@test "story_is_initiative: a BMAD story body is recognized" {
  run story_is_initiative "$(_story_body)"
  [ "$status" -eq 0 ]
}

@test "story_is_initiative: a plain issue body is not an initiative story" {
  run story_is_initiative $'Just a normal bug report.\n\nSteps to reproduce: ...'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# drift_verdict_envelope <verdict> <pr> <story> <reason> [now]
# ---------------------------------------------------------------------------

@test "drift_verdict_envelope: emits valid JSON carrying the verdict and refs" {
  run drift_verdict_envelope "DRIFT" "42" "1144" "diff diverges from AC #2" "2026-07-14T00:00:00Z"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.verdict')" = "DRIFT" ]
  [ "$(echo "$output" | jq -r '.pr')" = "42" ]
  [ "$(echo "$output" | jq -r '.story')" = "1144" ]
  [ "$(echo "$output" | jq -r '.reason')" = "diff diverges from AC #2" ]
  [ "$(echo "$output" | jq -r '.generated_at')" = "2026-07-14T00:00:00Z" ]
}

@test "drift_verdict_envelope: missing pr/story render as JSON null" {
  run drift_verdict_envelope "INDETERMINATE" "" "" "no acceptance criteria" "2026-07-14T00:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.pr')" = "null" ]
  [ "$(echo "$output" | jq -r '.story')" = "null" ]
  [ "$(echo "$output" | jq -r '.verdict')" = "INDETERMINATE" ]
}

# ---------------------------------------------------------------------------
# main() — mocked gh on PATH + pre-defined run_triage (no engine/network)
# ---------------------------------------------------------------------------

_install_gh_mock() {
  # $1 = issue body that `gh issue view` should emit
  # $2 = pr diff that `gh pr diff` should emit
  MOCK_BIN="$(mktemp -d)"
  export MOCK_BIN
  export MOCK_ISSUE_BODY="$1" MOCK_PR_DIFF="$2"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  issue) printf '%s' "$MOCK_ISSUE_BODY" ;;
  pr)    printf '%s' "$MOCK_PR_DIFF" ;;
  *)     : ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "${MOCK_BIN:-}"
}

@test "main: inert no-ACs (non-initiative story) → INDETERMINATE, exit 0" {
  _install_gh_mock $'Just a plain bug, no ACs here.' 'diff --git a b'
  export SPEC_DRIFT_STORY="999" SPEC_DRIFT_PR="42"
  # run_triage must NOT be reached on the inert path; make it fail loudly if it is.
  run_triage() { echo "run_triage-should-not-run"; return 1; }
  export -f run_triage

  run bash -c 'run_triage() { echo "should-not-run"; return 1; }; export -f run_triage; source "'"$SCRIPT"'"; main 2>/dev/null'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.verdict')" = "INDETERMINATE" ]
  [[ "$output" != *"should-not-run"* ]]
}

@test "main: no source story provided → inert INDETERMINATE, exit 0" {
  _install_gh_mock '' ''
  unset SPEC_DRIFT_STORY
  export SPEC_DRIFT_PR="42"
  run bash -c 'source "'"$SCRIPT"'"; main 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "INDETERMINATE" ]
}

@test "main: resolved ACs + DRIFT analysis → DRIFT verdict, exit 0" {
  _install_gh_mock "$(_story_body)" $'diff --git a/x b/x\n+ unrelated change'
  export SPEC_DRIFT_STORY="1144" SPEC_DRIFT_PR="42"
  run bash -c 'run_triage() { echo "DRIFT_VERDICT: DRIFT"; }; export -f run_triage; source "'"$SCRIPT"'"; main 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "DRIFT" ]
  [ "$(echo "$output" | jq -r '.pr')" = "42" ]
  [ "$(echo "$output" | jq -r '.story')" = "1144" ]
}

@test "main: resolved ACs + ALIGNED analysis → ALIGNED verdict, exit 0" {
  _install_gh_mock "$(_story_body)" $'diff --git a/x b/x\n+ the pure classifier'
  export SPEC_DRIFT_STORY="1144" SPEC_DRIFT_PR="42"
  run bash -c 'run_triage() { echo "DRIFT_VERDICT: ALIGNED"; }; export -f run_triage; source "'"$SCRIPT"'"; main 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "ALIGNED" ]
}
