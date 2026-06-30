#!/usr/bin/env bats
# Unit + integration tests for the fleet-wide soak-and-promote loop (#993):
#   - scripts/lib/soak-promote.sh   — pure decision core (control × gate × ceilings)
#   - scripts/soak-promote.sh        — orchestrator (report-only default; auto path)
#   - release/registry.yml           — fleet registry of first-party reusables
#   - release/control.yml            — declarative override file
#
# The decision core is side-effect-free and source-able. The orchestrator's
# mutating paths are exercised with stubbed git/gh, mirroring tests/canary_rollout.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/soak-promote.sh"
ORCH="$SCRIPT_DIR/scripts/soak-promote.sh"
REGISTRY="$SCRIPT_DIR/release/registry.yml"
CONTROL="$SCRIPT_DIR/release/control.yml"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── ring_index ────────────────────────────────────────────────────────────────
@test "ring_index: 0-based position in the ordered list" {
  [ "$(ring_index next  'next,ring0,ring1,stable')" -eq 0 ]
  [ "$(ring_index ring0 'next,ring0,ring1,stable')" -eq 1 ]
  [ "$(ring_index stable 'next,ring0,ring1,stable')" -eq 3 ]
}
@test "ring_index: unknown ring → nonzero rc" {
  run ring_index nope 'next,ring0,ring1,stable'
  [ "$status" -ne 0 ]
}

# ── version_gt (semver, leading v tolerated) ──────────────────────────────────
@test "version_gt: greater patch/minor/major" {
  run version_gt 2.2.0 2.1.1; [ "$status" -eq 0 ]
  run version_gt 2.1.2 2.1.1; [ "$status" -eq 0 ]
  run version_gt 3.0.0 2.9.9; [ "$status" -eq 0 ]
  run version_gt v2.2.0 v2.1.1; [ "$status" -eq 0 ]
}
@test "version_gt: equal or lesser → nonzero rc" {
  run version_gt 2.1.1 2.1.1; [ "$status" -ne 0 ]
  run version_gt 2.1.0 2.1.1; [ "$status" -ne 0 ]
  run version_gt 1.9.9 2.0.0; [ "$status" -ne 0 ]
}

# ── plan_action: the state machine ────────────────────────────────────────────
# args: <paused> <rollback> <force_ring> <advance_ring> <hold_at> <pin> <candidate_ver> <gate> <ordered_csv>
ORD='next,ring0,ring1,stable'

@test "plan_action: global pause is the kill switch (wins over everything)" {
  run plan_action true 2.0.0 ring1 ring0 ring1 2.0.0 2.5.0 PROMOTE "$ORD"
  [ "$output" = "PAUSED" ]
}
@test "plan_action: rollback one-shot beats force and gate" {
  run plan_action false 2.0.0 ring1 ring0 "" "" 2.5.0 PROMOTE "$ORD"
  [ "$output" = "ROLLBACK 2.0.0" ]
}
@test "plan_action: force one-shot bypasses the gate" {
  run plan_action false "" ring1 ring0 "" "" 2.5.0 SOAKING "$ORD"
  [ "$output" = "FORCE ring1" ]
}
@test "plan_action: empty advance_ring → COMPLETE" {
  run plan_action false "" "" "" "" "" 2.5.0 PROMOTE "$ORD"
  [ "$output" = "COMPLETE" ]
}
@test "plan_action: gate INVESTIGATE → HALT (fail-safe, beats pin/hold)" {
  run plan_action false "" "" ring1 ring0 1.0.0 2.5.0 INVESTIGATE "$ORD"
  [ "$output" = "HALT" ]
}
@test "plan_action: candidate over pin → PINNED" {
  run plan_action false "" "" ring1 "" 2.1.1 2.2.0 PROMOTE "$ORD"
  [ "$output" = "PINNED" ]
}
@test "plan_action: candidate at/under pin is allowed (not PINNED)" {
  run plan_action false "" "" ring1 "" 2.1.1 2.1.1 PROMOTE "$ORD"
  [ "$output" = "ADVANCE ring1" ]
}
@test "plan_action: advance_ring past hold_at → HOLD" {
  # advancing stable while hold_at=ring1 → stable is past the ceiling
  run plan_action false "" "" stable ring1 "" 2.2.0 PROMOTE "$ORD"
  [ "$output" = "HOLD" ]
}
@test "plan_action: advancing up to hold_at is allowed" {
  # advancing ring0 while hold_at=ring1 → ring0 <= ring1, not held
  run plan_action false "" "" ring0 ring1 "" 2.2.0 PROMOTE "$ORD"
  [ "$output" = "ADVANCE ring0" ]
}
@test "plan_action: gate SOAKING → WAIT" {
  run plan_action false "" "" ring1 "" "" 2.2.0 SOAKING "$ORD"
  [ "$output" = "WAIT" ]
}
@test "plan_action: gate PROMOTE + nothing blocking → ADVANCE <ring>" {
  run plan_action false "" "" ring1 "" "" 2.2.0 PROMOTE "$ORD"
  [ "$output" = "ADVANCE ring1" ]
}

