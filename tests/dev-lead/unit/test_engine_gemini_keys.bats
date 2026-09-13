#!/usr/bin/env bats
# Unit tests for engine.sh — additional Gemini API keys for resilience (#1777).
#
# GOOGLE_API_KEY_2 and GOOGLE_API_KEY_3 are extra keys the gemini engine rotates
# through, per model, when the current key is rate-limited — so a per-key quota
# exhaustion no longer forces an immediate model downgrade or a cross-provider
# hop while another key still has headroom.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
STUB_ENGINES_DIR="$SCRIPT_DIR/tests/dev-lead/fixtures/engines"

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"

  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL
  unset GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3

  STUB_BIN_DIR="$(mktemp -d)"
  cp "$STUB_ENGINES_DIR/stub-gemini" "$STUB_BIN_DIR/gemini"
  chmod +x "$STUB_BIN_DIR/gemini"
  export PATH="$STUB_BIN_DIR:$PATH"
  export STUB_BIN_DIR

  TEST_PROMPT="$(mktemp)"
  echo "test prompt content" > "$TEST_PROMPT"
  export TEST_PROMPT

  MODEL_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_MODELS="$MODEL_RECORD"
  KEY_RECORD="$(mktemp)"
  export STUB_ENGINE_RECORD_KEYS="$KEY_RECORD"

  export DEV_LEAD_DRY_RUN="false"
  # JSON capture wraps the stub output in an envelope; unset so the plain-text
  # rate-limit detection path (is_rate_limited_files) is exercised directly.
  unset TOKEN_LOG_FILE ENGINE_USAGE_JSON
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$TEST_PROMPT" "$MODEL_RECORD" "$KEY_RECORD"
  rm -rf "$STUB_BIN_DIR"
  rm -f /tmp/dev-lead-failure-reason
  unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3
  unset STUB_ENGINE_EXIT_BY_MODEL STUB_ENGINE_RESPONSE_BY_MODEL
  unset STUB_ENGINE_EXIT_BY_KEY STUB_ENGINE_RESPONSE_BY_KEY
  unset STUB_ENGINE_RECORD_MODELS STUB_ENGINE_RECORD_KEYS
  unset STUB_ENGINE_EXIT STUB_ENGINE_RESPONSE DEV_LEAD_ENGINES
}

_source_engine() {
  local engine="${1:-gemini}"
  export REVIEW_ENGINE="$engine"
  source "$ENGINE_SCRIPT" 2>/dev/null || true
}

# ── _gemini_api_keys helper ───────────────────────────────────────────────────

