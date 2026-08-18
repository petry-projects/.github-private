#!/usr/bin/env bats
# Tests for scripts/check-duplicate-decls.sh — the required duplicate-decl CI
# gate (#1520). The corrupted fixture replays the #1449/#1485 corruption
# signature (whole-block duplication of top-level functions).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/scripts/check-duplicate-decls.sh"
  FIXTURES="$REPO_ROOT/tests/dev-lead/fixtures/conflict-integrity"
  WORKDIR="$BATS_TEST_TMPDIR"
}

@test "gate: repo's own scripts/ tree is clean (green on restored main)" {
  run bash "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no duplicate top-level function declarations"* ]]
}

@test "gate: fails on the corrupted fixture and names the duplicated function" {
  cp "$FIXTURES/resolved_corrupted.sh" "$WORKDIR/"
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run_writer"* ]]
  [[ "$output" == *"declared 2 times"* ]]
}

@test "gate: failure output points at the #1485 incident record" {
  cp "$FIXTURES/resolved_corrupted.sh" "$WORKDIR/"
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#1485"* ]]
}

@test "gate: clean file passes; duplicated top-level VAR alone does not fail (functions only)" {
  cat > "$WORKDIR/clean_with_var_reassign.sh" <<'EOF'
#!/usr/bin/env bash
RC=0
one() { echo 1; }
RC=1
two() { echo 2; }
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "gate: catches duplicates defined with multiline 'name()\\n{' syntax" {
  cat > "$WORKDIR/multiline_dup.sh" <<'EOF'
#!/usr/bin/env bash
foo()
{
  echo 1
}
foo()
{
  echo 2
}
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"foo"* ]]
}

@test "gate: scans nested lib/ subdirectories" {
  mkdir -p "$WORKDIR/lib"
  cp "$FIXTURES/resolved_corrupted.sh" "$WORKDIR/lib/"
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
}
