#!/usr/bin/env bats
# Unit tests for the persona runtime core (scripts/lib/persona-runner.sh).
# Standard: petry-projects/.github standards/persona-standards.md §4.1.
#
# The runner is a SEPARATE trust boundary from the router: a repository_dispatch
# can be sent by anything with a token, so payload re-validation and the
# write-side recursion marker get the most coverage here.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/persona-runner.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
  ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
}

# --- the recursion marker (shared with the router) -------------------------

@test "pr_agent_marker matches the router's marker prefix exactly" {
  run pr_agent_marker qa-lead
  [ "$output" = "<!-- persona:qa-lead -->" ]
}

@test "pr_comment_has_marker accepts a body whose first line is the marker" {
  run pr_comment_has_marker qa-lead "$(printf '<!-- persona:qa-lead -->\n## advisory\nbody')"
  [ "$status" -eq 0 ]
}

@test "pr_comment_has_marker rejects a body missing the marker" {
  run pr_comment_has_marker qa-lead "$(printf '## advisory\nno marker')"
  [ "$status" -ne 0 ]
}

@test "pr_comment_has_marker rejects the marker on a later line (must be first)" {
  run pr_comment_has_marker qa-lead "$(printf 'preamble\n<!-- persona:qa-lead -->')"
  [ "$status" -ne 0 ]
}

@test "pr_comment_has_marker rejects the wrong persona's marker" {
  run pr_comment_has_marker qa-lead "$(printf '<!-- persona:dev-lead -->\nbody')"
  [ "$status" -ne 0 ]
}

# --- payload re-validation (this runner is its own trust boundary) ---------

@test "pr_valid_persona_id accepts a kebab-case slug" {
  run pr_valid_persona_id qa-lead
  [ "$status" -eq 0 ]
}

@test "pr_valid_persona_id accepts a single-token slug" {
  run pr_valid_persona_id murat
  [ "$status" -eq 0 ]
}

@test "pr_valid_persona_id rejects an empty id" {
  run pr_valid_persona_id ""
  [ "$status" -ne 0 ]
}

@test "pr_valid_persona_id rejects a path-traversal id" {
  run pr_valid_persona_id "../../etc/passwd"
  [ "$status" -ne 0 ]
}

@test "pr_valid_persona_id rejects uppercase, spaces, and slashes" {
  run pr_valid_persona_id "QA Lead"
  [ "$status" -ne 0 ]
  run pr_valid_persona_id "qa/lead"
  [ "$status" -ne 0 ]
}

@test "pr_valid_persona_id rejects leading, trailing, and doubled hyphens" {
  run pr_valid_persona_id "-qa"
  [ "$status" -ne 0 ]
  run pr_valid_persona_id "qa-"
  [ "$status" -ne 0 ]
  run pr_valid_persona_id "qa--lead"
  [ "$status" -ne 0 ]
}

# --- advisory prompt resolution (convention-driven) ------------------------

@test "pr_advisory_prompt_path follows the prompts/<id>/advisory.md convention" {
  run pr_advisory_prompt_path qa-lead
  [ "$output" = "prompts/qa-lead/advisory.md" ]
}

@test "pr_require_advisory returns the path when the prompt exists" {
  mkdir -p "$ROOT/prompts/qa-lead"
  echo "prompt" > "$ROOT/prompts/qa-lead/advisory.md"
  run pr_require_advisory qa-lead "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/qa-lead/advisory.md" ]
}

@test "pr_require_advisory fails (rc 3) with a diagnostic when the prompt is absent" {
  # A persona can declare an address before its runtime exists; the runner must
  # say so, not crash or invoke an empty prompt.
  run pr_require_advisory scrum-master "$ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no runtime wired yet"* ]]
}

@test "pr_require_advisory fails (rc 2) on a malformed id BEFORE touching the fs" {
  # Guards the path interpolation: a bad id must never reach the filesystem read.
  run pr_require_advisory "../../etc" "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed persona id"* ]]
}
