#!/usr/bin/env bats
# AI_MODELS_CLAUDE / AI_MODELS_GEMINI / AI_MODELS_COPILOT: each provider's model
# list as one Actions variable (scripts/lib/engine-models.sh), wired through
# engine.sh's set_engine_config.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/engine-models.sh"

setup() {
  unset AI_MODELS_CLAUDE AI_MODELS_GEMINI AI_MODELS_COPILOT AI_MODELS_PROBLEM_REPORTED
  unset CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN CLAUDE_AUDIT_MODEL_CHAIN
  unset CLAUDE_ACTION_MODEL_CHAIN CLAUDE_SINGLE_MODEL_CHAIN
  unset GEMINI_FLASH_MODEL GEMINI_PRO_MODEL GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN
  unset COPILOT_API_MODEL AI_ENGINES AI_DUCK_ENGINE AI_DUCK_MODEL
  # shellcheck source=../../../scripts/lib/engine-models.sh
  source "$LIB"
}

# Sources engine.sh for <engine> in a subshell and prints the requested vars.
_engine() {
  local engine="$1"; shift
  local vars="" v
  for v in "$@"; do vars="$vars $v=\${$v:-}"; done
  bash -c "export REVIEW_ENGINE=$engine; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; echo \"$vars\""
}

# ── Parsing ───────────────────────────────────────────────────────────────────

@test "parse: unset → defaults (Claude deep chain, Gemini pro is 3.1-pro-preview)" {
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5" ]
  [ "$(ai_models_chain gemini pro)" = "gemini-3.1-pro-preview,gemini-3.8-flash" ]
  [ "$(ai_models_chain copilot model)" = "openai/o4-mini" ]
  [ -z "$(ai_models_problems)" ]
}

@test "parse: '; ' and newlines separate entries; keys are case-insensitive; spaces ignored" {
  export AI_MODELS_CLAUDE=$'DEEP = claude-opus-4-8 , claude-sonnet-5\ntriage=claude-sonnet-5;  audit=claude-fable-5'
  [ "$(ai_models_chain claude deep)" = "claude-opus-4-8,claude-sonnet-5" ]
  [ "$(ai_models_chain claude triage)" = "claude-sonnet-5" ]
  [ "$(ai_models_chain claude audit)" = "claude-fable-5" ]
  # an omitted key keeps its default
  [ "$(ai_models_chain claude action)" = "claude-sonnet-5,claude-opus-4-8" ]
}

@test "parse: duplicate models collapse; the last entry for a key wins" {
  export AI_MODELS_GEMINI="pro=gemini-a,gemini-a,gemini-b; pro=gemini-c"
  [ "$(ai_models_chain gemini pro)" = "gemini-c" ]
  export AI_MODELS_GEMINI="pro=gemini-a,gemini-a,gemini-b"
  [ "$(ai_models_chain gemini pro)" = "gemini-a,gemini-b" ]
}

@test "problems: unknown key, missing '=', invalid id and empty list are reported and ignored" {
  export AI_MODELS_CLAUDE="deeep=claude-opus-4-8; claude-sonnet-5; deep=claude opus; triage=,"
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5" ]
  [ "$(ai_models_chain claude triage)" = "claude-haiku-4-5-20251001,claude-sonnet-5" ]
  run ai_models_problems
  [[ "$output" == *"unknown key 'deeep'"* ]]
  [[ "$output" == *"'claude-sonnet-5' is not <key>=<models>"* ]]
  [[ "$output" == *"'triage' lists no model"* ]]
  [[ "$output" == *"invalid model id 'claude opus'"* ]]
}

@test "parse: an unusable last entry for a key drops an earlier one (the default applies)" {
  export AI_MODELS_CLAUDE="deep=claude-sonnet-5; deep=not valid"
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5" ]
  export AI_MODELS_CLAUDE="deep=claude-sonnet-5; deep=,"
  [ "$(ai_models_chain claude deep)" = "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5" ]
}

@test "problems: an invalid model id drops the whole entry (no half-parsed chain)" {
  export AI_MODELS_GEMINI='pro=gemini-3.1-pro-preview,gem!ni'
  [ "$(ai_models_chain gemini pro)" = "gemini-3.1-pro-preview,gemini-3.8-flash" ]
  [[ "$(ai_models_problems)" == *"invalid model id 'gem!ni'"* ]]
}

@test "labels: short names for log lines" {
  [ "$(ai_model_label claude-haiku-4-5-20251001)" = "haiku 4.5" ]
  [ "$(ai_model_label claude-opus-5-5)" = "opus 5.5" ]
  [ "$(ai_model_label claude-sonnet-5)" = "sonnet 5" ]
  [ "$(ai_model_label openai/o4-mini)" = "o4-mini" ]
  [ "$(ai_models_label_chain claude-opus-5-5,claude-opus-4-8,claude-sonnet-5)" = "opus 5.5 [opus 4.8, sonnet 5]" ]
}

# ── Claude via engine.sh ──────────────────────────────────────────────────────

