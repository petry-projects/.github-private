#!/usr/bin/env bats
# Unit tests for scripts/lib/finding-verification.sh + emit_verification_record
# (issue #1092, epic #1088 — agentic iterative validation). Written TDD-first.
#
# apply_finding_verification() mirrors the documented lsp-verification downgrade
# discipline: it applies severity downgrades/drops to deep-tier logic/correctness
# findings based on the repro `verification` tag the deep tier recorded, and emits
# one kind:"finding_verification" record per processed finding so the FP-rate
# delta is measurable. Reward-hacking guard: only `refuted` (repro actively failed
# to reproduce) downgrades; `unverifiable` (no runnable target) never does.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FV_LIB="$SCRIPT_DIR/scripts/lib/finding-verification.sh"
TOKEN_LIB="$SCRIPT_DIR/scripts/lib/token-metrics.sh"

setup() {
  # shellcheck source=../../../scripts/lib/token-metrics.sh
  source "$TOKEN_LIB"
  # shellcheck source=../../../scripts/lib/finding-verification.sh
  source "$FV_LIB"
  TOKEN_LOG_FILE="$(mktemp)"
  export TOKEN_LOG_FILE
  DEEP_JSON="$(mktemp)"
}

teardown() {
  [ -n "${TOKEN_LOG_FILE:-}" ] && rm -f "$TOKEN_LOG_FILE"
  [ -n "${DEEP_JSON:-}" ] && rm -f "$DEEP_JSON"
  unset TOKEN_LOG_FILE
}

# Helper: write a deep.json with a single finding of the given
# category/severity/verification.
_write_one() {
  local category="$1" severity="$2" verification="$3"
  jq -n \
    --arg cat "$category" --arg sev "$severity" --arg v "$verification" \
    '{
      tier: "deep", decision: "escalate", risk: "HIGH",
      findings: [ { severity: $sev, category: $cat, message: "boom", file: "a.sh", line: 10, verification: $v } ]
    }' > "$DEEP_JSON"
}

_records() { jq -c 'select(.kind=="finding_verification")' "$TOKEN_LOG_FILE" 2>/dev/null; }
_record_count() { _records | wc -l | tr -d ' '; }

# ── emit_verification_record ──────────────────────────────────────────────────

@test "emit_verification_record: no-op when TOKEN_LOG_FILE unset" {
  unset TOKEN_LOG_FILE
  run emit_verification_record pr-review deep refuted critical major 0 pr
  [ "$status" -eq 0 ]
}

@test "emit_verification_record: writes a kind:finding_verification record with fields" {
  emit_verification_record pr-review deep refuted critical major 3 "https://pr/1"
  [ "$(jq -r '.kind' "$TOKEN_LOG_FILE")" = "finding_verification" ]
  [ "$(jq -r '.workflow' "$TOKEN_LOG_FILE")" = "pr-review" ]
  [ "$(jq -r '.tier' "$TOKEN_LOG_FILE")" = "deep" ]
  [ "$(jq -r '.outcome' "$TOKEN_LOG_FILE")" = "refuted" ]
  [ "$(jq -r '.severity_before' "$TOKEN_LOG_FILE")" = "critical" ]
  [ "$(jq -r '.severity_after' "$TOKEN_LOG_FILE")" = "major" ]
  [ "$(jq -r '.finding_index' "$TOKEN_LOG_FILE")" = "3" ]
  [ "$(jq -r '.context' "$TOKEN_LOG_FILE")" = "https://pr/1" ]
}

# ── _fv_downgrade_severity ────────────────────────────────────────────────────

@test "_fv_downgrade_severity: critical->major, major->minor, minor->info, info->drop" {
  [ "$(_fv_downgrade_severity critical)" = "major" ]
  [ "$(_fv_downgrade_severity major)" = "minor" ]
  [ "$(_fv_downgrade_severity minor)" = "info" ]
  [ "$(_fv_downgrade_severity info)" = "" ]
}

# ── apply_finding_verification: refuted downgrades ────────────────────────────

@test "apply: refuted critical logic finding downgrades to major + emits record" {
  _write_one logic critical refuted
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$(jq -r '.findings[0].severity' "$DEEP_JSON")" = "major" ]
  [ "$(_record_count)" = "1" ]
  [ "$(_records | jq -r '.outcome')" = "refuted" ]
  [ "$(_records | jq -r '.severity_before')" = "critical" ]
  [ "$(_records | jq -r '.severity_after')" = "major" ]
}

