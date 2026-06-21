#!/usr/bin/env bats
# Unit tests for the LSP finding-verification step (epic #839, story #843).
#
# The step grounds deep/audit cross-file/semantic findings against LSP nav tools
# before posting. The model annotates each such finding with an `lsp_verification`
# field (`verified`|`unverifiable`); this shell layer ENFORCES the annotation:
#   - inert when LSP is not wired or is degraded (review byte-for-byte unchanged) — AC #3
#   - `unverifiable` → downgrade severity one step + annotate (never dropped)     — AC #2
#   - each verified/unverifiable outcome → one JSONL record on TOKEN_LOG_FILE     — AC #4
# It reuses the MCP gating/degradation signal already shipped (#677/#678).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
ENGINE_SCRIPT="$SCRIPT_DIR/scripts/engine.sh"
LSP_LIB="$SCRIPT_DIR/scripts/lib/lsp-verification.sh"
TOKEN_LIB="$SCRIPT_DIR/scripts/lib/token-metrics.sh"
LSP_ALLOWED="mcp__lsp__find_references,mcp__lsp__get_diagnostics"

setup() {
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS
  # The degradation scan reuses engine.sh's _mcp_failure_pattern when present.
  # shellcheck source=/dev/null
  source "$ENGINE_SCRIPT" >/dev/null 2>&1 || true
  # shellcheck source=/dev/null
  source "$TOKEN_LIB"
  # shellcheck source=/dev/null
  source "$LSP_LIB"

  WORKDIR="$(mktemp -d)"
  export TOKEN_LOG_FILE="$WORKDIR/tokens.jsonl"
  export TOKEN_WORKFLOW="pr-review"
  export PR_URL="https://github.com/petry-projects/x/pull/7"

  MCP_CONFIG_FILE="$WORKDIR/lsp.json"
  echo '{"mcpServers":{"lsp":{"type":"stdio","command":"agent-lsp"}}}' > "$MCP_CONFIG_FILE"

  FINDINGS="$WORKDIR/deep.json"
}

teardown() {
  rm -rf "$WORKDIR"
  unset REVIEW_MCP_CONFIG REVIEW_MCP_ALLOWED_TOOLS TOKEN_LOG_FILE TOKEN_WORKFLOW PR_URL
}

_write_findings() {
  cat > "$FINDINGS"
}

_activate_lsp() {
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="$LSP_ALLOWED"
}

# ── AC #3: inert when LSP is not wired ────────────────────────────────────────

@test "inert: no MCP knob → findings file byte-for-byte unchanged, no JSONL" {
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"critical","category":"correctness","message":"foo() is undefined","lsp_verification":"unverifiable"}]}
JSON
  local before; before="$(cat "$FINDINGS")"
  run apply_lsp_verification "$FINDINGS" "deep"
  [ "$status" -eq 0 ]
  [ "$(cat "$FINDINGS")" = "$before" ]
  [ ! -s "$TOKEN_LOG_FILE" ]
}

@test "inert: MCP wired but no lsp tools (e.g. context7) → unchanged, no JSONL" {
  export REVIEW_MCP_CONFIG="$MCP_CONFIG_FILE"
  export REVIEW_MCP_ALLOWED_TOOLS="mcp__context7__*"
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"critical","category":"correctness","message":"foo() is undefined","lsp_verification":"unverifiable"}]}
JSON
  local before; before="$(cat "$FINDINGS")"
  run apply_lsp_verification "$FINDINGS" "deep"
  [ "$status" -eq 0 ]
  [ "$(cat "$FINDINGS")" = "$before" ]
  [ ! -s "$TOKEN_LOG_FILE" ]
}

@test "inert: lsp wired but CLI output shows MCP failure (degraded) → unchanged" {
  _activate_lsp
  local cli="$WORKDIR/deep.log"
  printf 'MCP server "lsp" failed to connect after 3 attempts\n' > "$cli"
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"critical","category":"correctness","message":"foo() is undefined","lsp_verification":"unverifiable"}]}
JSON
  local before; before="$(cat "$FINDINGS")"
  run apply_lsp_verification "$FINDINGS" "deep" "$cli"
  [ "$status" -eq 0 ]
  [ "$(cat "$FINDINGS")" = "$before" ]
  [ ! -s "$TOKEN_LOG_FILE" ]
}

# ── AC #2: downgrade + annotate the unverifiable finding (never drop) ──────────

@test "downgrade: unverifiable finding is downgraded one level and annotated" {
  _activate_lsp
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"critical","category":"correctness","message":"foo() is undefined","lsp_verification":"unverifiable"}]}
JSON
  run apply_lsp_verification "$FINDINGS" "deep"
  [ "$status" -eq 0 ]
  # Finding is NOT dropped.
  [ "$(jq '.findings | length' "$FINDINGS")" = "1" ]
  # critical → major.
  [ "$(jq -r '.findings[0].severity' "$FINDINGS")" = "major" ]
  # Annotated so the downgrade is visible/auditable in the posted body.
  run jq -r '.findings[0].message' "$FINDINGS"
  [[ "$output" == *"[lsp: unverifiable]"* ]]
}

