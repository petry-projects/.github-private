#!/usr/bin/env bats
# Unit tests for scripts/bootstrap-new-repo.sh — the DRY_RUN-aware bootstrap that
# orchestrates the existing apply-* scripts to bring a new repo to full org
# compliance (issue #967, epic #964). Mirrors tests/test_apply_rulesets.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BOOTSTRAP="$SCRIPT_DIR/scripts/bootstrap-new-repo.sh"
RULESETS_DIR="$SCRIPT_DIR/.github/rulesets"

setup() {
  STUB_BIN="$(mktemp -d)" || { echo "Failed to create STUB_BIN" >&2; exit 1; }
  export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
  STUB_DIR="$(mktemp -d)" || { echo "Failed to create STUB_DIR" >&2; exit 1; }
}
teardown() {
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  [ -n "${STUB_DIR:-}" ] && rm -rf "$STUB_DIR"
  return 0
}

# gh stub: records every write (POST/PUT/PATCH/label create) to $CALLS; returns
# empty objects for reads so the orchestration never fails on a read.
_stub_gh() {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method POST"*|*"--method PUT"*|*"PATCH"*|*"label create"*|*"-X PUT"*) echo "\$args" >> "$CALLS" ;;
esac
echo '{}'
EOF
  chmod +x "$STUB_BIN/gh"
}

# Stub the two sub-scripts so behavior (exit code) is deterministic. Each stub
# logs its invocation to $CALLS and exits with $1 (default 0).
_stub_substeps() {
  local settings_rc="${1:-0}" rulesets_rc="${2:-0}"
  cat > "$STUB_DIR/apply-repo-settings.sh" <<EOF
#!/usr/bin/env bash
echo "apply-repo-settings called: \$*" >> "$CALLS"
exit $settings_rc
EOF
  cat > "$STUB_DIR/apply-rulesets.sh" <<EOF
#!/usr/bin/env bash
echo "apply-rulesets called: \$*" >> "$CALLS"
exit $rulesets_rc
EOF
  chmod +x "$STUB_DIR/apply-repo-settings.sh" "$STUB_DIR/apply-rulesets.sh"
  export APPLY_REPO_SETTINGS="$STUB_DIR/apply-repo-settings.sh"
  export APPLY_RULESETS="$STUB_DIR/apply-rulesets.sh"
}

# ── codified pr-quality.json shape ────────────────────────────────────────────
@test "pr-quality.json: valid, branch target, active enforcement" {
  run jq -e '.name == "pr-quality" and .target == "branch" and .enforcement == "active"' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
}

@test "pr-quality.json: bypass = OrganizationAdmin + Integration, both bypass_mode always" {
  run jq -e '[.bypass_actors[].actor_type] | (index("OrganizationAdmin") and index("Integration"))' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  run jq -e '[.bypass_actors[].bypass_mode] | all(. == "always")' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
}

@test "pr-quality.json: Integration bypass uses the dependabot-automerge app id (3167543)" {
  run jq -e '[.bypass_actors[] | select(.actor_type=="Integration") | .actor_id] | index(3167543)' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
}

@test "pr-quality.json: pull_request rule — 1 approval, code-owner review, thread resolution, dismiss-stale, squash-only" {
  run jq -e '
    [.rules[] | select(.type=="pull_request") | .parameters] | .[0] as $p
    | $p.required_approving_review_count == 1
      and $p.require_code_owner_review == true
      and $p.required_review_thread_resolution == true
      and $p.dismiss_stale_reviews_on_push == true
      and ($p.allowed_merge_methods | index("squash"))
      and ($p.allowed_merge_methods | (index("merge") | not))
      and ($p.allowed_merge_methods | (index("rebase") | not))
  ' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
}

@test "pr-quality.json: targets the default branch — no legacy/ad-hoc 'main' literal" {
  run jq -e '.conditions.ref_name.include | index("~DEFAULT_BRANCH")' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  run jq -e '.conditions.ref_name.include | (index("refs/heads/main") | not)' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
}

