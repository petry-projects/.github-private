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