@test "claude: defaults unchanged (chains, per-tier primaries, label)" {
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-opus-5-5,claude-opus-4-8,claude-sonnet-5"* ]]
  [[ "$output" == *"ENGINE_TRIAGE_MODEL=claude-haiku-4-5-20251001"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=claude-opus-5-5"* ]]
  [[ "$output" == *"ENGINE_AUDIT_MODEL=claude-fable-5"* ]]
  [[ "$output" == *"ENGINE_ACTION_MODEL=claude-sonnet-5"* ]]
  [[ "$output" == *"ENGINE_SINGLE_MODEL=claude-fable-5"* ]]
}

@test "claude: AI_MODELS_CLAUDE sets the tier chain, its primary and the log label" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8,claude-sonnet-5"
  run _engine claude CLAUDE_DEEP_MODEL_CHAIN ENGINE_DEEP_MODEL ENGINE_LABEL
  [[ "$output" == *"CLAUDE_DEEP_MODEL_CHAIN=claude-opus-4-8,claude-sonnet-5"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=claude-opus-4-8"* ]]
  [[ "$output" == *"deep: opus 4.8 [sonnet 5]"* ]]
}

@test "claude: a per-tier CLAUDE_<TIER>_MODEL_CHAIN still wins over AI_MODELS_CLAUDE" {
  export AI_MODELS_CLAUDE="deep=claude-opus-4-8" CLAUDE_DEEP_MODEL_CHAIN="claude-sonnet-5"
  run _engine claude ENGINE_DEEP_MODEL
  [[ "$output" == *"ENGINE_DEEP_MODEL=claude-sonnet-5"* ]]
}

# ── Gemini via engine.sh ──────────────────────────────────────────────────────

@test "gemini: AI_MODELS_GEMINI sets the flash and pro chains" {
  export AI_MODELS_GEMINI="flash=gemini-f1,gemini-f2; pro=gemini-p1"
  run _engine gemini GEMINI_FLASH_MODEL_CHAIN GEMINI_PRO_MODEL_CHAIN ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL
  [[ "$output" == *"GEMINI_FLASH_MODEL_CHAIN=gemini-f1,gemini-f2"* ]]
  [[ "$output" == *"GEMINI_PRO_MODEL_CHAIN=gemini-p1"* ]]
  [[ "$output" == *"ENGINE_TRIAGE_MODEL=gemini-f1"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=gemini-p1"* ]]
}

@test "gemini: GEMINI_PRO_MODEL replaces only the first model of the configured chain" {
  export AI_MODELS_GEMINI="pro=gemini-p1,gemini-p2" GEMINI_PRO_MODEL="gemini-x"
  run _engine gemini GEMINI_PRO_MODEL_CHAIN ENGINE_DEEP_MODEL
  [[ "$output" == *"GEMINI_PRO_MODEL_CHAIN=gemini-x,gemini-p2"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=gemini-x"* ]]
}

@test "gemini: GEMINI_PRO_MODEL_CHAIN wins over both" {
  export AI_MODELS_GEMINI="pro=gemini-p1" GEMINI_PRO_MODEL="gemini-x" GEMINI_PRO_MODEL_CHAIN="gemini-c1,gemini-c2"
  run _engine gemini GEMINI_PRO_MODEL_CHAIN ENGINE_DEEP_MODEL
  [[ "$output" == *"GEMINI_PRO_MODEL_CHAIN=gemini-c1,gemini-c2"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=gemini-c1"* ]]
}

@test "gemini: the Claude duck model comes from AI_MODELS_CLAUDE duck=" {
  export AI_MODELS_CLAUDE="duck=claude-haiku-4-5-20251001"
  run _engine gemini DUCK_ENGINE DUCK_MODEL
  [[ "$output" == *"DUCK_ENGINE=claude"* ]]
  [[ "$output" == *"DUCK_MODEL=claude-haiku-4-5-20251001"* ]]
}

# ── Copilot via engine.sh ─────────────────────────────────────────────────────

@test "copilot: AI_MODELS_COPILOT model= sets COPILOT_API_MODEL and the tier labels" {
  export AI_MODELS_COPILOT="model=openai/gpt-5-mini"
  run _engine copilot COPILOT_API_MODEL ENGINE_DEEP_MODEL
  [[ "$output" == *"COPILOT_API_MODEL=openai/gpt-5-mini"* ]]
  [[ "$output" == *"ENGINE_DEEP_MODEL=gpt-5-mini"* ]]
}

@test "copilot: an explicit COPILOT_API_MODEL still wins" {
  export AI_MODELS_COPILOT="model=openai/gpt-5-mini" COPILOT_API_MODEL="openai/o4-mini"
  run _engine copilot COPILOT_API_MODEL
  [[ "$output" == *"COPILOT_API_MODEL=openai/o4-mini"* ]]
}

@test "copilot: the Gemini duck model comes from AI_MODELS_GEMINI duck=, else flash" {
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-3.8-flash"* ]]
  export AI_MODELS_GEMINI="duck=gemini-d1"
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-d1"* ]]
}

@test "copilot: the Gemini duck model follows GEMINI_FLASH_MODEL_CHAIN, then GEMINI_FLASH_MODEL" {
  export GEMINI_FLASH_MODEL_CHAIN="gemini-c1,gemini-c2" GEMINI_FLASH_MODEL="gemini-x"
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-c1"* ]]
  unset GEMINI_FLASH_MODEL_CHAIN
  run _engine copilot DUCK_MODEL
  [[ "$output" == *"DUCK_MODEL=gemini-x"* ]]
}

@test "problems: a duck or copilot model key given several models warns and keeps the first" {
  export AI_MODELS_COPILOT="model=openai/gpt-5-mini,openai/o4-mini" AI_MODELS_CLAUDE="duck=claude-sonnet-5,claude-opus-4-8"
  [ "$(ai_models_chain copilot model)" = "openai/gpt-5-mini" ]
  [ "$(ai_models_chain claude duck)" = "claude-sonnet-5" ]
  run ai_models_problems
  [[ "$output" == *"AI_MODELS_COPILOT: 'model' takes one model — only 'openai/gpt-5-mini' is used"* ]]
  [[ "$output" == *"AI_MODELS_CLAUDE: 'duck' takes one model — only 'claude-sonnet-5' is used"* ]]
}

@test "copilot: the log label shows the duck's short name" {
  run _engine copilot ENGINE_LABEL
  [[ "$output" == *"duck: gemini-3.8-flash →"* ]]
}

# ── Gemini billing probe (validate-engines.sh) ───────────────────────────────

# Puts a curl stub on PATH that records its URL and answers with <body> / <code>.
_probe_curl() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/body"
  printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/code"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in https://*) echo "$a" >> "$BATS_TEST_TMPDIR/urls" ;; esac; done
cat "$BATS_TEST_TMPDIR/body" "$BATS_TEST_TMPDIR/code"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" BATS_TEST_TMPDIR
}

@test "probe: the Gemini billing probe calls the configured flash model" {
  _probe_curl '{"candidates":[]}' 200
  export AI_MODELS_GEMINI="flash=gemini-f1,gemini-f2"
  source "$SCRIPT_DIR/scripts/validate-engines.sh"
  _gemini_probe_key fake
  grep -q "/models/gemini-f1:generateContent" "$BATS_TEST_TMPDIR/urls"
  export GEMINI_FLASH_MODEL_CHAIN="gemini-c1"
  _gemini_probe_key fake
  grep -q "/models/gemini-c1:generateContent" "$BATS_TEST_TMPDIR/urls"
}

@test "probe: Google's models/ prefix is stripped; an unprobe-able id warns and skips" {
  _probe_curl '{"candidates":[]}' 200
  export AI_MODELS_GEMINI="flash=models/gemini-f1"
  source "$SCRIPT_DIR/scripts/validate-engines.sh"
  _gemini_probe_key fake
  grep -q "/models/gemini-f1:generateContent" "$BATS_TEST_TMPDIR/urls"
  rm -f "$BATS_TEST_TMPDIR/urls"
  export AI_MODELS_GEMINI="flash=vendor/gemini-x"
  run bash -c "source '$SCRIPT_DIR/scripts/validate-engines.sh'; _gemini_probe_key a; echo rc=\$?"
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"Gemini billing probe skipped"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/urls" ]
}

@test "headroom: the Claude probe uses the configured triage model and warns without headers" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/args"
printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" BATS_TEST_TMPDIR
  export AI_MODELS_CLAUDE="triage=claude-sonnet-5" ANTHROPIC_API_KEY="fake"
  run bash -c "export REVIEW_ENGINE=claude; source '$SCRIPT_DIR/scripts/engine.sh' >/dev/null 2>&1; check_provider_headroom claude; echo rc=\$?; check_provider_headroom claude"
  [[ "$output" == *"rc=0"* ]]
  grep -q '"model":"claude-sonnet-5"' "$BATS_TEST_TMPDIR/args"
  [ "$(grep -c "no rate-limit headers from claude-sonnet-5" <<< "$output")" = "1" ]
}

@test "probe: a not-found probe model warns once and stays fail-open" {
  _probe_curl '{"error":{"code":404,"message":"models/gemini-gone is not found","status":"NOT_FOUND"}}' 404
  export AI_MODELS_GEMINI="flash=gemini-gone"
  run bash -c "source '$SCRIPT_DIR/scripts/validate-engines.sh'; _gemini_probe_key a; echo rc=\$?; _gemini_probe_key b"
  [[ "$output" == *"rc=0"* ]]
  [ "$(grep -c "model 'gemini-gone' was not found" <<< "$output")" = "1" ]
}

# ── Warnings ──────────────────────────────────────────────────────────────────

@test "engine.sh: a bad AI_MODELS_* entry warns once per run" {
  run bash -c "export REVIEW_ENGINE=claude AI_MODELS_GEMINI='typo=x'; source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c \"AI_MODELS_GEMINI: unknown key 'typo'\""
  [ "$output" = "1" ]
  run bash -c "export REVIEW_ENGINE=claude AI_MODELS_GEMINI='typo=x' AI_MODELS_PROBLEM_REPORTED=1; source '$SCRIPT_DIR/scripts/engine.sh' 2>&1 >/dev/null | grep -c 'AI_MODELS_GEMINI'"
  [ "$output" = "0" ]
}
