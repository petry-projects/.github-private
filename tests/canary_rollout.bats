#!/usr/bin/env bats
# Unit tests for the canary-rollout decision core (scripts/lib/canary-rollout.sh)
# and the scripts/canary-rollout.sh orchestrator's pure paths (with gh stubs).
# Initiative #495 · issues #501 (promotion) / #502 (rollback + observability).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/canary-rollout.sh"
ORCH="$SCRIPT_DIR/scripts/canary-rollout.sh"
RINGS="$SCRIPT_DIR/standards/canary-rings.json"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── ceil_div ──────────────────────────────────────────────────────────────────
@test "ceil_div: exact division" { [ "$(ceil_div 14 7)" -eq 2 ]; }
@test "ceil_div: rounds up remainder" { [ "$(ceil_div 15 7)" -eq 3 ]; [ "$(ceil_div 1 7)" -eq 1 ]; }
@test "ceil_div: zero numerator → 0" { [ "$(ceil_div 0 7)" -eq 0 ]; }
@test "ceil_div: zero denominator → 0 + nonzero rc" {
  run ceil_div 5 0
  [ "$status" -ne 0 ]; [ "$output" -eq 0 ]
}

# ── min_healthy_runs = ceil(baseline/7) ───────────────────────────────────────
@test "min_healthy_runs: ceil(baseline/7)" {
  [ "$(min_healthy_runs 70)" -eq 10 ]
  [ "$(min_healthy_runs 71)" -eq 11 ]
  [ "$(min_healthy_runs 6)" -eq 1 ]
}
@test "min_healthy_runs: unused reusable (baseline 0) → 0" { [ "$(min_healthy_runs 0)" -eq 0 ]; }

# ── failure_rate_permille ─────────────────────────────────────────────────────
@test "failure_rate_permille: basic" { [ "$(failure_rate_permille 1 10)" -eq 100 ]; }
@test "failure_rate_permille: zero total → 0 (no div-by-zero)" { [ "$(failure_rate_permille 0 0)" -eq 0 ]; }
@test "failure_rate_permille: all failing" { [ "$(failure_rate_permille 5 5)" -eq 1000 ]; }

# ── decide_gate (the state machine) ───────────────────────────────────────────
@test "decide_gate: quality holds + volume met → PROMOTE" {
  [ "$(decide_gate 10 10 50 50)" = "PROMOTE" ]   # equal failure rate is OK (<=)
  [ "$(decide_gate 12 10 20 50)" = "PROMOTE" ]   # better failure rate, over volume
}
@test "decide_gate: quality holds but volume short → SOAKING" {
  [ "$(decide_gate 4 10 0 100)" = "SOAKING" ]
}
@test "decide_gate: zero healthy runs (unused) → SOAKING, never PROMOTE" {
  [ "$(decide_gate 0 0 0 0)" = "SOAKING" ]   # min 0 but zero volume must not promote
}
@test "decide_gate: candidate failure-rate worse than baseline → INVESTIGATE" {
  [ "$(decide_gate 100 10 200 100)" = "INVESTIGATE" ]
}
@test "decide_gate: quality breach beats volume (checked first)" {
  # volume is met (50>=10) but failure rate is worse → must INVESTIGATE, not PROMOTE
  [ "$(decide_gate 50 10 300 100)" = "INVESTIGATE" ]
}

# ── next_channel_in_order ─────────────────────────────────────────────────────
@test "next_channel_in_order: walks the ring order" {
  [ "$(next_channel_in_order next  'next,ring0,ring1,stable')" = "ring0" ]
  [ "$(next_channel_in_order ring0 'next,ring0,ring1,stable')" = "ring1" ]
  [ "$(next_channel_in_order ring1 'next,ring0,ring1,stable')" = "stable" ]
}
@test "next_channel_in_order: last ring → empty" {
  [ -z "$(next_channel_in_order stable 'next,ring0,ring1,stable')" ]
}

# ── canary-rings.json SoT shape ───────────────────────────────────────────────
@test "canary-rings.json: valid JSON + dev-lead host + ordered rings" {
  run jq -e '.agents["dev-lead"].host == "petry-projects/.github-private"' "$RINGS"
  [ "$status" -eq 0 ]
  # rings are ordered next→ring0→ring1→stable
  run bash -c "jq -r '.agents[\"dev-lead\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  # ring1 names the two low-traffic consumers
  run jq -e '.agents["dev-lead"].rings[] | select(.channel=="ring1") | (.members | index("petry-projects/TalkTerm")) and (.members | index("petry-projects/bmad-bgreat-suite"))' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── orchestrator: resolve_members (host-relative tokens) ──────────────────────
@test "orchestrator: resolve_members expands \$host / \$org_infra / * " {
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead next"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github-private" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring0"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github" ]   # org_infra minus host
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring1"
  [[ "$output" == *"petry-projects/TalkTerm"* ]]
  [[ "$output" == *"petry-projects/bmad-bgreat-suite"* ]]
}

# ── orchestrator: evaluate (read-only) with stubbed gh/git ────────────────────
_make_stub_bin() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  # git: channel/release tags all resolve to distinct fake commits
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse"*"dev-lead/v1.4.0"*) echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *"rev-parse"*"dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *"rev-parse"*"dev-lead/ring0"*)  echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *"rev-parse"*"dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*"dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"tag -f"*) : ;;
  *"push"*)   : ;;
  *"fetch"*)  : ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
}

teardown() { [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; return 0; }

@test "orchestrator: evaluate prints a per-ring gate report and exits 0 (read-only)" {
  _make_stub_bin
  # gh stub: report run counts so ring1 (frontier, candidate=ring0 commit not yet on it) soaks
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# evaluate only needs run-list JSON; return an empty set (low-traffic → SOAKING)
case "$*" in
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"

  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"next"* ]]
  [[ "$output" == *"stable"* ]]
}

@test "orchestrator: promote --override --dry-run shows the move but never pushes" {
  _make_stub_bin
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  local pushlog="$STUB_BIN/push.log"
  # next + ring0 already on candidate (cccc); ring1 + stable on the old version (bbbb)
  # → frontier = ring1, so there is something to promote.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse"*"dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*"dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*) echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *"push"*) echo "\$*" >> "$pushlog" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"

  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --override --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$pushlog" ]   # dry-run must not push
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"ring1"* ]]   # the frontier it would advance
}
