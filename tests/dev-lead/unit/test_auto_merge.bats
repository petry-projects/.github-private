#!/usr/bin/env bats
# Unit tests for scripts/lib/auto-merge.sh
#
# Covers holding auto-merge OFF while dev-lead works a PR, restoring it on exit,
# and the push guard that treats a mid-run merge as a benign no-op rather than a
# red-X failure (see run 27078382804).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/auto-merge.sh"

setup() {
  STUB_BIN_DIR="$(mktemp -d)"
  export PATH="$STUB_BIN_DIR:$PATH"
  export GH_CALLS="$(mktemp)"
  export PR_NUMBER=77 REPO="owner/repo" DEV_LEAD_DRY_RUN=false
  # Exported so the gh stub subprocess sees them; tests reassign (export sticks).
  export AM_STATE="" PR_STATE="open" GH_MERGE_RC=0

  # gh stub: AM_STATE / PR_STATE / GH_MERGE_RC are read at call time so each
  # test can set the PR's auto-merge state, open/closed state, and merge rc.
  cat > "$STUB_BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
case "$*" in
  *"pr merge"*)            exit "${GH_MERGE_RC:-0}" ;;
  *auto_merge*)            printf '%s' "${AM_STATE:-}" ;;
  *".state"*)              printf '%s' "${PR_STATE:-open}" ;;
  *)                       echo "{}" ;;
esac
EOF
  chmod +x "$STUB_BIN_DIR/gh"
}

teardown() { rm -rf "$STUB_BIN_DIR" "$GH_CALLS"; }

# ── hold_auto_merge ───────────────────────────────────────────────────────────

@test "hold_auto_merge: disables auto-merge when it is currently on" {
  source "$LIB"
  AM_STATE="enabled"
  run hold_auto_merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"holding auto-merge OFF"* ]]
  grep -q -- "pr merge 77 --repo owner/repo --disable-auto" "$GH_CALLS"
}

@test "hold_auto_merge: no-op (no disable) when auto-merge is already off" {
  source "$LIB"
  AM_STATE=""
  run hold_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--disable-auto" "$GH_CALLS"
}

@test "hold_auto_merge: dry-run does not touch gh" {
  source "$LIB"
  export DEV_LEAD_DRY_RUN=true
  AM_STATE="enabled"
  run hold_auto_merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -s "$GH_CALLS" ]
}

# ── restore_auto_merge ────────────────────────────────────────────────────────

@test "restore_auto_merge: no-op when we never disabled auto-merge" {
  source "$LIB"
  _AM_NEEDS_RESTORE=0
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto" "$GH_CALLS"
}

@test "restore_auto_merge: re-enables when we disabled it and the PR is still open" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""   # currently off (we disabled it)
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge 77 --repo owner/repo --auto --squash" "$GH_CALLS"
}

@test "restore_auto_merge: does NOT re-enable on a merged/closed PR" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="closed"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto --squash" "$GH_CALLS"
}

@test "restore_auto_merge: skips when auto-merge is already back on (success path)" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE="enabled"   # success path already re-enabled it
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto --squash" "$GH_CALLS"
}

# ── push_with_merge_guard ─────────────────────────────────────────────────────

_install_git_stub() {  # $1 = push exit code
  cat > "$STUB_BIN_DIR/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = push ]; then
  echo "remote: rejected (stub)" >&2
  exit ${1:-0}
fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$STUB_BIN_DIR/git"
}

@test "push_with_merge_guard: returns 0 on a successful push" {
  source "$LIB"
  cat > "$STUB_BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = push ] && exit 0
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUB_BIN_DIR/git"
  run push_with_merge_guard
  [ "$status" -eq 0 ]
}

@test "push_with_merge_guard: exits 0 cleanly when the PR was merged/closed mid-run" {
  source "$LIB"
  _install_git_stub 1
  PR_STATE="closed"
  run push_with_merge_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to push"* ]]
}

@test "push_with_merge_guard: returns 1 on a genuine push failure (PR still open)" {
  source "$LIB"
  _install_git_stub 1
  PR_STATE="open"
  run push_with_merge_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"git push failed"* ]]
}
