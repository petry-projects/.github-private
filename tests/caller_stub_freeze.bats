#!/usr/bin/env bats
# Tests for scripts/caller_stub_freeze.sh — the ring-0 stub-freeze guard (#1052,
# Part B). It freezes each self-host caller stub's input-forwarding block (the
# reusable `uses:` + its `with:` block) against a committed baseline, reusing the
# fleet_stub_drift.sh byte-identity ALIGNED/DRIFTED/MISSING model, so a #1034-style
# `with:` forwarding change on a channel-pinned stub fails CI unless the baseline
# is updated in the same reviewed diff.
#
# All assertions here are PURE (no network). Run:
#   bats tests/caller_stub_freeze.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME"/.. && pwd)"
  FIX="$REPO_ROOT/tests/dev-lead/fixtures/caller-inputs"
  # shellcheck source=scripts/caller_stub_freeze.sh
  source "$REPO_ROOT/scripts/caller_stub_freeze.sh"
  EXPECTED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

# ---------------------------------------------------------------------------
# extract_forwarding_block — the uses + with block, comments/blanks stripped
# ---------------------------------------------------------------------------

@test "extract_forwarding_block: captures the reusable uses ref and its with keys" {
  run extract_forwarding_block "$FIX/caller_ok.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next"* ]]
  [[ "$output" == *"with:"* ]]
  [[ "$output" == *"agent_ref: pr-review/next"* ]]
  [[ "$output" == *"force_review:"* ]]
}

@test "extract_forwarding_block: strips comment lines (benign doc edits do not drift)" {
  # caller_1034.yml carries header comments; none of them appear in the block.
  run extract_forwarding_block "$FIX/caller_1034.yml"
  [ "$status" -eq 0 ]
  [[ "$output" != *"#"* ]]
}

@test "extract_forwarding_block: reflects a forwarding change (#1034 adds a key)" {
  ok="$(extract_forwarding_block "$FIX/caller_ok.yml")"
  drifted="$(extract_forwarding_block "$FIX/caller_1034.yml")"
  [ "$ok" != "$drifted" ]
  [[ "$drifted" == *"lsp_pilot_variant"* ]]
  [[ "$ok" != *"lsp_pilot_variant"* ]]
}

# ---------------------------------------------------------------------------
# Byte-identity classification is reused from fleet_stub_drift.sh
# ---------------------------------------------------------------------------

@test "classify_stub_drift is available (sourced from fleet_stub_drift.sh)" {
  run type -t classify_stub_drift
  [ "$output" = "function" ]
}

@test "freeze classification: identical forwarding blocks are ALIGNED" {
  sha="$(printf '%s\n' "$(extract_forwarding_block "$FIX/caller_ok.yml")" | git hash-object --stdin)"
  run classify_stub_drift "$sha" "$sha"
  [ "$output" = "ALIGNED" ]
}

@test "freeze classification: a changed forwarding block is DRIFTED" {
  ok_sha="$(printf '%s\n' "$(extract_forwarding_block "$FIX/caller_ok.yml")" | git hash-object --stdin)"
  new_sha="$(printf '%s\n' "$(extract_forwarding_block "$FIX/caller_1034.yml")" | git hash-object --stdin)"
  run classify_stub_drift "$ok_sha" "$new_sha"
  [ "$output" = "DRIFTED" ]
}

# ---------------------------------------------------------------------------
# caller_stub_freeze_annotate — errors + job failure on DRIFTED
# ---------------------------------------------------------------------------

@test "annotate: a DRIFTED row emits ::error:: naming the stub and fails" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/pr-review-trigger.yml" "DRIFTED" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$EXPECTED" >> "$tsv"
  run caller_stub_freeze_annotate "$tsv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"pr-review-trigger.yml"* ]]
  [[ "$output" == *"bbbbbbb"* ]]
  rm -f "$tsv"
}

@test "annotate: an all-ALIGNED set passes with no error" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "ALIGNED" "$EXPECTED" "$EXPECTED" >> "$tsv"
  run caller_stub_freeze_annotate "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error"* ]]
  rm -f "$tsv"
}

@test "annotate: MISSING is a warning, not a failure" {
  tsv="$(mktemp)"
  printf '%s\t%s\t%s\t%s\n' ".github/workflows/dev-lead.yml" "MISSING" "" "$EXPECTED" >> "$tsv"
  run caller_stub_freeze_annotate "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning"* ]]
  rm -f "$tsv"
}

# ---------------------------------------------------------------------------
# End-to-end: the real ring-0 stubs match their committed baselines on main
# ---------------------------------------------------------------------------

@test "driver: current ring-0 stubs are ALIGNED with their baselines (passes on main)" {
  run bash "$REPO_ROOT/scripts/caller_stub_freeze.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALIGNED"* ]]
  [[ "$output" != *"DRIFTED"* ]]
}
