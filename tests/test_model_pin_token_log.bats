#!/usr/bin/env bats
# #1979 AC3 — a token record keeps the RESOLVED model id, not the family name.
# Families are resolved to a concrete id before the engine runs, so the id that
# flows to emit_token_record (and thus TOKEN_LOG_FILE) is the real model.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  unset AI_MODELS_CLAUDE CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN \
        CLAUDE_ACTION_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  # shellcheck source=../scripts/lib/engine-models.sh
  source "$SCRIPT_DIR/scripts/lib/engine-models.sh"
  # shellcheck source=../scripts/lib/token-metrics.sh
  source "$SCRIPT_DIR/scripts/lib/token-metrics.sh"
  TOKEN_LOG_FILE="$(mktemp)"
  export TOKEN_LOG_FILE
}

teardown() {
  rm -f "$TOKEN_LOG_FILE"
}

@test "token-log: records the resolved id, not the family name" {
  local model
  model="$(ai_model_for_family sonnet)"
  [ "$model" != "sonnet" ]
  emit_token_record wf action claude "$model" 10 0 5 test
  local logged
  logged="$(jq -r '.model' < "$TOKEN_LOG_FILE")"
  [ "$logged" = "$model" ]
  [[ "$logged" == claude-sonnet-* ]]
}