@test "keys: _gemini_api_keys lists primary then _2 then _3, de-duplicated" {
  export GEMINI_API_KEY="k1"
  export GOOGLE_API_KEY="k1"       # same value as primary → collapsed
  export GOOGLE_API_KEY_2="k2"
  export GOOGLE_API_KEY_3="k3"
  _source_engine "gemini"

  run _gemini_api_keys
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "k1" ]
  [ "${lines[1]}" = "k2" ]
  [ "${lines[2]}" = "k3" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "keys: _gemini_api_keys skips empties and preserves distinct primary pair" {
  export GEMINI_API_KEY="ka"
  export GOOGLE_API_KEY="kb"
  unset GOOGLE_API_KEY_2
  export GOOGLE_API_KEY_3="kd"
  _source_engine "gemini"

  run _gemini_api_keys
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ka" ]
  [ "${lines[1]}" = "kb" ]
  [ "${lines[2]}" = "kd" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "keys: _gemini_api_keys emits nothing when no key is configured" {
  _source_engine "gemini"
  run _gemini_api_keys
  [ -z "$output" ]
}

# ── Per-key rotation inside the model chain ───────────────────────────────────

@test "rotate: primary key rate-limited → GOOGLE_API_KEY_2 succeeds (same model)" {
  export GEMINI_API_KEY="key1"
  export GOOGLE_API_KEY="key1"
  export GOOGLE_API_KEY_2="key2"
  export STUB_ENGINE_EXIT_BY_KEY="key1=1|key2=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="key1=429 too many requests|key2=ok from key2"
  _source_engine "gemini"

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 0 ]
  [[ "$output" == *"ok from key2"* ]]
  [[ "$output" != *"too many requests"* ]]
  grep -q "key1" "$KEY_RECORD"
  grep -q "key2" "$KEY_RECORD"
  # Only one model was tried — rotation stayed on gemini-3.8-flash across keys.
  [ "$(sort -u "$MODEL_RECORD" | wc -l)" -eq 1 ]
}

@test "rotate: all keys rate-limited on a model → falls through to next model" {
  export GEMINI_API_KEY="key1"
  export GOOGLE_API_KEY_2="key2"
  # First model 429s for every key; second model succeeds.
  export STUB_ENGINE_EXIT_BY_MODEL="gemini-3.8-flash=1|gemini-2.5-pro=0"
  export STUB_ENGINE_RESPONSE_BY_MODEL="gemini-3.8-flash=quota exceeded 429|gemini-2.5-pro=pro ok"
  _source_engine "gemini"

  run _gemini_chain_invoke "gemini-3.8-flash,gemini-2.5-pro" "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 0 ]
  [[ "$output" == *"pro ok"* ]]
  # Both keys were tried against the first model before degrading the model.
  grep -q "key1" "$KEY_RECORD"
  grep -q "key2" "$KEY_RECORD"
  grep -q "gemini-3.8-flash" "$MODEL_RECORD"
  grep -q "gemini-2.5-pro" "$MODEL_RECORD"
}

@test "rotate: every key rate-limited on every model → exit 2 (cross-provider signal)" {
  export GEMINI_API_KEY="key1"
  export GOOGLE_API_KEY_2="key2"
  export STUB_ENGINE_EXIT=1
  export STUB_ENGINE_RESPONSE="quota exceeded 429"
  _source_engine "gemini"

  run _gemini_chain_invoke "gemini-3.8-flash,gemini-2.5-pro" "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 2 ]
  grep -q "key1" "$KEY_RECORD"
  grep -q "key2" "$KEY_RECORD"
}

@test "rotate: single configured key → exactly one invocation (baseline unchanged)" {
  export GEMINI_API_KEY="only-key"
  export GOOGLE_API_KEY="only-key"
  export STUB_ENGINE_EXIT=0
  _source_engine "gemini"

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30 --approval-mode auto_edit

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$KEY_RECORD")" -eq 1 ]
}

@test "rotate: non-rate-limit failure on primary key does NOT rotate to next key" {
  export GEMINI_API_KEY="key1"
  export GOOGLE_API_KEY_2="key2"
  export STUB_ENGINE_EXIT_BY_KEY="key1=1|key2=0"
  export STUB_ENGINE_RESPONSE_BY_KEY="key1=unexpected internal error|key2=should not run"
  _source_engine "gemini"

  run _gemini_chain_invoke "gemini-3.8-flash" "$TEST_PROMPT" 30 --approval-mode auto_edit

  # A hard (non-rate-limit) failure propagates immediately — no key rotation.
  [ "$status" -eq 1 ]
  grep -q "key1" "$KEY_RECORD"
  ! grep -q "key2" "$KEY_RECORD"
}

# ── Config-gap recognition of the extra keys ──────────────────────────────────

@test "config: gemini attempted when only GOOGLE_API_KEY_2 is set (not skipped)" {
  # Neither GEMINI_API_KEY nor GOOGLE_API_KEY is set, but a secondary key is.
  # Gemini must NOT be treated as an unconfigured config-gap — it should run.
  export DEV_LEAD_ENGINES="gemini"
  export GOOGLE_API_KEY_2="secondary-key"
  export STUB_ENGINE_EXIT=0
  _source_engine "gemini"

  run run_writer_with_fallback "$TEST_PROMPT"

  [ "$status" -eq 0 ]
  grep -q "secondary-key" "$KEY_RECORD"
}
