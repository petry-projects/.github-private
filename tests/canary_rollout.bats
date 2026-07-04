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

# ── version-bump math (autocut front end, #1069) ──────────────────────────────
@test "bump_version: patch increments the patch component" {
  [ "$(bump_version 2.1.0 patch)" = "2.1.1" ]
  [ "$(bump_version 0.0.0 patch)" = "0.0.1" ]
}
@test "bump_version: minor increments minor and zeroes patch" {
  [ "$(bump_version 2.1.3 minor)" = "2.2.0" ]
}
@test "bump_version: major increments major and zeroes minor+patch" {
  [ "$(bump_version 2.1.3 major)" = "3.0.0" ]
}
@test "bump_version: default (no/unknown level) is patch" {
  [ "$(bump_version 2.1.0)" = "2.1.1" ]
  [ "$(bump_version 2.1.0 bogus)" = "2.1.1" ]
}

@test "_semver_gt: compares by major, then minor, then patch" {
  run _semver_gt 2.1.1 2.1.0; [ "$status" -eq 0 ]
  run _semver_gt 2.2.0 2.1.9; [ "$status" -eq 0 ]
  run _semver_gt 3.0.0 2.9.9; [ "$status" -eq 0 ]
  run _semver_gt 2.1.0 2.1.0; [ "$status" -ne 0 ]   # equal is not greater
  run _semver_gt 2.1.0 2.1.1; [ "$status" -ne 0 ]
}

@test "max_semver: picks the highest version" {
  [ "$(max_semver 2.0.5 2.1.0 2.0.9)" = "2.1.0" ]
  [ "$(max_semver 1.0.0)" = "1.0.0" ]
}
@test "max_semver: ignores non-semver tokens" {
  [ "$(max_semver 2.1.0 not-a-version 2.1.5 v3.0.0)" = "2.1.5" ]
}
@test "max_semver: empty input → empty" {
  [ -z "$(max_semver)" ]
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
  # dev-lead is a this-repo agent, but the move now goes through gh api on its host — the
  # dry-run must show the API PATCH, never a local `git tag -f`/`git push` (#1076).
  [[ "$output" == *"gh api PATCH"* ]]
  [[ "$output" != *"git tag -f"* ]]
}

@test "orchestrator: no local git tag/push in the promote/rollback move paths — gh api only (#1076)" {
  # Structural guard: the channel-tag move for EVERY agent (this-repo and cross-repo) goes
  # through gh api so the release-manager App's ruleset bypass is applied; a local force-push
  # is not a bypass actor for a tag UPDATE and 013s on protected tags such as dev-lead/next.
  ! grep -Ev '^[[:space:]]*#' "$ORCH" | grep -Eq '\bgit[[:space:]]+(tag|push)\b'
}

