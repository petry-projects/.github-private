#!/usr/bin/env bats
# Unit tests for scripts/lib/hold-label.sh (#2142)
#
# dev-lead's escalations used `gh pr edit --add-label needs-human-review
# 2>/dev/null`, which fails in production (token scopes) with the error thrown
# away, so a flagged PR was not held. The helper applies the label through the
# REST issues-labels endpoint, logs the API's message on failure, and makes a
# failed hold fail the run.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/hold-label.sh"

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  export PATH="$STUB_BIN_DIR:$PATH"
  export GH_CALLS="$(mktemp)"
  export LABEL_RC=0 MERGE_RC=0
  # gh stub: LABEL_RC / MERGE_RC are read at call time so each test can make the
  # label POST or the auto-merge disable fail with a realistic API message.
  cat > "$STUB_BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
case "$*" in
  *"issues/"*"/labels"*)
    if [ "${LABEL_RC:-0}" -ne 0 ]; then
      echo '{"message":"Resource not accessible by integration","status":"403"}'
      echo "gh: Resource not accessible by integration (HTTP 403)" >&2
      exit "$LABEL_RC"
    fi
    echo '[{"name":"needs-human-review"}]' ;;
  *"pr comment"*) echo "PR_COMMENT: $*" ;;
  *"pr merge"*)
    if [ "${MERGE_RC:-0}" -ne 0 ]; then
      echo "GraphQL: Resource not accessible by integration (disablePullRequestAutoMerge)" >&2
      exit "$MERGE_RC"
    fi ;;
  *) echo "{}" ;;
esac
EOF
  chmod +x "$STUB_BIN_DIR/gh"
}

teardown() { rm -rf "$STUB_BIN_DIR" "$GH_CALLS"; }

# ── apply_hold_label ──────────────────────────────────────────────────────────

@test "apply_hold_label: POSTs the label to the REST issues-labels endpoint" {
  source "$LIB"
  run apply_hold_label owner/repo 77
  [ "$status" -eq 0 ]
  grep -q "api -X POST repos/owner/repo/issues/77/labels" "$GH_CALLS"
  grep -q "labels\[\]=needs-human-review" "$GH_CALLS"
  # Never the gh pr edit path that lacks token scopes.
  ! grep -q "pr edit" "$GH_CALLS"
}

@test "apply_hold_label: success leaves no failure state and no not-held note" {
  source "$LIB"
  apply_hold_label owner/repo 77
  [ "${HOLD_LABEL_FAILED:-0}" -eq 0 ]
  [ -z "$HOLD_LABEL_NOTE" ]
}

@test "apply_hold_label: honours an explicit label and NEEDS_HUMAN_REVIEW_LABEL" {
  source "$LIB"
  apply_hold_label owner/repo 77 dev-lead:needs-human
  grep -q "labels\[\]=dev-lead:needs-human" "$GH_CALLS"
  NEEDS_HUMAN_REVIEW_LABEL=custom-hold apply_hold_label owner/repo 78
  grep -q "labels\[\]=custom-hold" "$GH_CALLS"
}

@test "apply_hold_label: API refusal returns non-zero and logs the API message" {
  source "$LIB"
  LABEL_RC=1
  run apply_hold_label owner/repo 77
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"Resource not accessible by integration"* ]]
  [[ "$output" == *"#77"* ]]
}

@test "apply_hold_label: API refusal sets the failure flag and a not-held note" {
  source "$LIB"
  LABEL_RC=1
  apply_hold_label owner/repo 77 2>/dev/null >/dev/null || true
  [ "$HOLD_LABEL_FAILED" -eq 1 ]
  [[ "$HOLD_LABEL_NOTE" == *"could not be held"* ]]
  [[ "$HOLD_LABEL_NOTE" == *"needs-human-review"* ]]
  [[ "$HOLD_LABEL_NOTE" == *"Resource not accessible by integration"* ]]
}

@test "apply_hold_label: a later success does not clear an earlier failure" {
  source "$LIB"
  LABEL_RC=1
  apply_hold_label owner/repo 77 >/dev/null 2>&1 || true
  LABEL_RC=0
  apply_hold_label owner/repo 77
  [ "$HOLD_LABEL_FAILED" -eq 1 ]
  [ -z "$HOLD_LABEL_NOTE" ]
}

# ── post_hold_failure_note ────────────────────────────────────────────────────

@test "post_hold_failure_note: posts nothing when the hold succeeded" {
  source "$LIB"
  apply_hold_label owner/repo 77
  run post_hold_failure_note owner/repo 77
  [ "$status" -eq 0 ]
  ! grep -q "pr comment" "$GH_CALLS"
}

@test "post_hold_failure_note: posts the not-held note when the hold failed" {
  source "$LIB"
  LABEL_RC=1
  apply_hold_label owner/repo 77 >/dev/null 2>&1 || true
  run post_hold_failure_note owner/repo 77
  grep -q "pr comment 77 --repo owner/repo" "$GH_CALLS"
  grep -q "could not be held" "$GH_CALLS"
}

# ── disable_auto_merge_for_hold ───────────────────────────────────────────────

@test "disable_auto_merge_for_hold: disables auto-merge" {
  source "$LIB"
  run disable_auto_merge_for_hold owner/repo 77
  [ "$status" -eq 0 ]
  grep -q -- "pr merge 77 --repo owner/repo --disable-auto" "$GH_CALLS"
}

@test "disable_auto_merge_for_hold: a failure logs gh's message instead of discarding it" {
  source "$LIB"
  MERGE_RC=1
  run disable_auto_merge_for_hold owner/repo 77
  [ "$status" -eq 0 ]
  [[ "$output" == *"#77"* ]]
  [[ "$output" == *"disablePullRequestAutoMerge"* ]]
}