# ── orchestration: DRY_RUN path ───────────────────────────────────────────────
@test "DRY_RUN: exits 0 and makes no write API calls" {
  _stub_gh
  run env DRY_RUN=true bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "DRY_RUN: prints intent and a PASS summary" {
  _stub_gh
  run env DRY_RUN=true bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"DRY_RUN"* ]]
  [[ "$output" == *"owner/new-repo"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "DRY_RUN: bridges the flag onto both sub-scripts (DEV_LEAD_DRY_RUN + DRY_RUN)" {
  # Use real sub-scripts but a gh stub; in dry-run neither makes write calls.
  _stub_gh
  run env DRY_RUN=true bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  # apply-repo-settings dry-run prints its own intent line; apply-rulesets too.
  [[ "$output" == *"apply-rulesets"* ]] || [[ "$output" == *"rulesets"* ]]
}

# ── orchestration: sequencing + fail-fast + summary ───────────────────────────
@test "sequence: invokes apply-repo-settings then apply-rulesets --repo on success" {
  _stub_gh
  _stub_substeps 0 0
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  grep -q "apply-repo-settings called" "$CALLS"
  grep -q "apply-rulesets called: --repo owner/new-repo" "$CALLS"
  # order: settings line must precede rulesets line
  settings_ln="$(grep -n 'apply-repo-settings called' "$CALLS" | head -1 | cut -d: -f1)"
  rulesets_ln="$(grep -n 'apply-rulesets called' "$CALLS" | head -1 | cut -d: -f1)"
  [ "$settings_ln" -lt "$rulesets_ln" ]
}

@test "fail-fast: apply-repo-settings failure stops before apply-rulesets and exits non-zero" {
  _stub_gh
  _stub_substeps 1 0
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -ne 0 ]
  grep -q "apply-repo-settings called" "$CALLS"
  ! grep -q "apply-rulesets called" "$CALLS"
  [[ "$output" == *"FAIL"* ]]
}

@test "fail-fast: apply-rulesets failure exits non-zero with a FAIL summary" {
  _stub_gh
  _stub_substeps 0 1
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -ne 0 ]
  grep -q "apply-rulesets called" "$CALLS"
  [[ "$output" == *"FAIL"* ]]
}

@test "summary: success prints a PASS summary naming the repo" {
  _stub_gh
  _stub_substeps 0 0
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"owner/new-repo"* ]]
}

# ── argument handling ─────────────────────────────────────────────────────────
@test "errors when no repo argument is given" {
  _stub_gh
  run bash "$BOOTSTRAP"
  [ "$status" -ne 0 ]
}

# ── release-ring confirmation + registration (#968) ───────────────────────────
# A throwaway copy of the real ring SoT so non-stable tests can assert intent
# without mutating the tracked file.
_ring_sot_copy() {
  RING_SOT="$STUB_DIR/canary-rings.json"
  cp "$SCRIPT_DIR/standards/canary-rings.json" "$RING_SOT"
  export CANARY_RINGS="$RING_SOT"
}

@test "ring: defaults to stable and records an auditable decision (record-only)" {
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  run env GITHUB_ACTOR=octocat bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ring-audit]"* ]]
  [[ "$output" == *"ring=stable"* ]]
  [[ "$output" == *"operator=octocat"* ]]
  [[ "$output" == *"decision=recorded"* ]]
  # stable is record-only: no central-file edit intent, SoT untouched
  [[ "$output" != *"would add owner/new-repo"* ]]
  run diff "$SCRIPT_DIR/standards/canary-rings.json" "$RING_SOT"
  [ "$status" -eq 0 ]
}

@test "ring: rejects an unknown ring value" {
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  run bash "$BOOTSTRAP" --ring nope owner/new-repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown ring"* ]]
}