# ── orchestrator: full graduated verdicts (cut date + gh run data → gate state) ─
# Lay out next = candidate (cccc); ring0/ring1/stable = prior (bbbb): frontier = ring0,
# transition next->ring0, source = next. The release tag cccc is dated `cut_days` ago,
# so the per-candidate window (and the robust sample target) are exercised end to end.
_graduated_stub() {
  local cut_days="$1" run_days_ago="$2" conclusion="$3" reusable_diff="$4"
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
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
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
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

# ── orchestrator: cross-repo agents resolve tags on `host`, not the local checkout ─
# (#1049) A cross-repo agent (host = petry-projects/.github) keeps its <name>/<channel>
# and <name>/vX.Y.Z tags on the HOST repo, not this checkout. `evaluate` must resolve them
# there via `gh api` (dereferencing annotated tags) — reading the LOCAL refs makes every
# ring resolve empty → "all rings equal → fully rolled out", which would falsely SKIP a
# cross-repo agent that is actually ring1 with stable on an old baseline (READY to promote).
_crossrepo_stub() {
  # next=ring0=ring1 on the candidate (cccc); stable on the OLD baseline (bbbb):
  # frontier = ring1, transition = ring1->stable — the ring1->stable promotion is pending.
  local cut_days="$1" run_days_ago="$2" conclusion="$3"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cand="cccccccccccccccccccccccccccccccccccccccc"
  local old="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  # gh: channel tags + the release tag are resolved via the API on the HOST repo; run-list
  # feeds the sample/health. Channel/release tag responses are pre-computed strings; the
  # run-list branch invokes jq to generate timestamped records from the injected parameters.
  # The channel tags are lightweight (object.type=commit); the release tag is annotated
  # (object.type=tag), so its commit + tagger date come from a second git/tags/<obj> call.
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/auto-rebase/next"*)   echo "$cand commit" ;;
  *"git/ref/tags/auto-rebase/ring0"*)  echo "$cand commit" ;;
  *"git/ref/tags/auto-rebase/ring1"*)  echo "$cand commit" ;;
  *"git/ref/tags/auto-rebase/stable"*) echo "$old commit" ;;
  *"matching-refs/tags/auto-rebase/v"*) printf 'refs/tags/auto-rebase/v1.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "$cand" "$cut_iso" ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # git: a cross-repo agent has NO local refs — every git call resolves empty. If the code
  # regressed to the local path, channel_commit would be empty for every ring → the frontier
  # would collapse to "fully rolled out" and this test would fail (that is exactly #1049).
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # no local refs for a cross-repo agent
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: cross-repo agent resolves channel+release tags on host → ring1->stable pending, NOT 'fully rolled out' (#1049)" {
  # cut 2 days ago (dwell ≫ 12h), ring1 runs 1 day ago all success → sample ≥ 1, clean.
  _crossrepo_stub 2 1 success
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate auto-rebase
  [ "$status" -eq 0 ]
  [[ "$output" != *"fully rolled out"* ]]
  [[ "$output" == *"ring1->stable"* ]]
  [[ "$output" == *"PROMOTE"* ]]
}

# ── orchestrator: promote-all — the gated fleet auto-promote (the SCHEDULED arm, #1045b) ─
@test "orchestrator: promote-all iterates every registry agent and forwards to promote (dry-run, no push)" {
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
  # Reuse the dev-lead git stub but log any push so we can assert the sweep never mutates.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*) : ;;
  *"push"*) echo "\$*" >> "$pushlog" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"

  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote-all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"promote-all: fleet-wide"* ]]
  # Every registry agent gets its own section (the loop covers the whole fleet, not dev-lead only).
  [[ "$output" == *"agent: dev-lead"* ]]
  [[ "$output" == *"agent: auto-rebase"* ]]
  [[ "$output" == *"agent: pr-review-mention"* ]]
  # A real move is never pushed under --dry-run.
  [ ! -f "$pushlog" ]
}

# ── orchestrator: cross-repo promote MOVES the channel tag on the HOST via gh api (#1054) ─
# A cross-repo agent (host = petry-projects/.github) keeps its channel tags on the host, so
# the promote move must go through `gh api PATCH .../git/refs/tags/...`, NOT local `git tag -f`
# (which fails "nonexistent object" for a host commit absent from this checkout — #1054).
@test "orchestrator: cross-repo promote --dry-run shows the host gh-api move, not a local git tag (#1054)" {
  _crossrepo_stub 2 1 success   # auto-rebase ring1->stable PROMOTE
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote auto-rebase --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"gh api PATCH repos/petry-projects/.github/git/refs/tags/auto-rebase/stable"* ]]
  [[ "$output" != *"git tag -f"* ]]
}