# ── hold_label_exit_guard ─────────────────────────────────────────────────────

@test "hold_label_exit_guard: a successful run with a successful hold exits 0" {
  run bash -c "source '$LIB'; trap hold_label_exit_guard EXIT; apply_hold_label owner/repo 77; exit 0"
  [ "$status" -eq 0 ]
}

@test "hold_label_exit_guard: a failed hold turns a successful run into a failure" {
  run bash -c "source '$LIB'; trap hold_label_exit_guard EXIT; apply_hold_label owner/repo 77 || true; exit 0"
  [ "$status" -eq 0 ]
  LABEL_RC=1 run bash -c "source '$LIB'; trap hold_label_exit_guard EXIT; apply_hold_label owner/repo 77 || true; exit 0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not be held"* ]]
}

@test "hold_label_exit_guard: keeps an existing non-zero exit code" {
  LABEL_RC=1 run bash -c "source '$LIB'; trap hold_label_exit_guard EXIT; apply_hold_label owner/repo 77 || true; exit 4"
  [ "$status" -eq 4 ]
}

@test "hold_label_exit_guard: works chained after another EXIT handler" {
  LABEL_RC=1 run bash -c "source '$LIB'; other() { true; }; trap 'rc=\$?; other; hold_label_exit_guard \"\$rc\"' EXIT; apply_hold_label owner/repo 77 || true; exit 0"
  [ "$status" -ne 0 ]
}

@test "hold_label_exit_guard: no-argument fallback still fails a run with a failed hold" {
  LABEL_RC=1 run bash -c "source '$LIB'; other() { true; }; trap 'other; hold_label_exit_guard' EXIT; apply_hold_label owner/repo 77 || true; exit 0"
  [ "$status" -ne 0 ]
}

# ── review follow-ups (#2142) ─────────────────────────────────────────────────

@test "add_label_rest: POSTs any label to the REST labels endpoint without touching hold state" {
  source "$LIB"
  run add_label_rest owner/repo 5 auto-rebase:ready
  [ "$status" -eq 0 ]
  grep -q "gh api -X POST repos/owner/repo/issues/5/labels -f labels\[\]=auto-rebase:ready" "$GH_CALLS"
  LABEL_RC=1 add_label_rest owner/repo 5 auto-rebase:ready 2>/dev/null >/dev/null || true
  [ "${HOLD_LABEL_FAILED:-0}" = "0" ]
}

@test "hold_label_exit_guard: chained with a captured status keeps the original exit code" {
  LABEL_RC=1 run bash -c "source '$LIB'; other() { true; }; trap 'rc=\$?; other; hold_label_exit_guard \"\$rc\"' EXIT; apply_hold_label owner/repo 77 || true; exit 4"
  [ "$status" -eq 4 ]
}

@test "disable_auto_merge_for_hold: a refused disable on an active auto-merge fails the hold" {
  source "$LIB"
  cat > "$STUB_BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr merge"*) echo "refused" >&2; exit 1 ;;
  *"pr view"*) echo true ;;
esac
EOF
  rc=0
  disable_auto_merge_for_hold owner/repo 77 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
  [ "$HOLD_LABEL_FAILED" = "1" ]
}

@test "hold_label_exit_guard: a failure recorded in a subshell reaches the guard via HOLD_LABEL_FAILED_FILE" {
  f="$BATS_TEST_TMPDIR/failed"
  HOLD_LABEL_FAILED_FILE="$f" LABEL_RC=1 run bash -c "source '$LIB'; x=\$(apply_hold_label owner/repo 77 2>/dev/null || true); trap 'rc=\$?; hold_label_exit_guard \"\$rc\"' EXIT; exit 0"
  [ "$status" -ne 0 ]
}

# ── dev-lead-retry.sh marker directory (#2142 review) ─────────────────────────

_run_retry_with_marker_probe() {
  # gh stub records the marker's parent dir + mode; optionally simulates a failed hold.
  cat > "$STUB_BIN_DIR/gh" <<'EOF2'
#!/usr/bin/env bash
if [ -n "${HOLD_LABEL_FAILED_FILE:-}" ]; then
  d="$(dirname "$HOLD_LABEL_FAILED_FILE")"
  echo "$d" > "$PROBE_OUT.dir"
  stat -c '%a' "$d" > "$PROBE_OUT.mode"
  [ "${SIMULATE_FAILED_HOLD:-0}" != "1" ] || : > "$HOLD_LABEL_FAILED_FILE"
fi
case "$*" in
  *"repo list"*) echo '[]' ;;
esac
exit 0
EOF2
  chmod +x "$STUB_BIN_DIR/gh"
  export PROBE_OUT="$BATS_TEST_TMPDIR/probe"
  DRY_RUN=true TARGET_ORG=acme DELEGATION_ORGS="" run bash "$SCRIPT_DIR/scripts/dev-lead-retry.sh"
}

@test "dev-lead-retry.sh: the failure marker lives in a private mode-700 directory removed on a clean exit" {
  SIMULATE_FAILED_HOLD=0 _run_retry_with_marker_probe
  [ "$status" -eq 0 ]
  [ "$(cat "$PROBE_OUT.mode")" = "700" ]
  [ ! -e "$(cat "$PROBE_OUT.dir")" ]
}

@test "dev-lead-retry.sh: a failed hold fails the scan and the private marker directory is still removed" {
  SIMULATE_FAILED_HOLD=1 _run_retry_with_marker_probe
  [ "$status" -ne 0 ]
  [ "$(cat "$PROBE_OUT.mode")" = "700" ]
  [ ! -e "$(cat "$PROBE_OUT.dir")" ]
}