@test "downgrade: ladder bottoms out at info (minor → info, info → info)" {
  _activate_lsp
  _write_findings <<'JSON'
{"tier":"audit","findings":[
  {"severity":"minor","category":"x","message":"a","lsp_verification":"unverifiable"},
  {"severity":"info","category":"y","message":"b","lsp_verification":"unverifiable"}
]}
JSON
  run apply_lsp_verification "$FINDINGS" "audit"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].severity' "$FINDINGS")" = "info" ]
  [ "$(jq -r '.findings[1].severity' "$FINDINGS")" = "info" ]
}

@test "verified: finding is left intact (no downgrade, no annotation)" {
  _activate_lsp
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"major","category":"correctness","message":"breaks 3 callers","lsp_verification":"verified"}]}
JSON
  run apply_lsp_verification "$FINDINGS" "deep"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].severity' "$FINDINGS")" = "major" ]
  run jq -r '.findings[0].message' "$FINDINGS"
  [ "$output" = "breaks 3 callers" ]
}

@test "untouched: a finding with no lsp_verification annotation is not changed" {
  _activate_lsp
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"critical","category":"style","message":"prefer printf"}]}
JSON
  run apply_lsp_verification "$FINDINGS" "deep"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].severity' "$FINDINGS")" = "critical" ]
  # No verification record for an un-annotated finding.
  [ ! -s "$TOKEN_LOG_FILE" ]
}

# ── AC #4: per-finding verification outcome on the Token Observatory JSONL ─────

@test "jsonl: one finding_verification record per verified/unverifiable finding" {
  _activate_lsp
  _write_findings <<'JSON'
{"tier":"deep","findings":[
  {"severity":"critical","category":"correctness","message":"undefined sym","lsp_verification":"unverifiable"},
  {"severity":"major","category":"correctness","message":"breaks 2 callers","lsp_verification":"verified"},
  {"severity":"minor","category":"style","message":"nit"}
]}
JSON
  run apply_lsp_verification "$FINDINGS" "deep"
  [ "$status" -eq 0 ]
  # Two records (the un-annotated finding produces none).
  [ "$(grep -c . "$TOKEN_LOG_FILE")" = "2" ]
  # Every record is discriminated as a finding_verification record.
  run jq -rs 'map(select(.kind == "finding_verification")) | length' "$TOKEN_LOG_FILE"
  [ "$output" = "2" ]
}

@test "jsonl: record carries tier, outcome, and before/after severities" {
  _activate_lsp
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"critical","category":"correctness","message":"undefined","lsp_verification":"unverifiable"}]}
JSON
  run apply_lsp_verification "$FINDINGS" "deep"
  [ "$status" -eq 0 ]
  run jq -r '[.kind,.tier,.outcome,.severity_before,.severity_after,.workflow] | @tsv' "$TOKEN_LOG_FILE"
  [ "$output" = "$(printf 'finding_verification\tdeep\tunverifiable\tcritical\tmajor\tpr-review')" ]
}

@test "jsonl: verified outcome keeps severity_after == severity_before" {
  _activate_lsp
  _write_findings <<'JSON'
{"tier":"audit","findings":[{"severity":"major","category":"correctness","message":"ok","lsp_verification":"verified"}]}
JSON
  run apply_lsp_verification "$FINDINGS" "audit"
  [ "$status" -eq 0 ]
  run jq -r '[.outcome,.severity_before,.severity_after] | @tsv' "$TOKEN_LOG_FILE"
  [ "$output" = "$(printf 'verified\tmajor\tmajor')" ]
}

# ── emit_verification_record: no-op safety ────────────────────────────────────

@test "emit_verification_record: no-op when TOKEN_LOG_FILE is unset" {
  unset TOKEN_LOG_FILE
  run emit_verification_record "pr-review" "deep" "ctx" "0" "correctness" "critical" "major" "unverifiable"
  [ "$status" -eq 0 ]
}

@test "emit_verification_record: appends one valid JSONL object" {
  emit_verification_record "pr-review" "deep" "ctx" "0" "correctness" "critical" "major" "unverifiable"
  [ "$(grep -c . "$TOKEN_LOG_FILE")" = "1" ]
  run jq -e '.kind == "finding_verification" and .finding_index == 0' "$TOKEN_LOG_FILE"
  [ "$status" -eq 0 ]
}

# ── apply_lsp_verification: positional-parameter edge cases ──────────────────

@test "shift-guard: called with 1 arg (no tier) and findings contain MCP-failure text → still processes, not inert" {
  # Regression for: shift 2 failing when $# < 2 leaves $@ unchanged, causing
  # lsp_verification_active to scan the findings file for failure patterns.
  _activate_lsp
  # The findings file itself contains text matching the MCP-failure pattern.
  _write_findings <<'JSON'
{"tier":"deep","findings":[{"severity":"critical","category":"correctness","message":"mcp server lsp failed to connect","lsp_verification":"unverifiable"}]}
JSON
  # Called with only the findings file (no tier arg) — the risky case.
  run apply_lsp_verification "$FINDINGS"
  [ "$status" -eq 0 ]
  # Verification must be active: the unverifiable finding must be downgraded.
  [ "$(jq -r '.findings[0].severity' "$FINDINGS")" = "major" ]
  run jq -r '.findings[0].message' "$FINDINGS"
  [[ "$output" == *"[lsp: unverifiable]"* ]]
}
