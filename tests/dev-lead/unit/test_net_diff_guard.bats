#!/usr/bin/env bats
# Unit tests for scripts/lib/net-diff-guard.sh (#1786, slice 1 of epic #1620).
#
# The guard must tell three states apart on a real repo:
#   - net diff empty      → net_diff_is_empty returns 0 (true)
#   - net diff non-empty  → net_diff_is_empty returns 1 (false)
#   - base unverifiable   → net_diff_is_empty returns 1 (FAIL-OPEN), never 0
# and net_diff_summary must report file count + net line change (and never
# assert "0 files" from an unresolved base).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/net-diff-guard.sh"

setup() {
  # shellcheck source=scripts/lib/net-diff-guard.sh
  source "$LIB"
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO_DIR"
  git -C "$REPO_DIR" init -q
  printf 'base\n' > "$REPO_DIR/file.txt"
  git -C "$REPO_DIR" add .
  git -C "$REPO_DIR" -c user.email="t@test" -c user.name="T" commit -q -m "base"
  BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  # origin/main tracks the base commit (no real remote needed for a three-dot diff).
  git -C "$REPO_DIR" update-ref refs/remotes/origin/main "$BASE_SHA"
}

# Add a feature commit, then optionally revert it, and echo nothing — the caller
# runs the guard from inside $REPO_DIR.
_add_feature_commit() {
  printf 'base\nfeature\n' > "$REPO_DIR/file.txt"
  git -C "$REPO_DIR" add .
  git -C "$REPO_DIR" -c user.email="t@test" -c user.name="T" commit -q -m "feat"
}

_revert_feature_commit() {
  printf 'base\n' > "$REPO_DIR/file.txt"
  git -C "$REPO_DIR" add .
  git -C "$REPO_DIR" -c user.email="t@test" -c user.name="T" commit -q -m "revert"
}

@test "net_diff_is_empty: empty net diff (feature added then reverted) → true" {
  _add_feature_commit
  _revert_feature_commit
  cd "$REPO_DIR"
  run net_diff_is_empty main
  [ "$status" -eq 0 ]
}

@test "net_diff_is_empty: non-empty net diff (feature stands) → false" {
  _add_feature_commit
  cd "$REPO_DIR"
  run net_diff_is_empty main
  [ "$status" -eq 1 ]
}

@test "net_diff_is_empty: no changes at all against base → true" {
  cd "$REPO_DIR"
  run net_diff_is_empty main
  [ "$status" -eq 0 ]
}

@test "net_diff_is_empty: unresolvable base fails open (returns 1, warns)" {
  cd "$REPO_DIR"
  run net_diff_is_empty does-not-exist
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not resolve"* ]]
}

@test "net_diff_is_empty: base defaults to main when omitted" {
  _add_feature_commit
  cd "$REPO_DIR"
  run net_diff_is_empty
  [ "$status" -eq 1 ]
}

@test "net_diff_summary: reports file count and net line change" {
  _add_feature_commit
  cd "$REPO_DIR"
  run net_diff_summary main
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s)"* ]]
  [[ "$output" == *"+1/-0 lines"* ]]
}

@test "net_diff_summary: unresolvable base reports unknown, never '0 files'" {
  cd "$REPO_DIR"
  run net_diff_summary does-not-exist
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown"* ]]
  [[ "$output" != *"file(s)"* ]]
}