_crossrepo_promote_stub() {
  # Like _crossrepo_stub but the gh stub LOGS any ref mutation (PATCH/POST) to $MOVE_LOG so
  # a REAL promote can be asserted to move the tag on the host (never touching local git).
  local cut_days="$1" run_days_ago="$2" conclusion="$3"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export MOVE_LOG="$STUB_BIN/move.log"
  local cand="cccccccccccccccccccccccccccccccccccccccc"
  local old="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"-X PATCH"*"git/refs/tags/"*) echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"-X POST"*"git/refs"*)        echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"git/ref/tags/auto-rebase/next"*)   echo "$cand commit" ;;
  *"git/ref/tags/auto-rebase/ring0"*)  echo "$cand commit" ;;
  *"git/ref/tags/auto-rebase/ring1"*)  echo "$cand commit" ;;
  *"git/ref/tags/auto-rebase/stable"*) echo "$old commit" ;;
  *"matching-refs/tags/auto-rebase/v"*) printf 'refs/tags/auto-rebase/v1.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "$cand" "$cut_iso" ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # A cross-repo agent has NO local refs; if the code regressed to `git tag -f`, this stub
  # would record the attempt (and the move.log would stay empty) — the test would fail.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"tag -f"*|*"push"*) echo "LOCAL:\$*" >> "$MOVE_LOG" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: cross-repo promote (real) moves the host channel tag via gh api + records the output (#1054)" {
  _crossrepo_promote_stub 2 1 success   # auto-rebase ring1->stable PROMOTE
  local out="$BATS_TEST_TMPDIR/gh_output"; : > "$out"
  local plog="$BATS_TEST_TMPDIR/promotions.tsv"; : > "$plog"
  run env CANARY_RINGS="$RINGS" GITHUB_OUTPUT="$out" CANARY_PROMOTIONS_LOG="$plog" bash "$ORCH" promote auto-rebase
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted auto-rebase/stable"* ]]
  # The move went through gh api PATCH on the HOST, never local git tag/push.
  grep -q "PATCH repos/petry-projects/.github/git/refs/tags/auto-rebase/stable" "$MOVE_LOG"
  ! grep -q "^LOCAL:" "$MOVE_LOG"
  # The move is exposed for the workflow's GitHub Deployment step (#502).
  grep -q "promoted_agent=auto-rebase" "$out"
  grep -q "promoted_ring=stable" "$out"
  # promoted_host is the OWNING repo (the cross-repo host), so the deployment is created
  # where the moved commit exists — not GITHUB_REPOSITORY, which would 422 "No ref found" (#1059).
  grep -q "promoted_host=petry-projects/.github" "$out"
  # The promotions log gets one TSV line per move (agent, ring, sha, owning-repo) so a
  # promote-all run can record a deployment for EVERY promotion, not just the last.
  grep -qP "^auto-rebase\tstable\t[0-9a-f]+\tpetry-projects/\.github$" "$plog"
}

@test "orchestrator: cross-repo promote --dry-run shows the host move but touches neither git nor the API (#1054)" {
  _crossrepo_promote_stub 2 1 success
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote auto-rebase --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"auto-rebase/stable"* ]]
  [[ "$output" == *"petry-projects/.github"* ]]
  [ ! -f "$MOVE_LOG" ]
}

# ── orchestrator: sync-issues — auto-triage held promotions into tracked issues ──
# A held (BLOCKED) promotion files/updates ONE idempotent issue per agent with the failing-run
# evidence; a cleared agent's issue auto-closes; the fleet-status table is rendered to the job
# summary. dev-lead-only registry keeps the fleet loop to one agent; the gh stub logs issue ops.
_sync_stub() {
  # $1 conclusion (failure→BLOCKED | success→cleared); $2 blocker-list JSON returned by `gh issue list`
  local concl="$1" blocker_list="${2:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  local cut_iso run_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*) echo "cccccccccccccccccccccccccccccccccccccccc||$cut_iso" ;;
  *"rev-parse"*"cccc"*":"*) echo "blobAAAA" ;;
  *"rev-parse"*"bbbb"*":"*) echo "blobAAAA" ;;
  *"rev-parse"*"dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *"rev-parse"*"dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*"dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*"dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *"rev-parse"*) echo "cccccccccccccccccccccccccccccccccccccccc" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$concl" '[range(3)|{conclusion:\$c,createdAt:\$d,databaseId:12345,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Some step","conclusion":"failure"}]}]}' ;;
  "issue list"*) echo '$blocker_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/777" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "issue pin"*)    echo "PIN|\$*"    >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  SYNC_RINGS="$BATS_TEST_TMPDIR/sync-rings.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$SYNC_RINGS"
}

