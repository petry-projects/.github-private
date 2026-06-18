#!/usr/bin/env bats
# Unit tests for engine.sh — COPILOT_API_MODEL must be defaulted independent of
# the selected REVIEW_ENGINE (issue #773).
#
# Under the default `claude` engine the rubber-duck tier deliberately routes to
# Copilot (DUCK_ENGINE=copilot → run_duck → copilot_chat), which dereferences
# $COPILOT_API_MODEL. Before the fix that variable was only assigned inside the
# `copilot)` arm of set_engine_config, so under `set -euo pipefail` the duck
# subshell aborted with "COPILOT_API_MODEL: unbound variable" and the review
# silently fell through to deep-review-only.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  # A `gh` stub that records the --model value copilot_chat passes through, so
  # we can assert the duck path actually reaches the API with a defaulted model
  # instead of aborting on an unbound variable.
  STUB_BIN_DIR="$(mktemp -d)"
  GH_MODEL_RECORD="$(mktemp)"
  export GH_MODEL_RECORD
  cat > "$STUB_BIN_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh copilot` stub: record the --model arg, emit a benign reply.
prev=""
for arg in "$@"; do
  if [ "$prev" = "--model" ]; then
    printf '%s\n' "$arg" >> "$GH_MODEL_RECORD"
  fi
  prev="$arg"
done
echo "stub copilot reply"
STUB
  chmod +x "$STUB_BIN_DIR/gh"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  TEST_PROMPT="$(mktemp)"
  echo "duck prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  # copilot_chat requires a token; provide a fake one (the stub ignores it).
  export GH_TOKEN="fake-token"

  # Ensure a clean slate so engine.sh evaluates its own default.
  unset COPILOT_API_MODEL
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$GH_MODEL_RECORD"
  rm -rf "$STUB_BIN_DIR"
  unset COPILOT_API_MODEL
}

_source_engine() {
  local engine="${1:-claude}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT"
}

# ── COPILOT_API_MODEL is engine-agnostic ──────────────────────────────────────

@test "duck-model: COPILOT_API_MODEL is defaulted under the claude engine" {
  _source_engine "claude"
  # Set even though the copilot) arm never ran.
  [ -n "${COPILOT_API_MODEL+x}" ]
  [ "$COPILOT_API_MODEL" = "openai/o4-mini" ]
}

@test "duck-model: COPILOT_API_MODEL is exported under the claude engine" {
  _source_engine "claude"
  # Exported so the cross-engine duck subshell (copilot_chat) inherits it.
  run bash -c 'echo "${COPILOT_API_MODEL:-MISSING}"'
  [ "$status" -eq 0 ]
  [ "$output" = "openai/o4-mini" ]
}

@test "duck-model: copilot_chat duck path does not abort with unbound variable on claude engine" {
  _source_engine "claude"
  # This is the exact failure from #773: under set -u, copilot_chat dereferenced
  # an unset COPILOT_API_MODEL and aborted before producing JSON.
  run copilot_chat "$TEST_PROMPT" 30
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  # The default model reached the gh invocation.
  grep -q "openai/o4-mini" "$GH_MODEL_RECORD"
}

@test "duck-model: a pre-set COPILOT_API_MODEL override is honored on the claude engine" {
  export COPILOT_API_MODEL="openai/gpt-5-mini"
  _source_engine "claude"
  [ "$COPILOT_API_MODEL" = "openai/gpt-5-mini" ]
}

# ── Regression guard: copilot engine still defaults the model ─────────────────

@test "duck-model: copilot engine still defaults COPILOT_API_MODEL" {
  _source_engine "copilot"
  [ "$COPILOT_API_MODEL" = "openai/o4-mini" ]
}
