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
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 10 ]
}
@test "robust_sample_target: below floor clamps up to 3" {
  set -- 4 4 4 4 4 4 4 4 4 4 4 4 4 4   # avg 4 → 0.25·4 = 1 → clamp 3
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 3 ]
}
@test "robust_sample_target: above ceiling clamps down to 15" {
  set -- 100 100 100 100 100 100 100 100 100 100 100 100 100 100  # 25 → clamp 15
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 15 ]
}
@test "robust_sample_target: a 2500-run loop day is capped at 3× median (not inflated to 15)" {
  # 13 low days of 2 + one 2500-run loop day. Robust baseline caps the spike at
  # 3× median (=6), so the target stays a reachable 3 — NOT the 15 a raw mean gives.
  set -- 2 2 2 2 2 2 2 2 2 2 2 2 2 2500
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 3 ]
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

# ── benign_match (per-reusable known-benign failure-class matcher, #1025 P2) ────
# args: <workflow_name> <failure_signature> <workflow_regex> <step_regex>
@test "benign_match: workflow + step signature both match → yes" {
  [ "$(benign_match 'Dev-Lead Agent' 'Push fix-review branch' 'Dev-Lead' '[Pp]ush')" = "yes" ]
}
@test "benign_match: workflow regex mismatch → no" {
  [ "$(benign_match 'Other Workflow' 'Push branch' 'Dev-Lead' '[Pp]ush')" = "no" ]
}
@test "benign_match: signature does not match step regex → no" {
  [ "$(benign_match 'Dev-Lead Agent' 'Compile sources' 'Dev-Lead' '[Pp]ush')" = "no" ]
}
@test "benign_match: empty step regex never matches (guards against a match-all entry)" {
  [ "$(benign_match 'Dev-Lead Agent' 'anything at all' 'Dev-Lead' '')" = "no" ]
}
@test "benign_match: empty workflow regex matches any workflow" {
  [ "$(benign_match 'Whatever' 'Resolve Dependabot dispatch context' '' '[Dd]ependabot')" = "yes" ]
}

# ── canary-rings.json: benign allowlist + control block shape (#1025 P2) ────────
@test "canary-rings.json: dev-lead gate carries a benign_failure_classes allowlist + control block" {
  run jq -e '.agents["dev-lead"].gate.benign_failure_classes | type == "array" and length >= 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.benign_failure_classes | all(has("id") and has("reason") and has("step"))' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.control | has("allow_pre_existing")' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── orchestrator: evaluate-all iterates the whole registry (#1025 P1) ──────────
@test "orchestrator: evaluate-all iterates every agent in the registry (fleet-wide)" {
  _make_stub_bin
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # A registry with a second (cloned) agent proves fleet iteration over the registry
  # keys rather than a dev-lead hardcode.
  local multi="$BATS_TEST_TMPDIR/rings.json"
  jq '.agents["fleet-canary-test"] = .agents["dev-lead"]' "$RINGS" > "$multi"
  run env CANARY_RINGS="$multi" bash "$ORCH" evaluate-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"fleet-canary-test"* ]]
}

# ── orchestrator: benign-failure allowlist excludes known-benign from cum_fail ──
# Lay out next = candidate (cccc); ring0/ring1/stable = prior (bbbb). Every tier repo
# returns `failure` runs whose only failed step is <step>; `gh run view` yields that
# step so the orchestrator can build a signature and test it against the allowlist.
_benign_stub() {
  local cut_days="$1" run_days_ago="$2" step="$3" reusable_diff="$4"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in'
    echo '  *"run list"*)'
    printf '    if [[ "$*" == *"databaseId"* ]]; then jq -nc --arg d "%s" '"'"'[range(3)|{conclusion:"failure",createdAt:$d,databaseId:(1000+.),workflowName:"Dev-Lead Agent"}]'"'"'; else jq -nc --arg d "%s" '"'"'[range(3)|{conclusion:"failure",createdAt:$d}]'"'"'; fi\n' "$run_iso" "$run_iso"
    echo '    ;;'
    printf '  *"run view"*) jq -nc --arg s "%s" '"'"'{jobs:[{steps:[{name:$s,conclusion:"failure"}]}]}'"'"' ;;\n' "$step"
    echo '  *) echo "{}" ;;'
    echo 'esac'
  } > "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
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

@test "orchestrator: allowlisted benign failure (reusable unchanged) is excluded from cum_fail → not BLOCKED" {
  # A git-push-permission failure since cut, but the reusable is byte-identical to the
  # prior channel → matches the [Pp]ush benign class → excluded → gate is not BLOCKED.
  _benign_stub 3 2 "Push fix-review branch" 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" != *"BLOCKED"* ]]
  [[ "$output" == *"benign"* ]]
}