@test "orchestrator: sync-issues --dry-run plans the blocker + renders status, no GitHub writes" {
  _sync_stub failure '[]'   # BLOCKED, nothing filed yet
  # Pin GITHUB_STEP_SUMMARY to a temp file — under CI the runner sets it, so the table lands
  # in the summary, not stdout; asserting the file keeps the test env-independent.
  local summ="$BATS_TEST_TMPDIR/summary.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would OPEN blocker issue for dev-lead"* ]]
  grep -q "Canary Rollout — fleet status" "$summ"   # table still renders under --dry-run
  [ ! -s "$ISSUE_LOG" ]   # dry-run mutates nothing on GitHub
}

@test "orchestrator: sync-issues opens ONE blocker issue (with evidence) + writes the fleet summary — no dashboard issue" {
  _sync_stub failure '[]'
  local summ="$BATS_TEST_TMPDIR/summary.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened blocker issue #777 for dev-lead"* ]]
  [[ "$output" == *"wrote fleet-status table to the job summary"* ]]
  # Exactly ONE issue create (the blocker) — the dashboard is NOT an issue anymore.
  [ "$(grep -c '^CREATE|' "$ISSUE_LOG" || true)" -eq 1 ]
  grep -q -- "--label canary-blocker" "$ISSUE_LOG"
  ! grep -q -- "--label canary-dashboard" "$ISSUE_LOG"
  ! grep -q "^PIN|" "$ISSUE_LOG"
  # The fleet-status table landed in the job summary file.
  grep -q "Canary Rollout — fleet status" "$summ"
  grep -q "dev-lead" "$summ"
}

@test "orchestrator: sync-issues survives a failing 'gh issue create' — no abort under set -e, still renders the fleet summary (#1081)" {
  # Regression: the blocker-issue create failing (App lacks Issues:write, rate-limit, …)
  # must NOT abort the whole step before the dashboard renders. Make `gh issue create` exit
  # non-zero and assert graceful degradation: warning logged, table still written, status 0.
  _sync_stub failure '[]'
  sed 's#"issue create"\*).*#"issue create"*) echo "gh: HTTP 403 (Issues:write?)" >\&2; exit 1 ;;#' "$STUB_BIN/gh" > "$STUB_BIN/gh.tmp" && mv "$STUB_BIN/gh.tmp" "$STUB_BIN/gh" && chmod +x "$STUB_BIN/gh"
  local summ="$BATS_TEST_TMPDIR/summary_fail.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not open blocker issue for dev-lead (Issues:write on the App?)"* ]]
  [[ "$output" == *"wrote fleet-status table to the job summary"* ]]
  grep -q "Canary Rollout — fleet status" "$summ"
  grep -q "dev-lead" "$summ"
}

@test "orchestrator: sync-issues auto-closes a cleared agent's open blocker issue" {
  # dev-lead now clean (success → not BLOCKED) but an OPEN blocker issue #501 exists → close it.
  _sync_stub success '[{"number":501,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"}]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed cleared blocker issue #501 for dev-lead"* ]]
  grep -q "CLOSE|.*501" "$ISSUE_LOG"
}

@test "orchestrator: sync-issues prepends a separator newline so the fleet-status header is never concatenated to prior summary content" {
  # If prior summary content lacks a trailing newline, the fleet-status header must still
  # start on its own line — not be appended directly to the prior content.
  _sync_stub success '[]'
  local summ="$BATS_TEST_TMPDIR/summary_sep.md"
  printf 'prior step output (no trailing newline)' > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  # The header must appear at the start of a line — not concatenated onto the prior content.
  grep -q '^# Canary Rollout' "$summ"
  ! grep -q 'prior.*# Canary Rollout' "$summ"
}

