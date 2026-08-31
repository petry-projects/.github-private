#!/usr/bin/env bats
# Unit tests for the engine-token liveness detector
# (scripts/lib/engine_liveness_detect.sh, issue #1587).
#
# #1587: dev-lead failed 100% of runs across 8 repos for seven days — every run
# died at the "Engine token preflight" step ("CLAUDE_CODE_OAUTH_TOKEN is not
# provided") — and nothing alerted a human. Two gaps: (a) pr-review had no
# preflight so it failed OPEN (looked healthy while reviewing nothing), and
# (b) a sustained fleet-wide preflight failure only accumulated in periodic
# health reports instead of escalating.
#
# This library is the machine-checkable decision layer. Given already-gathered
# run/step metadata it decides, per repo, whether the engine-token preflight is
# failing, and whether the aggregate warrants a FLEET-level alert (the outage
# class) vs. ISOLATED health-check reporting vs. NONE. It also classifies a
# credential's scope/expiry (GH_PAT_DON_PETRY). Detection only — never mutates.
#
# Escalation contract (issue scope 3):
#   AGENTS_PAUSED=true                              -> silent (handled by caller)
#   >=2 consecutive preflight failures in >=2 repos -> FLEET alert
#   otherwise any single-repo failure               -> ISOLATED (routine report)
#
# Run with: bats tests/test_engine_liveness_detect.bats

setup() {
  # BATS creates $BATS_TEST_TMPDIR fresh per test and removes it afterwards, so
  # use it directly — no manual mktemp/teardown, no parallel-run collisions or
  # leftover dirs on failure (gemini review, #1587).
  TMP="$BATS_TEST_TMPDIR"
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/engine_liveness_detect.sh"
}

# ---------------------------------------------------------------------------
# is_preflight_step / step_is_preflight_failure — the step matcher
# ---------------------------------------------------------------------------

@test "is_preflight_step matches the verbatim step name" {
  run is_preflight_step "Engine token preflight (#1525)"
  [ "$status" -eq 0 ]
}

@test "is_preflight_step ignores an unrelated step" {
  run is_preflight_step "Checkout agent repo"
  [ "$status" -ne 0 ]
}

@test "step_is_preflight_failure fires only on a FAILED preflight step" {
  run step_is_preflight_failure "Engine token preflight (#1525)" failure
  [ "$status" -eq 0 ]
}

@test "step_is_preflight_failure does not fire on a passing preflight step" {
  run step_is_preflight_failure "Engine token preflight (#1525)" success
  [ "$status" -ne 0 ]
}

