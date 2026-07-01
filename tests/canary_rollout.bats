#!/usr/bin/env bats
# Unit tests for the canary-rollout decision core (scripts/lib/canary-rollout.sh)
# and the scripts/canary-rollout.sh orchestrator's pure paths (with gh stubs).
# Initiative #495 · issues #501 (promotion) / #502 (rollback + observability).
# Gate standard: .github#548 (graduated dwell/sample, robust baseline,
# per-candidate cumulative window, ring0 sample waiver, failure triage).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/canary-rollout.sh"
ORCH="$SCRIPT_DIR/scripts/canary-rollout.sh"
RINGS="$SCRIPT_DIR/standards/canary-rings.json"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── clamp ─────────────────────────────────────────────────────────────────────
@test "clamp: within range is unchanged" { [ "$(clamp 7 3 15)" -eq 7 ]; }
@test "clamp: below floor snaps to floor" { [ "$(clamp 1 3 15)" -eq 3 ]; }
@test "clamp: above ceiling snaps to ceiling" { [ "$(clamp 25 3 15)" -eq 15 ]; }
@test "clamp: at bounds is inclusive" { [ "$(clamp 3 3 15)" -eq 3 ]; [ "$(clamp 15 3 15)" -eq 15 ]; }

# ── round_div (banker-free half-up rounding) ──────────────────────────────────
@test "round_div: exact" { [ "$(round_div 10 5)" -eq 2 ]; }
@test "round_div: rounds half up" { [ "$(round_div 5 2)" -eq 3 ]; [ "$(round_div 7 2)" -eq 4 ]; }
@test "round_div: rounds down below half" { [ "$(round_div 4 3)" -eq 1 ]; }
@test "round_div: zero denominator → 0 + nonzero rc" {
  run round_div 5 0
  [ "$status" -ne 0 ]; [ "$output" -eq 0 ]
}

# ── median_x2 (2×median, exact integer even for even-length sets) ──────────────
@test "median_x2: odd length" { [ "$(median_x2 1 5 3)" -eq 6 ]; }   # median 3 → 6
@test "median_x2: even length sums the two middles" { [ "$(median_x2 4 4 4 4)" -eq 8 ]; }  # 4+4
@test "median_x2: unsorted input" { [ "$(median_x2 40 2 2 40 2 2)" -eq 4 ]; } # sorted middles 2,2
@test "median_x2: empty → 0" { [ "$(median_x2)" -eq 0 ]; }

# ── robust_sample_target: robust baseline = spike-capped mean, then clamp ──────
# fraction_permille=250 (0.25), clamp [3,15].
@test "robust_sample_target: steady volume → round(0.25·avg)" {
  # 14 days all = 40 → avg 40 → 0.25·40 = 10 → clamp 10
  set -- 40 40 40 40 40 40 40 40 40 40 40 40 40 40
  [ "$(robust_sample_target 250 3 15 "$@")" -eq 10 ]
}
@test "robust_sample_target: below floor clamps up to 3" {
  set -- 4 4 4 4 4 4 4 4 4 4 4 4 4 4   # avg 4 → 0.25·4 = 1 → clamp 3
  [ "$(robust_sample_target 250 3 15 "$@")" -eq 3 ]
}
@test "robust_sample_target: above ceiling clamps down to 15" {
  set -- 100 100 100 100 100 100 100 100 100 100 100 100 100 100  # 25 → clamp 15
  [ "$(robust_sample_target 250 3 15 "$@")" -eq 15 ]
}
@test "robust_sample_target: a 2500-run loop day is capped at 3× median (not inflated to 15)" {
  # 13 low days of 2 + one 2500-run loop day. Robust baseline caps the spike at
  # 3× median (=6), so the target stays a reachable 3 — NOT the 15 a raw mean gives.
  set -- 2 2 2 2 2 2 2 2 2 2 2 2 2 2500
  [ "$(robust_sample_target 250 3 15 "$@")" -eq 3 ]
  # sanity: the naive (uncapped) mean would blow past the ceiling
  local sum=0 n=0 c; for c in "$@"; do sum=$((sum+c)); n=$((n+1)); done
  [ "$(clamp "$(round_div $((250*sum)) $((1000*n)))" 3 15)" -eq 15 ]
}

# ── dwell_met ─────────────────────────────────────────────────────────────────
@test "dwell_met: at/over floor → 1" { [ "$(dwell_met 4 4)" -eq 1 ]; [ "$(dwell_met 9 8)" -eq 1 ]; }
@test "dwell_met: under floor → 0" { [ "$(dwell_met 3 4)" -eq 0 ]; }

