#!/usr/bin/env bats
# Golden-fixture regression guard for the pure downstream-impact mapper
# (issue #753, epic #748): compute_downstream_impact <changed_files> <manifest>.
#
# Unlike test_downstream_impact_map.bats (which asserts individual behaviours),
# this guard PINS the mapper's exact output against committed golden fixtures so
# that ANY change to the mapping output — added/removed fields, reordered lists,
# altered provider-normalisation — fails CI. The golden manifest is FROZEN and
# deliberately independent of the live scripts/lib/consumer-manifest.json: this
# guard protects the mapping LOGIC, not the manifest DATA (which Story 1's
# builder legitimately refreshes). Changing expected mapping output therefore
# requires an explicit, reviewable fixture update visible in the diff.
#
# Each case directory under fixtures/.../golden/cases/ holds:
#   - changed.txt  : the newline-delimited changed-file input (optional; omit for empty input)
#   - expected.json: the golden mapper output (canonicalised with `jq -S`)
#
# This is fixture-based regression testing, not metric/eval tuning, so no
# held-out split is needed.
#
# Run with: bats tests/test_downstream_impact_regression.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/downstream-impact.sh"
  GOLDEN_DIR="$(dirname "$BATS_TEST_FILENAME")/fixtures/downstream-impact/golden"
  MANIFEST="$GOLDEN_DIR/manifest.json"
}

# Compare the mapper's output for a case against its golden expected.json.
# Both sides are canonicalised (jq -S, sorted keys) so the comparison is exact
# but insensitive to incidental whitespace/key-order from jq itself.
_assert_golden_case() {
  local case_dir="$1"
  local changed expected actual
  if [ -f "$case_dir/changed.txt" ]; then
    changed="$(cat "$case_dir/changed.txt")"
  else
    changed=""
  fi
  expected="$(jq -S . "$case_dir/expected.json")"
  actual="$(compute_downstream_impact "$changed" "$MANIFEST" | jq -S .)"
  if [ "$actual" != "$expected" ]; then
    echo "Golden mismatch for case: $case_dir" >&2
    echo "--- expected ---" >&2
    echo "$expected" >&2
    echo "--- actual ---" >&2
    echo "$actual" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# The golden fixtures must exist and be well-formed (a deleted/renamed fixture
# must not silently turn the guard into a no-op).
# ---------------------------------------------------------------------------

@test "golden manifest fixture exists and is valid JSON" {
  [ -f "$MANIFEST" ]
  jq empty "$MANIFEST"
}

@test "at least one golden case is present" {
  local count=0
  for d in "$GOLDEN_DIR"/cases/*/; do
    [ -d "$d" ] && count=$((count + 1))
  done
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Per-case golden pins. Each named case must match its committed expected.json
# byte-for-byte (after canonicalisation), so a mapping-logic change fails CI.
# ---------------------------------------------------------------------------

@test "golden: direct reusable-workflow change" {
  _assert_golden_case "$GOLDEN_DIR/cases/01-direct-workflow"
}

@test "golden: indirect scripts/lib change via surface_sources" {
  _assert_golden_case "$GOLDEN_DIR/cases/02-indirect-lib"
}

@test "golden: indirect prompts change via surface_sources" {
  _assert_golden_case "$GOLDEN_DIR/cases/03-indirect-prompt"
}

@test "golden: source shared by two reusables (union of surfaces + consumers)" {
  _assert_golden_case "$GOLDEN_DIR/cases/04-shared-source-union"
}

@test "golden: mixed impacting + non-impacting paths" {
  _assert_golden_case "$GOLDEN_DIR/cases/05-mixed"
}

@test "golden: no-impact change" {
  _assert_golden_case "$GOLDEN_DIR/cases/06-no-impact"
}

@test "golden: empty changed-file list" {
  _assert_golden_case "$GOLDEN_DIR/cases/07-empty"
}

# Catch-all so a NEW case directory added without a matching @test above is
# still pinned (and a fixture with a missing expected.json fails loudly).
@test "every golden case directory matches its expected output" {
  local d
  for d in "$GOLDEN_DIR"/cases/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/expected.json" ] || { echo "missing expected.json in $d" >&2; return 1; }
    _assert_golden_case "${d%/}"
  done
}

# ---------------------------------------------------------------------------
# AC#1 cost cap: with the feature flag off, the triage inlining is a no-op, so
# the triage prompt stays byte-identical to pre-feature behavior.
# ---------------------------------------------------------------------------

@test "flag off: triage section emits nothing (off-path no-op)" {
  local impact_file="$BATS_TEST_TMPDIR/impact.txt"
  printf 'Impacted shared surfaces:\n  - .github/workflows/pr-review.yml\n' > "$impact_file"
  unset DOWNSTREAM_IMPACT_ENABLED
  run downstream_impact_triage_section "$impact_file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "flag explicitly false: triage section emits nothing (off-path no-op)" {
  local impact_file="$BATS_TEST_TMPDIR/impact.txt"
  printf 'Impacted shared surfaces:\n  - .github/workflows/pr-review.yml\n' > "$impact_file"
  export DOWNSTREAM_IMPACT_ENABLED=false
  run downstream_impact_triage_section "$impact_file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
