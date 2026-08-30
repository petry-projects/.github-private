#!/usr/bin/env bats
# Tests for scripts/check-vendored-installed-tools.sh — the narrow guard (#1541,
# split from #1468 AC 3) against the #1449 failure class: an agent commits a
# vendored copy of a tool (node_modules/bats/) that this repo's CI already
# installs via a package manager (lint.yml `apt-get install -y bats`). The guard
# fires ONLY on that exact overlap so it never false-positives on legitimate
# first-party committed assets (AC #2).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GUARD="$REPO_ROOT/scripts/check-vendored-installed-tools.sh"
  FIX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$FIX/.github/workflows"
}

# --- AC #3: the current clean tree passes -----------------------------------

@test "guard: repo's own tree is clean (CI installs bats, nothing vendored)" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no CI-installed tool is also committed as a vendored copy"* ]]
}

# --- AC #3: the #1449 fixture fails -----------------------------------------

@test "guard: fails on node_modules/bats alongside lint.yml's apt-get install -y bats" {
  cp "$REPO_ROOT/.github/workflows/lint.yml" "$FIX/.github/workflows/lint.yml"
  mkdir -p "$FIX/node_modules/bats/bin"
  touch "$FIX/node_modules/bats/bin/bats" "$FIX/node_modules/bats/package.json"

  run bash "$GUARD" "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bats"* ]]
  [[ "$output" == *"node_modules/bats"* ]]
  [[ "$output" == *"#1449"* ]]
}

@test "guard: names the vendoring dependency-manager directory in the report" {
  cp "$REPO_ROOT/.github/workflows/lint.yml" "$FIX/.github/workflows/lint.yml"
  mkdir -p "$FIX/vendor/bats"
  touch "$FIX/vendor/bats/bats"

  run bash "$GUARD" "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vendor/bats"* ]]
}

# --- AC #2: narrowness — no false positives ---------------------------------

@test "guard: install step but NO vendored copy passes (clean synthetic tree)" {
  cat > "$FIX/.github/workflows/lint.yml" <<'YML'
jobs:
  bats:
    steps:
      - run: sudo apt-get install -y bats
YML
  run bash "$GUARD" "$FIX"
  [ "$status" -eq 0 ]
}

@test "guard: vendored copy but NO matching install step passes" {
  # A vendored 'bats' with no workflow that installs bats — legitimate as far as
  # this guard is concerned; it only fires on the CI-installs-this-exact-tool overlap.
  cat > "$FIX/.github/workflows/other.yml" <<'YML'
jobs:
  build:
    steps:
      - run: echo nothing to install here
YML
  mkdir -p "$FIX/node_modules/bats"
  touch "$FIX/node_modules/bats/bats"
  run bash "$GUARD" "$FIX"
  [ "$status" -eq 0 ]
}

@test "guard: a first-party committed asset named like a tool but NOT under a dep dir passes" {
  cp "$REPO_ROOT/.github/workflows/lint.yml" "$FIX/.github/workflows/lint.yml"
  # committed first-party file at tools/bats — not under node_modules/vendor/.venv
  mkdir -p "$FIX/tools/bats"
  touch "$FIX/tools/bats/helper.sh"
  run bash "$GUARD" "$FIX"
  [ "$status" -eq 0 ]
}

# --- usage -------------------------------------------------------------------

@test "guard: nonexistent tree exits 2 with an error" {
  run bash "$GUARD" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}