@test "orchestrator: benign allowlist is DISABLED when the candidate changed the reusable → BLOCKED+REGRESSION" {
  # Same push failure + matching class, but the candidate changed the reusable → the
  # allowlist must NOT mask a possible candidate regression.
  _benign_stub 3 2 "Push fix-review branch" 1
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"REGRESSION"* ]]
}

# ── orchestrator: cross-repo agent support (gh api stubs) ──────────────────────
# For agents whose host != petry-projects/.github-private (i.e. the six #482 reusables),
# channel_commit, candidate_cut_date, _reusable_differs, promote, and rollback must
# use gh api rather than local git. The stubs below simulate petry-projects/.github tags.
_make_cross_repo_stub_bin() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  # git: cross-repo channel tags live in petry-projects/.github, not locally.
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
case "$*" in
  *"for-each-ref"*) : ;;
  *"rev-parse"*) : ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  # gh: stub api calls for petry-projects/.github tag/commit/blob lookups.
  # agent-shield/next → annotated tag object tagobj1111 → commit cccc...
  # agent-shield/{ring0,ring1,stable} → lightweight ref pointing to bbbb...
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  api*"repos/petry-projects/.github/git/ref/tags/agent-shield/next"*)
    echo '{"object":{"sha":"tagobj1111111111111111111111111111111111","type":"tag"}}' ;;
  api*"repos/petry-projects/.github/git/tags/tagobj"*)
    echo '{"object":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}}' ;;
  api*"repos/petry-projects/.github/git/ref/tags/agent-shield/"*)
    echo '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}' ;;
  api*"repos/petry-projects/.github/commits/"*)
    echo '{"commit":{"committer":{"date":"2026-07-01T10:00:00Z"}}}' ;;
  api*"repos/petry-projects/.github/contents/"*)
    echo '{"sha":"blobAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}' ;;
  api*"repos/petry-projects/.github/git/ref/tags/"*)
    echo '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}' ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "orchestrator: channel_commit uses gh api for cross-repo agents" {
  # agent-shield's channel tags live in petry-projects/.github; local git has nothing.
  _make_cross_repo_stub_bin
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' channel_commit agent-shield next"
  [ "$status" -eq 0 ]
  [ "$output" = "cccccccccccccccccccccccccccccccccccccccc" ]
}

@test "orchestrator: _reusable_differs uses gh api contents endpoint for cross-repo agents" {
  # Both blobs return the same sha → differs=0 (no regression introduced).
  _make_cross_repo_stub_bin
  run bash -c "
    source '$ORCH'
    CANARY_RINGS='$RINGS' _reusable_differs agent-shield \
      cccccccccccccccccccccccccccccccccccccccc \
      bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  "
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "orchestrator: _reusable_differs returns 1 when cross-repo blob changes" {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
:
GITEOF
  chmod +x "$STUB_BIN/git"
  # Different blob sha for cand vs prior → differs=1 (candidate regression possible).
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  api*"?ref=cccc"*) echo '{"sha":"blobAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}' ;;
  api*"?ref=bbbb"*) echo '{"sha":"blobBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run bash -c "
    source '$ORCH'
    CANARY_RINGS='$RINGS' _reusable_differs agent-shield cccc bbbb
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "orchestrator: evaluate for cross-repo agent-shield resolves channel tags via gh api" {
  _make_cross_repo_stub_bin
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate agent-shield
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-shield"* ]]
  [[ "$output" == *"next"* ]]
}

@test "orchestrator: promote --override --dry-run for cross-repo agent-shield uses gh api path" {
  _make_cross_repo_stub_bin
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote agent-shield --override --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"petry-projects/.github"* ]]
}

@test "orchestrator: a non-allowlisted failure (reusable unchanged) still BLOCKS as PRE_EXISTING" {
  # Failed step matches no benign class → counted → BLOCKED, triaged PRE_EXISTING.
  _benign_stub 3 2 "Compile TypeScript" 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"PRE_EXISTING"* ]]
}

# ── orchestrator: promote --allow-pre-existing (control override, #1025 P2) ─────
@test "orchestrator: promote --allow-pre-existing advances a BLOCKED+PRE_EXISTING frontier (dry-run)" {
  _graduated_stub 3 2 failure 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --allow-pre-existing --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"PRE_EXISTING"* ]]
  [[ "$output" != *"not promoting"* ]]
}

@test "orchestrator: promote --allow-pre-existing REFUSES a BLOCKED+REGRESSION frontier" {
  _graduated_stub 3 2 failure 1
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --allow-pre-existing --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRY-RUN"* ]]
  [[ "$output" == *"REGRESSION"* ]]
}