# ── status_row ────────────────────────────────────────────────────────────────
@test "status_row: renders a markdown table row with the key fields" {
  run status_row pr-review-mention ring1 2.1.1 PROMOTE "ADVANCE stable"
  [[ "$output" == *"pr-review-mention"* ]]
  [[ "$output" == *"ring1"* ]]
  [[ "$output" == *"2.1.1"* ]]
  [[ "$output" == *"ADVANCE stable"* ]]
  [[ "$output" == "|"* ]]   # markdown table row
}

# ── registry.yml / control.yml shape ──────────────────────────────────────────
@test "registry.yml: valid YAML with a non-empty reusables map" {
  run yq -e '.version' "$REGISTRY"; [ "$status" -eq 0 ]
  run yq -e '.reusables | length > 0' "$REGISTRY"; [ "$status" -eq 0 ]
}
@test "registry.yml: every reusable has a host and ordered rings" {
  run bash -c "yq -o=json '$REGISTRY' | jq -e '[.reusables[] | (has(\"host\") and (.rings|length>0))] | all'"
  [ "$status" -eq 0 ]
}
@test "registry.yml: #684 fleet coverage — includes both hosts' reusables" {
  run bash -c "yq -o=json '$REGISTRY' | jq -e '.reusables | (has(\"dev-lead\") and has(\"pr-review\") and has(\"pr-review-mention\") and has(\"feature-ideation\"))'"
  [ "$status" -eq 0 ]
}
@test "control.yml: valid YAML, autonomous by default (pause:false, no holds)" {
  run yq -e '.pause == false' "$CONTROL"; [ "$status" -eq 0 ]
  run yq -e 'has("reusables")' "$CONTROL"; [ "$status" -eq 0 ]
}

# ── orchestrator integration (stubbed git/gh) ─────────────────────────────────
_fixtures() {
  FIX="$BATS_TEST_TMPDIR"
  cat > "$FIX/registry.yml" <<'YML'
version: 1
reusables:
  dev-lead:
    host: petry-projects/.github-private
    run_workflow: "Dev-Lead Agent"
    gate: { soak_window_days: 7 }
    rings:
      - { channel: next,   order: 0, repos: ["$host"] }
      - { channel: ring0,  order: 1, repos: ["$org_infra"] }
      - { channel: ring1,  order: 2, repos: ["petry-projects/TalkTerm"] }
      - { channel: stable, order: 3, repos: ["*"] }
YML
}

_stub_bin() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  PUSHLOG="$STUB_BIN/push.log"
  # next + ring0 on candidate (cccc); ring1 + stable on old (bbbb) → frontier = ring1.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse"*"dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*"dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*) echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *"tag --points-at"*|*"tag -l"*) echo "dev-lead/v2.2.0" ;;
  *"push"*) echo "\$*" >> "$PUSHLOG" ;;
  *"tag -f"*) : ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run list"*) echo "[]" ;;          # empty volume → SOAKING
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