# ── orchestrator: autocut — auto-cut a new candidate when a reusable changes on main (#1069) ─
# The front end of the canary pipeline: at each scheduled tick (gated by CANARY_AUTO_CUT), for
# each registered agent compare the reusable blob at the host's main HEAD against the blob at the
# current `next` candidate; if they differ, cut a new immutable vX.Y.Z (patch bump default) and
# move `next` onto it via cut-release.sh. The stub feeds: default_branch, main HEAD, the two blob
# SHAs, the `next` commit (git for a this-repo agent, gh api for a cross-repo one), the existing
# release-tag versions (matching-refs), and a cut-release.sh stand-in (CUT_RELEASE) that logs args.
_autocut_stub() {
  # args: agent host reusable main_blob next_blob mainsha nextsha versions_ws [bump]
  local agent="$1" host="$2" reusable="$3" MAIN_BLOB="$4" NEXT_BLOB="$5" MAINSHA="$6" NEXTSHA="$7" versions="$8" bump="${9:-}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export CUT_LOG="$STUB_BIN/cut.log"; : > "$CUT_LOG"
  export CUT_RELEASE="$STUB_BIN/cut-release"
  cat > "$CUT_RELEASE" <<CUTEOF
#!/usr/bin/env bash
echo "\$*" >> "$CUT_LOG"
CUTEOF
  chmod +x "$CUT_RELEASE"
  local refs="" v
  for v in $versions; do refs+="refs/tags/$agent/v$v"$'\n'; done
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *".default_branch"*) echo "main" ;;
  *"contents/"*"ref=$MAINSHA"*) echo "$MAIN_BLOB" ;;
  *"contents/"*"ref=$NEXTSHA"*) echo "$NEXT_BLOB" ;;
  *"/commits/"*) echo "$MAINSHA" ;;
  *"matching-refs/tags/$agent/v"*) printf '%s' "$refs" ;;
  *"git/ref/tags/$agent/next"*) printf '%s\tcommit\n' "$NEXTSHA" ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse"*"$agent/next"*) echo "$NEXTSHA" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  AUTOCUT_RINGS="$BATS_TEST_TMPDIR/autocut-rings.json"
  if [ -n "$bump" ]; then
    jq --arg a "$agent" --arg b "$bump" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): (.agents[$a] + {autocut: {bump: $b}})}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  else
    jq --arg a "$agent" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): .agents[$a]}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  fi
}

@test "orchestrator: autocut is a no-op when CANARY_AUTO_CUT is not 'true' (kill-switch off)" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_RINGS="$AUTOCUT_RINGS" CUT_RELEASE="$CUT_RELEASE" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISABLED"* ]]
  [ ! -s "$CUT_LOG" ]   # nothing cut when the kill-switch is off
}

@test "orchestrator: autocut cuts a patch-bumped version + moves next when the reusable blob differs on main" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" CUT_RELEASE="$CUT_RELEASE" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # Highest existing tag is v2.1.0 → patch bump → v2.1.1, cut from main HEAD, channel next, pushed.
  grep -q "dev-lead 2.1.1 --ref aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --channel next --push" "$CUT_LOG"
}

@test "orchestrator: autocut is idempotent — identical blob on main and next is a clean no-op" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    sameBLOB sameBLOB aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" CUT_RELEASE="$CUT_RELEASE" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cut"* ]]
  [ ! -s "$CUT_LOG" ]   # nothing cut when the blob is unchanged
}

@test "orchestrator: autocut --dry-run prints the intended cut without invoking cut-release --push" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" CUT_RELEASE="$CUT_RELEASE" bash "$ORCH" autocut --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"2.1.1"* ]]
  [ ! -s "$CUT_LOG" ]   # dry-run never pushes a real cut
}