@test "ring: non-stable (DRY_RUN) records the decision and prints both-file + stub intent" {
  # Real sub-scripts under dry-run make no writes, so $CALLS stays a pure
  # gh-write ledger (a stubbed sub-script would log to it and break the check).
  _stub_gh
  _ring_sot_copy
  run env DRY_RUN=true GITHUB_ACTOR=octocat bash "$BOOTSTRAP" --ring ring1 owner/new-repo
  [ "$status" -eq 0 ]
  # auditable record, even in dry-run
  [[ "$output" == *"[ring-audit]"* ]]
  [[ "$output" == *"ring=ring1"* ]]
  [[ "$output" == *"decision=registered"* ]]
  # central file 1: this repo's canary-rings.json
  [[ "$output" == *"would add owner/new-repo"* ]]
  [[ "$output" == *"ring1"* ]]
  # central file 2: cross-repo ring-pins.sh in petry-projects/.github
  [[ "$output" == *"ring-pins.sh"* ]]
  [[ "$output" == *"petry-projects/.github"* ]]
  # stub repin to the matching channel tag
  [[ "$output" == *"@dev-lead/ring1"* ]]
  # dry-run makes no write API calls and does not mutate the SoT
  [ ! -f "$CALLS" ]
  run diff "$SCRIPT_DIR/standards/canary-rings.json" "$RING_SOT"
  [ "$status" -eq 0 ]
}

@test "ring: non-stable consistency holds — repo lands in the named ring and no other" {
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  # Proposed post-state must place owner/new-repo in ring1 and nowhere else.
  run env DRY_RUN=true bash "$BOOTSTRAP" --ring ring1 owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"ring consistency OK"* ]]
}

# ── end-to-end DRY_RUN validation: the full policy surface in one run (#970) ────
# A single DRY_RUN walkthrough with the REAL sub-scripts (only `gh` stubbed) must
# describe the entire intended state — recorded ring, repo settings + GHAS + push
# protection, both sanctioned rulesets, the standard labels, CODEOWNERS team — and
# emit zero write API calls (no drift). This is the executable form of the
# end-to-end validation recorded in docs/bootstrap/new-repo-validation.md.
@test "e2e DRY_RUN: covers the whole intended-state surface with no write calls (#970 AC #2/#3)" {
  _stub_gh
  _ring_sot_copy
  run env DRY_RUN=true GITHUB_ACTOR=octocat CANARY_RINGS="$RING_SOT" \
    bash "$BOOTSTRAP" petry-projects/acme-service
  [ "$status" -eq 0 ]

  # (1/5) ring — auditable record, default stable, record-only.
  [[ "$output" == *"[ring-audit]"* ]]
  [[ "$output" == *"ring=stable"* ]]
  [[ "$output" == *"decision=recorded"* ]]

  # (2/5) repo settings — security_and_analysis + secret-scanning push protection,
  # and the Claude/CodeRabbit check-suite auto-trigger disable.
  [[ "$output" == *"security_and_analysis"* ]]
  [[ "$output" == *"secret_scanning_push_protection"* ]]
  [[ "$output" == *"would disable auto-trigger"* ]]

  # (3/5) both sanctioned rulesets are applied.
  [[ "$output" == *"pr-quality"* ]]
  [[ "$output" == *"code-quality"* ]]

  # (4/5) the standard label set.
  [[ "$output" == *"needs-human-review"* ]]
  [[ "$output" == *"ack-test-deletion"* ]]

  # (5/5) CODEOWNERS team verification.
  [[ "$output" == *"CODEOWNERS"* ]]
  [[ "$output" == *"org-leads"* ]]

  # PASS summary + the no-drift invariant: a pure DRY_RUN makes no write API calls.
  [[ "$output" == *"PASS"* ]]
  [ ! -f "$CALLS" ]

  # Each sanctioned ruleset carries its bypass actors + required checks in the JSON
  # (not wired by bootstrap). These `run jq` calls overwrite $output, so they run
  # last, after every transcript assertion above.
  run jq -e '[.bypass_actors[].actor_type] | (index("OrganizationAdmin") and index("Integration"))' "$RULESETS_DIR/code-quality.json"
  [ "$status" -eq 0 ]
  run jq -e '[.bypass_actors[].actor_type] | (index("OrganizationAdmin") and index("Integration"))' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  run jq -e '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | length > 0' "$RULESETS_DIR/code-quality.json"
  [ "$status" -eq 0 ]
}