@test "step_is_preflight_failure does not fire on a failure of a DIFFERENT step" {
  run step_is_preflight_failure "Review each PR (cascade)" failure
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# repo_liveness_state <consecutive_preflight_failures>
# ---------------------------------------------------------------------------

@test "repo_liveness_state: 0 consecutive failures -> OK" {
  run repo_liveness_state 0
  [ "$output" = "OK" ]
}

@test "repo_liveness_state: 1 consecutive failure -> FAIL (not yet sustained)" {
  run repo_liveness_state 1
  [ "$output" = "FAIL" ]
}

@test "repo_liveness_state: 2 consecutive failures -> OUTAGE (sustained)" {
  run repo_liveness_state 2
  [ "$output" = "OUTAGE" ]
}

@test "repo_liveness_state: many consecutive failures -> OUTAGE" {
  run repo_liveness_state 7
  [ "$output" = "OUTAGE" ]
}

@test "repo_liveness_state: non-numeric input degrades to OK (never crashes)" {
  run repo_liveness_state "abc"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "repo_liveness_state: missing input -> OK" {
  run repo_liveness_state
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# fleet_escalation <sustained_repo_count> <any_failure_repo_count>
# FLEET requires >=2 repos each sustaining (>=2 consecutive) failures.
# ---------------------------------------------------------------------------

@test "fleet_escalation: 2 sustained repos -> FLEET (the outage class)" {
  run fleet_escalation 2 2
  [ "$output" = "FLEET" ]
}

@test "fleet_escalation: 3 sustained repos -> FLEET" {
  run fleet_escalation 3 3
  [ "$output" = "FLEET" ]
}

@test "fleet_escalation: 1 sustained repo -> ISOLATED (single-repo, not fleet)" {
  run fleet_escalation 1 1
  [ "$output" = "ISOLATED" ]
}

@test "fleet_escalation: 0 sustained but 1 failing repo -> ISOLATED" {
  run fleet_escalation 0 1
  [ "$output" = "ISOLATED" ]
}

@test "fleet_escalation: no failures anywhere -> NONE" {
  run fleet_escalation 0 0
  [ "$output" = "NONE" ]
}

@test "fleet_escalation: a single repo failing on many runs is still ISOLATED, not FLEET" {
  # The fleet gate is about BREADTH (>=2 repos), not depth. One repo alone,
  # however many consecutive failures, must never trip the fleet alarm.
  run fleet_escalation 1 1
  [ "$output" = "ISOLATED" ]
}

@test "fleet_escalation: non-numeric input degrades to NONE" {
  run fleet_escalation "x" "y"
  [ "$output" = "NONE" ]
}

# ---------------------------------------------------------------------------
# monitoring_status <inspected_stubs> <api_errors>
# A NONE all-clear is only trustworthy if the monitor actually inspected
# something. 0 stubs inspected + >=1 non-404 API error -> DEGRADED (#1587).
# ---------------------------------------------------------------------------

@test "monitoring_status: 0 inspected and >=1 API error -> DEGRADED (blind run, not all-clear)" {
  run monitoring_status 0 1
  [ "$output" = "DEGRADED" ]
}

@test "monitoring_status: 0 inspected but 0 API errors -> OK (genuinely nothing to monitor)" {
  run monitoring_status 0 0
  [ "$output" = "OK" ]
}

@test "monitoring_status: some stubs inspected despite an API error -> OK (partial visibility)" {
  run monitoring_status 3 2
  [ "$output" = "OK" ]
}

@test "monitoring_status: non-numeric input degrades to OK (never crashes)" {
  run monitoring_status "x" "y"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# pat_expiry_state <expiration_value> [warn_days] [now_epoch]
# ---------------------------------------------------------------------------

@test "pat_expiry_state: empty value -> NO_EXPIRY (a classic PAT with no expiry)" {
  run pat_expiry_state "" 14 100000
  [ "$output" = "NO_EXPIRY" ]
}

@test "pat_expiry_state: an expiry already in the past -> EXPIRED" {
  # now = 2026-08-30, expiry = 2026-08-01
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  run pat_expiry_state "2026-08-01 12:00:00 UTC" 14 "$now"
  [ "$output" = "EXPIRED" ]
}

@test "pat_expiry_state: an expiry inside the warn window -> EXPIRING" {
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  run pat_expiry_state "2026-09-05 00:00:00 UTC" 14 "$now"
  [ "$output" = "EXPIRING" ]
}

@test "pat_expiry_state: an expiry far in the future -> OK" {
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  run pat_expiry_state "2027-08-30 00:00:00 UTC" 14 "$now"
  [ "$output" = "OK" ]
}

@test "pat_expiry_state: unparseable value -> UNKNOWN" {
  run pat_expiry_state "not-a-date" 14 100000
  [ "$output" = "UNKNOWN" ]
}

@test "pat_expiry_state: exactly at the warn boundary -> EXPIRING" {
  now=$(date -u -d "2026-08-30T00:00:00Z" +%s)
  # 14 days out, warn window 14 days -> within window (<=), so EXPIRING
  run pat_expiry_state "2026-09-13 00:00:00 UTC" 14 "$now"
  [ "$output" = "EXPIRING" ]
}

# ---------------------------------------------------------------------------
# pat_missing_scopes / pat_scopes_ok
# ---------------------------------------------------------------------------

@test "pat_missing_scopes: all required present -> empty" {
  run pat_missing_scopes "repo, workflow, read:org" "repo workflow"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pat_missing_scopes: a missing scope is named" {
  run pat_missing_scopes "repo, read:org" "repo workflow"
  [[ "$output" == *"workflow"* ]]
}

@test "pat_scopes_ok exit 0 when nothing missing, non-zero when missing" {
  run pat_scopes_ok "repo, workflow" "repo workflow"
  [ "$status" -eq 0 ]
  run pat_scopes_ok "repo" "repo workflow"
  [ "$status" -ne 0 ]
}

@test "pat_missing_scopes: empty scopes string reports every required scope" {
  run pat_missing_scopes "" "repo workflow"
  [[ "$output" == *"repo"* ]]
  [[ "$output" == *"workflow"* ]]
}

# ---------------------------------------------------------------------------
# escalation_headline — one-line human summary per level
# ---------------------------------------------------------------------------

@test "escalation_headline: FLEET names a fleet-wide outage" {
  run escalation_headline FLEET
  [[ "$output" == *"FLEET"* || "$output" == *"fleet"* ]]
  [[ "$output" == *"outage"* || "$output" == *"OUTAGE"* ]]
}

@test "escalation_headline: NONE is an all-clear" {
  run escalation_headline NONE
  [[ "$output" == *"healthy"* || "$output" == *"clear"* || "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# render_liveness_table — per-repo markdown table / all-clear line
# ---------------------------------------------------------------------------

@test "render_liveness_table renders each repo row with its state" {
  f=$(mktemp "$TMP/rows.XXXXXX")
  printf '%s\t%s\t%s\t%s\n' "petry-projects/ContentTwin" "dev-lead.yml" "OUTAGE" "3" > "$f"
  printf '%s\t%s\t%s\t%s\n' "petry-projects/markets" "pr-review.yml" "OK" "0" >> "$f"
  run render_liveness_table "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ContentTwin"* ]]
  [[ "$output" == *"OUTAGE"* ]]
  [[ "$output" == *"markets"* ]]
}

@test "render_liveness_table on an empty file prints an all-clear line, not a table" {
  f=$(mktemp "$TMP/rows.XXXXXX")
  : > "$f"
  run render_liveness_table "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"| Repo |"* ]]
}