@test "orchestrator: autocut honors the registry autocut.bump override (minor)" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" minor
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" CUT_RELEASE="$CUT_RELEASE" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # minor bump of v2.1.0 → v2.2.0
  grep -q "dev-lead 2.2.0 --ref aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --channel next --push" "$CUT_LOG"
}

@test "orchestrator: autocut is cross-repo aware — cuts v2.1.1 for auto-rebase from the host main HEAD (#1069)" {
  # auto-rebase is hosted in petry-projects/.github; its next candidate + release tags live there,
  # so the next commit is resolved via gh api (not local git) and the cut is cross-repo.
  _autocut_stub auto-rebase petry-projects/.github .github/workflows/auto-rebase-reusable.yml \
    ece45480ece45480ece45480ece45480ece45480 2763750027637500276375002763750027637500 \
    ece45480ece45480ece45480ece45480ece45480 2763750027637500276375002763750027637500 "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" CUT_RELEASE="$CUT_RELEASE" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "auto-rebase 2.1.1 --ref ece45480ece45480ece45480ece45480ece45480 --channel next --push" "$CUT_LOG"
}

# ── set_difference (pure set-diff core for drift detection, #1082) ─────────────
# args: <set_a_newlines> <set_b_newlines> — echo lines in A that are NOT in B.
@test "set_difference: A minus B keeps only A-only elements" {
  run set_difference "$(printf 'a\nb\nc\n')" "$(printf 'b\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a\nc')" ]
}
@test "set_difference: no overlap returns all of A" {
  run set_difference "$(printf 'x\ny\n')" "$(printf 'p\nq\n')"
  [ "$output" = "$(printf 'x\ny')" ]
}
@test "set_difference: full overlap returns nothing" {
  run set_difference "$(printf 'a\nb\n')" "$(printf 'a\nb\n')"
  [ -z "$output" ]
}
@test "set_difference: empty A returns nothing" {
  run set_difference "" "$(printf 'a\n')"
  [ -z "$output" ]
}
@test "set_difference: empty B returns all of A (nothing removed)" {
  run set_difference "$(printf 'a\nb\n')" ""
  [ "$output" = "$(printf 'a\nb')" ]
}
@test "set_difference: matches whole lines only (a path is not a prefix match)" {
  # '.github/workflows/foo-reusable.yml' must not be swallowed by a partial 'foo'.
  run set_difference "$(printf '.github/workflows/foo-reusable.yml\n')" "$(printf 'foo\n')"
  [ "$output" = ".github/workflows/foo-reusable.yml" ]
}

# ── orchestrator: drift — registry vs host reusables (read-only audit, #1082) ──
# The registry (.agents{}) is the MANUAL source of truth for what the canary pipeline
# manages. `drift` scans each registered host repo's .github/workflows/*-reusable.yml
# and diffs it against the registry so an unregistered reusable (zero staged rollout) OR
# a registry entry pointing at a deleted reusable surfaces within one scheduled cycle.
#
# The stub answers `gh api repos/<host>/contents/.github/workflows` with a per-host JSON
# array (env HOSTPRIV_JSON / HOSTPUB_JSON); the orchestrator filters *-reusable.yml itself.
_drift_stub() {
  # $1 = JSON array for petry-projects/.github-private ; $2 = JSON array for petry-projects/.github
  local priv_json="$1" pub_json="${2:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  # '.github' is a substring of '.github-private', so match the more specific repo FIRST.
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"repos/petry-projects/.github-private/contents/.github/workflows"*) cat <<'JSON'
$priv_json
JSON
    ;;
  *"repos/petry-projects/.github/contents/.github/workflows"*) cat <<'JSON'
$pub_json
JSON
    ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # drift never touches git
GITEOF
  chmod +x "$STUB_BIN/git"
}

# A registry with a single this-repo agent (dev-lead) so the present/registered sets are
# fully controlled: registered on .github-private = {dev-lead-reusable.yml}, none on .github.
_drift_rings_one_agent() {
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-rings.json"
  jq '{version, description, org_infra_repos, member_tokens, agents: {"dev-lead": .agents["dev-lead"]}}' \
    "$RINGS" > "$DRIFT_RINGS"
}

