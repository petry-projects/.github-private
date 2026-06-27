#!/usr/bin/env bats
# Integration tests for the cross-repo publish path in cut-release.sh (#872):
# feature-ideation + the six #482 reusables are hosted in petry-projects/.github,
# so their release/channel tags are cut against THAT repo via `gh api`. These
# tests run main() end-to-end with a fake `gh` so no network/tags are touched.
#
# Run with: bats tests/test_cut_release_cross_repo.bats

setup() {
  TT_TMP="$(mktemp -d)" || { echo "Failed to create temp directory" >&2; exit 1; }
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/cut-release.sh"
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
  install_gh_stub
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh: logs every call, resolves a fixed SHA, and answers the ref-exists probe
# from GH_TAG_EXISTS (default 0 = absent). POSTs to git/tags return a tag-object SHA.
install_gh_stub() {
  local bin="${TT_TMP}/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
[ "${1:-}" = "api" ] || exit 0
case "$*" in
  *"commits/"*)        echo "feedfacefeedfacefeedfacefeedfacefeedface"; exit 0 ;;
  *"git/ref/tags/"*)   [ "${GH_TAG_EXISTS:-0}" = "1" ] && exit 0 || exit 1 ;;  # exists probe
  *"git/tags"*)        echo "0babebabe0babebabe0babebabe0babebabe0bab"; exit 0 ;;  # annotated tag object
  *"git/refs"*)        exit 0 ;;  # create/patch ref
esac
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

@test "cross-repo --dry-run resolves the SHA against .github and touches nothing" {
  run env GH_TOKEN=x bash "$SCRIPT" agent-shield 2.1.0 --channel next --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'target=petry-projects/.github'
  echo "$output" | grep -q '(dry-run) no tags created'
  # resolved a SHA, but no tag object / ref was created
  grep -q 'commits/main' "$GH_CALLS"
  ! grep -qE 'POST .*git/(tags|refs)' "$GH_CALLS"
  ! grep -qE 'PATCH ' "$GH_CALLS"
}

@test "cross-repo without --push is print-only (no mutation)" {
  run env GH_TOKEN=x bash "$SCRIPT" agent-shield 2.1.0 --channel next
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'print only — re-run with --push'
  ! grep -qE 'POST .*git/(tags|refs)' "$GH_CALLS"
  ! grep -qE 'PATCH ' "$GH_CALLS"
}

@test "cross-repo --push creates the release tag and moves the channel on .github" {
  run env GH_TOKEN=x bash "$SCRIPT" agent-shield 2.1.0 --channel next --push
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'created agent-shield/v2.1.0 on petry-projects/.github'
  echo "$output" | grep -q 'moved agent-shield/next'
  echo "$output" | grep -q 'published to petry-projects/.github'
  # annotated tag object + ref creation both went to petry-projects/.github
  grep -qE 'POST repos/petry-projects/\.github/git/tags' "$GH_CALLS"
  grep -qE 'POST repos/petry-projects/\.github/git/refs .*refs/tags/agent-shield/v2.1.0' "$GH_CALLS"
}

@test "cross-repo --push refuses to overwrite an existing release tag" {
  GH_TAG_EXISTS=1 run env GH_TOKEN=x GH_TAG_EXISTS=1 bash "$SCRIPT" agent-shield 2.1.0 --channel next --push
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'already exists on petry-projects/.github'
  ! grep -qE 'POST .*git/tags' "$GH_CALLS"
}

@test "a this-repo agent still uses the local-git path (no gh api), dry-run" {
  run env GH_TOKEN=x bash "$SCRIPT" pr-review 9.9.9 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'target=origin (this repo)'
  ! grep -q 'commits/' "$GH_CALLS"
}