# ── canary-rings.json: the 6 #482 cross-repo reusables (#1036) ─────────────────
# These were rolled out manually via the now-retired bridge and were never onboarded
# into the registry, so `evaluate-all` could not see them. All 6 host in the public
# petry-projects/.github repo (cross-repo) and share one ring topology: the rollout is
# canaried in .github-private (the caller-stub/automation repo) FIRST, then the host.
_REUSABLES_482="agent-shield dependency-audit auto-rebase dependabot-automerge dependabot-rebase pr-review-mention"

@test "canary-rings.json: all 6 #482 reusables are registered (7 agents incl. dev-lead)" {
  run jq -e '.agents | keys | length == 7' "$RINGS"
  [ "$status" -eq 0 ]
  for a in $_REUSABLES_482; do
    jq -e --arg a "$a" '.agents | has($a)' "$RINGS" >/dev/null
  done
}

@test "canary-rings.json: each #482 reusable has host .github + right reusable path + run_workflow" {
  # host, reusable path, run_workflow per the #1036 table (col 2 / col 3).
  _chk() {
    jq -e --arg a "$1" '.agents[$a].host == "petry-projects/.github"' "$RINGS" >/dev/null
    jq -e --arg a "$1" --arg r "$2" '.agents[$a].reusable == $r' "$RINGS" >/dev/null
    jq -e --arg a "$1" --arg w "$3" '.agents[$a].run_workflow == $w' "$RINGS" >/dev/null
  }
  _chk agent-shield         ".github/workflows/agent-shield-reusable.yml"         "agent-shield.yml"
  _chk dependency-audit     ".github/workflows/dependency-audit-reusable.yml"     "dependency-audit.yml"
  _chk auto-rebase          ".github/workflows/auto-rebase-reusable.yml"          "auto-rebase.yml"
  _chk dependabot-automerge ".github/workflows/dependabot-automerge-reusable.yml" "dependabot-automerge.yml"
  _chk dependabot-rebase    ".github/workflows/dependabot-rebase-reusable.yml"    "dependabot-rebase.yml"
  _chk pr-review-mention    ".github/workflows/pr-review-mention-reusable.yml"    "pr-review-mention.yml"
}

@test "canary-rings.json: #482 reusables share the ring topology (next=.github-private, ring0=.github, ring1 pair, stable=*)" {
  for a in $_REUSABLES_482; do
    run bash -c "jq -r '.agents[\"$a\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
    [ "$status" -eq 0 ]
    [ "$output" = "next,ring0,ring1,stable" ]
    jq -e --arg a "$a" '.agents[$a].rings[] | select(.channel=="next")  | .members == ["petry-projects/.github-private"]' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].rings[] | select(.channel=="ring0") | .members == ["petry-projects/.github"]' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].rings[] | select(.channel=="ring1") | (.members | index("petry-projects/TalkTerm")) and (.members | index("petry-projects/bmad-bgreat-suite"))' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].rings[] | select(.channel=="stable") | .members == ["*"]' "$RINGS" >/dev/null
  done
}

@test "orchestrator: resolve_members for a #482 cross-repo reusable (next=.github-private, ring0=.github, stable=*)" {
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members agent-shield next"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github-private" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members agent-shield ring0"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dependabot-rebase ring1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"petry-projects/TalkTerm"* ]]
  [[ "$output" == *"petry-projects/bmad-bgreat-suite"* ]]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members pr-review-mention stable"
  [ "$status" -eq 0 ]; [ "$output" = "*" ]
}

@test "canary-rings.json: #482 reusables carry the #548 per-transition gate knobs" {
  for a in $_REUSABLES_482; do
    jq -e --arg a "$a" '.agents[$a].gate.baseline_window_days == 14' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.baseline_spike_cap_multiple == 3' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["next->ring0"].dwell_hours == 4' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["next->ring0"].sample_fraction_permille == 250' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["next->ring0"].sample_clamp_min == 3' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["next->ring0"].sample_clamp_max == 15' "$RINGS" >/dev/null
    # waive_sample_if_no_caller covers dependabot-rebase's missing .github-private caller
    # (the "soak starts at ring0" note): a next tier with zero callers waives the fresh sample.
    jq -e --arg a "$a" '.agents[$a].gate.transitions["next->ring0"].waive_sample_if_no_caller == true' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["ring0->ring1"].dwell_hours == 8' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["ring0->ring1"].waive_sample == true' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["ring1->stable"].dwell_hours == 12' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.transitions["ring1->stable"].sample_min == 1' "$RINGS" >/dev/null
    jq -e --arg a "$a" '.agents[$a].gate.control.allow_pre_existing == false' "$RINGS" >/dev/null
  done
}

@test "orchestrator: evaluate-all reports all 7 registered agents (dev-lead + the 6 #482)" {
  _make_stub_bin
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate-all
  [ "$status" -eq 0 ]
  for a in dev-lead $_REUSABLES_482; do
    [[ "$output" == *"agent: $a"* ]]
  done
}