# ── iso_after (per-candidate cumulative window predicate) ──────────────────────
@test "iso_after: strictly-after and equal are 'yes'" {
  [ "$(iso_after 2026-06-28T00:00:00Z 2026-06-28T00:00:00Z)" = yes ]
  [ "$(iso_after 2026-06-29T00:00:00Z 2026-06-28T00:00:00Z)" = yes ]
}
@test "iso_after: excludes a pre-cut failure (pr-review-mention 06-27 before v2.1.1 06-28 cut)" {
  # A run on 06-27 is NOT after the 06-28 candidate cut → must be excluded.
  [ "$(iso_after 2026-06-27T10:00:00Z 2026-06-28T00:00:00Z)" = no ]
}

# ── decide_graduated (dwell + sample + cumulative-health) ─────────────────────
# args: <dwell_h> <dwell_floor> <sample> <sample_target> <sample_waived> <cum_fail> <cum_startup>
@test "decide_graduated: dwell+sample met, clean → PROMOTE" {
  [ "$(decide_graduated 5 4 8 3 false 0 0)" = "PROMOTE" ]
}
@test "decide_graduated: dwell short → SOAKING" {
  [ "$(decide_graduated 3 4 8 3 false 0 0)" = "SOAKING" ]
}
@test "decide_graduated: sample short → SOAKING" {
  [ "$(decide_graduated 5 4 2 3 false 0 0)" = "SOAKING" ]
}
@test "decide_graduated: any cumulative failure → BLOCKED (beats dwell+sample)" {
  [ "$(decide_graduated 99 4 99 3 false 1 0)" = "BLOCKED" ]
  [ "$(decide_graduated 99 4 99 3 false 0 1)" = "BLOCKED" ]
}
@test "decide_graduated: ring0→ring1 waives the fresh sample (cumulative-clean + dwell only)" {
  # sample 0 but waived → PROMOTE once dwell met and clean.
  [ "$(decide_graduated 9 8 0 0 true 0 0)" = "PROMOTE" ]
  # still blocks on a cumulative failure even when waived.
  [ "$(decide_graduated 9 8 0 0 true 1 0)" = "BLOCKED" ]
  # still soaks if dwell not met.
  [ "$(decide_graduated 5 8 0 0 true 0 0)" = "SOAKING" ]
}

# ── classify_failure (triage: regression vs pre-existing/environmental) ────────
# args: <reusable_differs 0|1> <category>
@test "classify_failure: reusable changed + non-environmental → REGRESSION" {
  [ "$(classify_failure 1 unknown)" = "REGRESSION" ]
}
@test "classify_failure: reusable identical to prior version → PRE_EXISTING" {
  [ "$(classify_failure 0 unknown)" = "PRE_EXISTING" ]
}
@test "classify_failure: environmental category → PRE_EXISTING even if reusable changed" {
  [ "$(classify_failure 1 comment-cap)" = "PRE_EXISTING" ]
  [ "$(classify_failure 1 rate-limit)" = "PRE_EXISTING" ]
  [ "$(classify_failure 1 infra)" = "PRE_EXISTING" ]
  [ "$(classify_failure 1 data)" = "PRE_EXISTING" ]
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

# ── transition_key (source→frontier lookup key) ───────────────────────────────
@test "transition_key: frontier maps to its source→frontier key" {
  [ "$(transition_key ring0 'next,ring0,ring1,stable')" = "next->ring0" ]
  [ "$(transition_key ring1 'next,ring0,ring1,stable')" = "ring0->ring1" ]
  [ "$(transition_key stable 'next,ring0,ring1,stable')" = "ring1->stable" ]
}

# ── canary-rings.json SoT shape (rings + gate knobs) ──────────────────────────
@test "canary-rings.json: valid JSON + dev-lead host + ordered rings" {
  run jq -e '.agents["dev-lead"].host == "petry-projects/.github-private"' "$RINGS"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.agents[\"dev-lead\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  run jq -e '.agents["dev-lead"].rings[] | select(.channel=="ring1") | (.members | index("petry-projects/TalkTerm")) and (.members | index("petry-projects/bmad-bgreat-suite"))' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: gate block carries #548 per-transition defaults" {
  # baseline window + spike cap
  run jq -e '.agents["dev-lead"].gate.baseline_window_days == 14' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.baseline_spike_cap_multiple == 3' "$RINGS"
  [ "$status" -eq 0 ]
  # next->ring0: 4h dwell, 0.25 fraction, clamp [3,15], dwell-only when source has no caller
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].dwell_hours == 4' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].sample_fraction_permille == 250' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].sample_clamp_min == 3 and .agents["dev-lead"].gate.transitions["next->ring0"].sample_clamp_max == 15' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].waive_sample_if_no_caller == true' "$RINGS"
  [ "$status" -eq 0 ]
  # ring0->ring1: 8h dwell, sample waived (cumulative-only)
  run jq -e '.agents["dev-lead"].gate.transitions["ring0->ring1"].dwell_hours == 8' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["ring0->ring1"].waive_sample == true' "$RINGS"
  [ "$status" -eq 0 ]
  # ring1->stable: 12h dwell, >=1 ring1 run
  run jq -e '.agents["dev-lead"].gate.transitions["ring1->stable"].dwell_hours == 12' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["ring1->stable"].sample_min == 1' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── orchestrator: resolve_members (host-relative tokens) ──────────────────────
@test "orchestrator: resolve_members expands \$host / \$org_infra / * " {
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead next"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github-private" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring0"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring1"
  [[ "$output" == *"petry-projects/TalkTerm"* ]]
  [[ "$output" == *"petry-projects/bmad-bgreat-suite"* ]]
}

# ── orchestrator: evaluate / promote (read-only + dry-run) with stubs ─────────
_make_stub_bin() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  *"for-each-ref"*) : ;;   # no release-tag date available in the stub
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
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
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
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*) : ;;
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
  [ ! -f "$pushlog" ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"ring1"* ]]
}