teardown() { [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; return 0; }

@test "orchestrator report: writes STATUS.md, prints the matrix, never pushes" {
  _fixtures; _stub_bin
  cat > "$FIX/control.yml" <<'YML'
pause: false
reusables: {}
YML
  run env SOAK_REGISTRY="$FIX/registry.yml" SOAK_CONTROL="$FIX/control.yml" \
      SOAK_STATUS_OUT="$FIX/STATUS.md" bash "$ORCH" report
  [ "$status" -eq 0 ]
  [ -f "$FIX/STATUS.md" ]
  [[ "$(cat "$FIX/STATUS.md")" == *"dev-lead"* ]]
  [ ! -f "$PUSHLOG" ]   # report-only must never push
}

@test "orchestrator report: a forced override is reported but NOT executed" {
  _fixtures; _stub_bin
  cat > "$FIX/control.yml" <<'YML'
pause: false
reusables:
  dev-lead:
    force: { ring: ring1 }
YML
  run env SOAK_REGISTRY="$FIX/registry.yml" SOAK_CONTROL="$FIX/control.yml" \
      SOAK_STATUS_OUT="$FIX/STATUS.md" bash "$ORCH" report
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORCE"* ]]
  [ ! -f "$PUSHLOG" ]   # report mode never mutates, even on a force override
}

@test "orchestrator auto: a forced override performs the channel-tag move" {
  _fixtures; _stub_bin
  cat > "$FIX/control.yml" <<'YML'
pause: false
reusables:
  dev-lead:
    force: { ring: ring1 }
YML
  run env SOAK_REGISTRY="$FIX/registry.yml" SOAK_CONTROL="$FIX/control.yml" \
      SOAK_STATUS_OUT="$FIX/STATUS.md" bash "$ORCH" auto
  [ "$status" -eq 0 ]
  [ -f "$PUSHLOG" ]                       # auto mode pushed the moved channel tag
  [[ "$(cat "$PUSHLOG")" == *"dev-lead/ring1"* ]]
}

@test "orchestrator report: an empty candidate version still parses cleanly" {
  # Regression: frontier_state fields are tab-delimited so an empty candidate
  # version (no vX.Y.Z tag points at the commit) cannot shift the positional read.
  _fixtures
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse"*"dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*"dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*) echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *"tag --points-at"*) : ;;          # no release tag at the candidate → empty version
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in *"run list"*) echo "[]" ;; *) echo "{}" ;; esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$FIX/control.yml" <<'YML'
pause: false
reusables: {}
YML
  run env SOAK_REGISTRY="$FIX/registry.yml" SOAK_CONTROL="$FIX/control.yml" \
      SOAK_STATUS_OUT="$FIX/STATUS.md" bash "$ORCH" report
  [ "$status" -eq 0 ]
  # frontier (ring1) + gate (WAIT, from SOAKING) must land in the right columns.
  [[ "$(cat "$FIX/STATUS.md")" == *"| dev-lead | ring1 |"* ]]
  [[ "$(cat "$FIX/STATUS.md")" == *"WAIT"* ]]
}

@test "orchestrator auto: global pause halts all mutation" {
  _fixtures; _stub_bin
  cat > "$FIX/control.yml" <<'YML'
pause: true
reusables:
  dev-lead:
    force: { ring: ring1 }
YML
  run env SOAK_REGISTRY="$FIX/registry.yml" SOAK_CONTROL="$FIX/control.yml" \
      SOAK_STATUS_OUT="$FIX/STATUS.md" bash "$ORCH" auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"PAUSED"* ]]
  [ ! -f "$PUSHLOG" ]   # kill switch stops even a forced advance
}
