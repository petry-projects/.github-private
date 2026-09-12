#!/usr/bin/env bats
# Regression guard for the qa-lead risk-tiering recalibration (#1698).
#
# #1698 found qa-lead over-escalates a test-infrastructure flakiness symptom to
# HIGH/escalate where the reference is MEDIUM/no. The fix lives in the advisory
# prompt's risk-tiering guidance (prompts/qa-lead/advisory.md), but its calibration
# is characterised by held-out cases that separate three distinct signals:
#
#   - flakiness with no production impact          -> MEDIUM / escalate no
#   - flakiness that MASKS a real production race  -> HIGH   / escalate yes
#   - a slow-but-deterministic suite               -> LOW    / escalate no
#
# This test pins those three additions (AC #1) and asserts the six pre-existing
# held-out cases keep their expected escalate/risk verdicts, enforcing AC #2's
# "holdout stays byte-stable except for AC #1's additions" — in particular that
# the flaky-network-e2e reference stays MEDIUM/no and payment-happy-only stays
# HIGH/yes (the bias must not be "fixed" by weakening the references).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOLDOUT="$ROOT/evals/qa-lead/holdout/cases.jsonl"
}

# assert_case <id> <escalate true|false> <risk LOW|MEDIUM|HIGH>
assert_case() {
  local id="$1" escalate="$2" risk="$3"
  run python3 -c '
import json, sys
path, cid, want_esc, want_risk = sys.argv[1:5]
want_esc = want_esc == "true"
found = None
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    case = json.loads(line)
    if case.get("id") == cid:
        found = case
        break
if found is None:
    print(f"missing case id: {cid}")
    sys.exit(1)
exp = found.get("expected", {})
esc_val = exp.get("escalate")
if esc_val is not want_esc:
    print(f"{cid}: escalate={esc_val} want {want_esc}")
    sys.exit(1)
risk_val = exp.get("risk")
if risk_val != want_risk:
    print(f"{cid}: risk={risk_val} want {want_risk}")
    sys.exit(1)
rec_val = str(exp.get("recommend", "")).strip()
if not rec_val:
    print(f"{cid}: missing non-empty recommend")
    sys.exit(1)
print("ok")
' "$HOLDOUT" "$id" "$escalate" "$risk"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- AC #1: the three new characterization cases ------------------------------

@test "flaky UI/timing test with no production impact is MEDIUM / no-escalate" {
  assert_case "qa-lead-hold-flaky-ui-timing" false MEDIUM
}

@test "flakiness masking a real production race is HIGH / escalate" {
  assert_case "qa-lead-hold-flaky-masks-real-race" true HIGH
}

@test "slow-but-deterministic suite is LOW / no-escalate" {
  assert_case "qa-lead-hold-slow-deterministic-suite" false LOW
}

# --- AC #2: the six pre-existing references are unchanged ----------------------

@test "flaky-network-e2e reference stays MEDIUM / no-escalate" {
  assert_case "qa-lead-hold-flaky-network-e2e" false MEDIUM
}

@test "payment-happy-only reference stays HIGH / escalate" {
  assert_case "qa-lead-hold-payment-happy-only" true HIGH
}

@test "auth-no-contract reference stays HIGH / escalate" {
  assert_case "qa-lead-hold-auth-no-contract" true HIGH
}

@test "migration-no-rollback-test reference stays HIGH / escalate" {
  assert_case "qa-lead-hold-migration-no-rollback-test" true HIGH
}

@test "coverage-gaming reference stays MEDIUM / escalate" {
  assert_case "qa-lead-hold-coverage-gaming" true MEDIUM
}

@test "well-tested-refactor reference stays LOW / no-escalate" {
  assert_case "qa-lead-hold-well-tested-refactor" false LOW
}

# --- The committed holdout stays schema-valid with the additions --------------

@test "committed qa-lead holdout validates against the case schema" {
  run python3 "$ROOT/evals/validate-cases.py" "$HOLDOUT" "$ROOT/evals/case.schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