# ── orchestrator: full graduated verdicts (cut date + gh run data → gate state) ─
# Lay out next = candidate (cccc); ring0/ring1/stable = prior (bbbb): frontier = ring0,
# transition next->ring0, source = next. The release tag cccc is dated `cut_days` ago,
# so the per-candidate window (and the robust sample target) are exercised end to end.
_graduated_stub() {
  local cut_days="$1" run_days_ago="$2" conclusion="$3" reusable_diff="$4"
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ)"
  # gh: every run-list query returns 20 runs at run_iso with the given conclusion.
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in'
    printf '  *"run list"*) jq -nc --arg d "%s" --arg c "%s" '"'"'[range(20)|{conclusion:$c,createdAt:$d}]'"'"' ;;\n' "$run_iso" "$conclusion"
    echo '  *) echo "{}" ;;'
    echo 'esac'
  } > "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  # git: only `next` is on the candidate (cccc); ring0/ring1/stable stay on the prior
  # version (bbbb). for-each-ref yields the cccc release tag dated cut_iso; the reusable
  # blob is identical (reusable_diff=0) or differs (=1) between cand and prior.
  local cand_blob="reuseAAAA" prior_blob="reuseAAAA"
  [ "$reusable_diff" = "1" ] && prior_blob="reuseBBBB"
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in'
    printf '  *"for-each-ref"*) echo "cccccccccccccccccccccccccccccccccccccccc||%s" ;;\n' "$cut_iso"
    printf '  *"rev-parse"*"cccccccccccccccccccccccccccccccccccccccc:"*) echo "%s" ;;\n' "$cand_blob"
    printf '  *"rev-parse"*"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:"*) echo "%s" ;;\n' "$prior_blob"
    echo '  *"rev-parse"*"dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc" ;;'
    echo '  *"rev-parse"*"dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;'
    echo '  *"rev-parse"*"dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;'
    echo '  *"rev-parse"*"dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;'
    echo '  *"rev-parse"*) echo "cccccccccccccccccccccccccccccccccccccccc" ;;'
    echo '  *) : ;;'
    echo 'esac'
  } > "$STUB_BIN/git"
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: PROMOTE verdict — dwell + sample met on a clean per-candidate window" {
  # cut 3 days ago, runs 2 days ago, all success → dwell ≫ 4h, sample 20 ≥ target, clean.
  _graduated_stub 3 2 success 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"PROMOTE"* ]]
  [[ "$output" == *"decision for next ring 'ring0'"* ]]
}

@test "orchestrator: BLOCKED + REGRESSION — in-window failure with a changed reusable" {
  # A failure since the candidate cut, and the reusable differs from the prior channel
  # → cumulative-health breach classified as a candidate regression (HALT + rollback).
  _graduated_stub 3 2 failure 1
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"REGRESSION"* ]]
}

@test "orchestrator: BLOCKED + PRE_EXISTING — in-window failure but reusable unchanged" {
  # Same failure, but the reusable is byte-identical to the prior channel → pre-existing,
  # report only (do NOT rollback, do NOT advance).
  _graduated_stub 3 2 failure 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"PRE_EXISTING"* ]]
}