@test "orchestrator: drift flags a reusable present on a host but absent from the registry (unregistered)" {
  _drift_rings_one_agent
  # .github-private hosts an EXTRA foo-reusable.yml that no .agents{} block registers.
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"},
    {"type":"file","name":"foo-reusable.yml","path":".github/workflows/foo-reusable.yml"},
    {"type":"file","name":"ci.yml","path":".github/workflows/ci.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[unregistered]"* ]]
  [[ "$output" == *".github/workflows/foo-reusable.yml"* ]]
  # the registered reusable and the non-reusable ci.yml are NOT flagged
  [[ "$output" != *"DRIFT[unregistered] petry-projects/.github-private: .github/workflows/dev-lead-reusable.yml"* ]]
  [[ "$output" != *"ci.yml present on host"* ]]
}

@test "orchestrator: drift flags a registry entry whose reusable file no longer exists on the host (missing-file)" {
  # Registry has 'ghost' pointing at a reusable that is NOT present on the host.
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-ghost.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"ghost": (.agents["dev-lead"] + {reusable: ".github/workflows/ghost-reusable.yml"})}}' \
    "$RINGS" > "$DRIFT_RINGS"
  # Host lists only an unrelated (registered-elsewhere-none) file — ghost-reusable.yml is gone.
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[missing-file]"* ]]
  [[ "$output" == *"ghost"* ]]
  [[ "$output" == *".github/workflows/ghost-reusable.yml"* ]]
}

@test "orchestrator: drift reports NO drift when the registry and host reusables are in sync" {
  _drift_rings_one_agent
  # Host lists exactly the one registered reusable — nothing extra, nothing missing.
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFT["* ]]
  [[ "$output" == *"no reusable drift"* ]]
  [[ "$output" == *"0 unregistered, 0 missing-file"* ]]
}

@test "orchestrator: drift --emit-stub prints a scaffold .agents[<name>] block for an unregistered reusable" {
  _drift_rings_one_agent
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"},
    {"type":"file","name":"foo-reusable.yml","path":".github/workflows/foo-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift --emit-stub
  [ "$status" -eq 0 ]
  # A scaffold JSON object keyed by the derived agent name 'foo' the maintainer can fill in.
  [[ "$output" == *"\"foo\""* ]]
  [[ "$output" == *"\"reusable\": \".github/workflows/foo-reusable.yml\""* ]]
  [[ "$output" == *"petry-projects/.github-private"* ]]
}

@test "orchestrator: drift skips a host it cannot enumerate — no false missing-file avalanche" {
  # Registry has 'ghost' on .github-private, but the contents API returns a non-array error
  # body (no access / API error). The host must be SKIPPED, NOT reported as every registered
  # reusable having been deleted.
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-noaccess.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"ghost": (.agents["dev-lead"] + {reusable: ".github/workflows/ghost-reusable.yml"})}}' \
    "$RINGS" > "$DRIFT_RINGS"
  _drift_stub '{"message":"Not Found"}' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not enumerate"* ]]
  [[ "$output" != *"DRIFT[missing-file]"* ]]
  [[ "$output" == *"0 unregistered, 0 missing-file"* ]]
}

@test "orchestrator: drift renders a fleet-drift table into the job summary when GITHUB_STEP_SUMMARY is set" {
  _drift_rings_one_agent
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"},
    {"type":"file","name":"foo-reusable.yml","path":".github/workflows/foo-reusable.yml"}
  ]' '[]'
  local summ="$BATS_TEST_TMPDIR/drift-summary.md"; : > "$summ"
  run env CANARY_RINGS="$DRIFT_RINGS" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  grep -q "Canary Rollout — reusable drift" "$summ"
  grep -q "foo-reusable.yml" "$summ"
}
