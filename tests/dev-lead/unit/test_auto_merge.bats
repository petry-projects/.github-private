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
  export AM_COMMIT_TITLE="" AM_COMMIT_MESSAGE="" HEAD_SHA_API=""

  # gh stub: AM_STATE / PR_STATE / GH_MERGE_RC are read at call time so each
  # test can set the PR's auto-merge state, open/closed state, and merge rc.
  # commit_title / commit_message / head.sha cases must come before the generic
  # *auto_merge* catch-all since those jq filters also contain "auto_merge".
  cat > "$STUB_BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
case "$*" in
  *"pr merge"*)            exit "${GH_MERGE_RC:-0}" ;;
  *"commit_title"*)        printf '%s' "${AM_COMMIT_TITLE:-}" ;;
  *"commit_message"*)      printf '%s' "${AM_COMMIT_MESSAGE:-}" ;;
  *"head.sha"*)            printf '%s' "${HEAD_SHA_API:-}" ;;
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
  AM_STATE="squash"
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

@test "restore_auto_merge: re-enables with the original merge strategy, not always squash" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  _AM_MERGE_METHOD="merge"
  PR_STATE="open"
  AM_STATE=""   # currently off (we disabled it)
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge 77 --repo owner/repo --auto --merge" "$GH_CALLS"
  ! grep -q -- "--squash" "$GH_CALLS"
}

@test "restore_auto_merge: re-enables with rebase strategy when originally set to rebase" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  _AM_MERGE_METHOD="rebase"
  PR_STATE="open"
  AM_STATE=""   # currently off (we disabled it)
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge 77 --repo owner/repo --auto --rebase" "$GH_CALLS"
}

@test "restore_auto_merge: does NOT re-enable on a merged/closed PR" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="closed"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto" "$GH_CALLS"
}

@test "restore_auto_merge: passes --match-head-commit when HEAD_SHA is set" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  export HEAD_SHA="abc123"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "--match-head-commit abc123" "$GH_CALLS"
}

@test "restore_auto_merge: skips when auto-merge is already back on (success path)" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE="enabled"   # success path already re-enabled it
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--auto" "$GH_CALLS"
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

# ── hold_auto_merge — commit text capture ─────────────────────────────────────

@test "hold_auto_merge: captures commit title and message when auto-merge is on" {
  source "$LIB"
  AM_STATE="squash"
  export AM_COMMIT_TITLE="My PR title"
  export AM_COMMIT_MESSAGE="My PR body"
  hold_auto_merge
  [ "${_AM_COMMIT_TITLE}" = "My PR title" ]
  [ "${_AM_COMMIT_MESSAGE}" = "My PR body" ]
}

# ── restore_auto_merge — HEAD_SHA refresh and commit text replay ──────────────

@test "restore_auto_merge: preserves original HEAD_SHA for --match-head-commit guard" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  export HEAD_SHA="original_sha"
  export HEAD_SHA_API="newer_sha"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "--match-head-commit original_sha" "$GH_CALLS"
  ! grep -q -- "--match-head-commit newer_sha" "$GH_CALLS"
}

@test "restore_auto_merge: passes --subject and --body when commit text was captured" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  _AM_COMMIT_TITLE="Custom title"
  _AM_COMMIT_MESSAGE="Custom body"
  run restore_auto_merge
  [ "$status" -eq 0 ]
  grep -q -- "pr merge.*--subject" "$GH_CALLS"
  grep -q -- "pr merge.*--body" "$GH_CALLS"
}

@test "restore_auto_merge: omits --subject and --body when no custom commit text" {
  source "$LIB"
  _AM_NEEDS_RESTORE=1
  PR_STATE="open"
  AM_STATE=""
  run restore_auto_merge
  [ "$status" -eq 0 ]
  ! grep -q -- "--subject" "$GH_CALLS"
  ! grep -q -- "--body" "$GH_CALLS"
}