@test "apply: refuted info logic finding is DROPPED from findings" {
  _write_one logic info refuted
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$(jq -r '.findings | length' "$DEEP_JSON")" = "0" ]
  [ "$(_record_count)" = "1" ]
  [ "$(_records | jq -r '.severity_after')" = "dropped" ]
}

@test "apply: correctness category is also treated as logic-class" {
  _write_one correctness major refuted
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$(jq -r '.findings[0].severity' "$DEEP_JSON")" = "minor" ]
  [ "$(_record_count)" = "1" ]
}

# ── apply_finding_verification: unverifiable never downgrades ──────────────────

@test "apply: unverifiable logic finding keeps severity (reward-hacking guard)" {
  _write_one logic critical unverifiable
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$(jq -r '.findings[0].severity' "$DEEP_JSON")" = "critical" ]
  [ "$(_record_count)" = "1" ]
  [ "$(_records | jq -r '.outcome')" = "unverifiable" ]
  [ "$(_records | jq -r '.severity_before')" = "$(_records | jq -r '.severity_after')" ]
}

@test "apply: confirmed logic finding keeps severity + emits record" {
  _write_one logic critical confirmed
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$(jq -r '.findings[0].severity' "$DEEP_JSON")" = "critical" ]
  [ "$(_record_count)" = "1" ]
  [ "$(_records | jq -r '.outcome')" = "confirmed" ]
}

# ── apply_finding_verification: only logic-class findings are touched ──────────

@test "apply: non-logic category (security) is untouched even when refuted" {
  _write_one security critical refuted
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$(jq -r '.findings[0].severity' "$DEEP_JSON")" = "critical" ]
  [ "$(_record_count)" = "0" ]
}

@test "apply: logic finding without a verification tag is untouched" {
  jq -n '{ tier:"deep", findings:[ {severity:"critical", category:"logic", message:"x"} ] }' > "$DEEP_JSON"
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$(jq -r '.findings[0].severity' "$DEEP_JSON")" = "critical" ]
  [ "$(_record_count)" = "0" ]
}

# ── apply_finding_verification: mixed set + top-level preservation ─────────────

@test "apply: processes each logic finding once, leaves others intact, preserves top-level" {
  jq -n '{
    tier:"deep", decision:"escalate", risk:"HIGH",
    findings: [
      {severity:"critical", category:"logic",    message:"a", verification:"refuted"},
      {severity:"major",    category:"security",  message:"b"},
      {severity:"minor",    category:"correctness", message:"c", verification:"unverifiable"}
    ]
  }' > "$DEEP_JSON"
  apply_finding_verification "$DEEP_JSON" pr-review deep pr
  # logic refuted critical -> major
  [ "$(jq -r '.findings[0].severity' "$DEEP_JSON")" = "major" ]
  # security untouched
  [ "$(jq -r '.findings[1].severity' "$DEEP_JSON")" = "major" ]
  # correctness unverifiable unchanged
  [ "$(jq -r '.findings[2].severity' "$DEEP_JSON")" = "minor" ]
  # two logic-class findings processed -> two records
  [ "$(_record_count)" = "2" ]
  # top-level fields preserved
  [ "$(jq -r '.decision' "$DEEP_JSON")" = "escalate" ]
  [ "$(jq -r '.risk' "$DEEP_JSON")" = "HIGH" ]
}

# ── apply_finding_verification: safe no-ops ────────────────────────────────────

@test "apply: missing file is a no-op (returns 0, no records)" {
  run apply_finding_verification "/tmp/does-not-exist-$$.json" pr-review deep pr
  [ "$status" -eq 0 ]
  [ "$(_record_count)" = "0" ]
}

@test "apply: invalid JSON is a no-op (returns 0, no records)" {
  printf 'not json{' > "$DEEP_JSON"
  run apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$status" -eq 0 ]
  [ "$(_record_count)" = "0" ]
}

@test "apply: findings-less JSON is a no-op" {
  jq -n '{tier:"deep", decision:"approve", risk:"LOW"}' > "$DEEP_JSON"
  run apply_finding_verification "$DEEP_JSON" pr-review deep pr
  [ "$status" -eq 0 ]
  [ "$(_record_count)" = "0" ]
}
