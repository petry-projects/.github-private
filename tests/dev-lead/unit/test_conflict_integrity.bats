#!/usr/bin/env bats
# Unit + regression tests for scripts/lib/conflict-integrity.sh (#1482).
#
# The regression fixture reproduces the #1449 corruption: a botched conflict
# resolution duplicated whole blocks of scripts/engine.sh (2688 → 4011 lines),
# doubling run_writer / parse_reset_time / extract_verdict_json. The detector must
# catch that at the point of resolution — not wait for an unrelated unit test to
# trip over the corrupted function hours later.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/conflict-integrity.sh"
FIX="$SCRIPT_DIR/tests/dev-lead/fixtures/conflict-integrity"

setup() {
  # shellcheck source=scripts/lib/conflict-integrity.sh
  source "$LIB"
}

# ---------------------------------------------------------------------------
# extract_top_level_symbols
# ---------------------------------------------------------------------------

@test "extract_top_level_symbols: emits top-level functions and vars" {
  run extract_top_level_symbols "$FIX/parent_base.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fn:run_writer"* ]]
  [[ "$output" == *"fn:extract_verdict_json"* ]]
  [[ "$output" == *"fn:parse_reset_time"* ]]
  [[ "$output" == *"var:MAX_RETRIES"* ]]
}

@test "extract_top_level_symbols: ignores indented / nested declarations" {
  local f="$BATS_TEST_TMPDIR/test_file.sh"
  cat > "$f" <<'EOF'
top() {
  local nested=1
  inner() { echo nested; }
}
EOF
  run extract_top_level_symbols "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fn:top"* ]]
  # A function defined *inside* another (indented) is not a top-level decl.
  [[ "$output" != *"fn:inner"* ]]
  # An indented `local` assignment is not a top-level variable decl.
  [[ "$output" != *"var:nested"* ]]
}

@test "extract_top_level_symbols: recognizes allman-style bare name() (brace on next line)" {
  local f="$BATS_TEST_TMPDIR/allman.sh"
  cat > "$f" <<'EOF'
alpha()
{
  echo a
}
beta()
{
  echo b
}
EOF
  run extract_top_level_symbols "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fn:alpha"* ]]
  [[ "$output" == *"fn:beta"* ]]
}

# ---------------------------------------------------------------------------
# new_duplicate_symbols — the #1449 regression
# ---------------------------------------------------------------------------

@test "new_duplicate_symbols: flags the #1449 doubled engine.sh symbols" {
  run new_duplicate_symbols "$FIX/resolved_corrupted.sh" "$FIX/parent_base.sh" "$FIX/parent_branch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fn:run_writer"* ]]
  [[ "$output" == *"fn:extract_verdict_json"* ]]
  [[ "$output" == *"fn:parse_reset_time"* ]]
  # The duplicated top-level constant is caught too.
  [[ "$output" == *"var:MAX_RETRIES"* ]]
  # Symbols that stayed single (build_prompt, run_reviewer) are NOT flagged.
  [[ "$output" != *"build_prompt"* ]]
  [[ "$output" != *"run_reviewer"* ]]
}

@test "new_duplicate_symbols: reports the resolved declaration count" {
  run new_duplicate_symbols "$FIX/resolved_corrupted.sh" "$FIX/parent_base.sh" "$FIX/parent_branch.sh"
  [ "$status" -eq 0 ]
  # Each doubled symbol appears twice in the resolved file.
  [[ "$output" == *$'fn:run_writer\t2'* ]]
}

@test "new_duplicate_symbols: flags an allman-style duplicated function" {
  # The #1532 blind spot: a botched resolution that duplicates a function in
  # allman style (bare signature, brace on the next line) must be caught by the
  # #1482 detector just like the same-line-brace form.
  local resolved="$BATS_TEST_TMPDIR/allman_dup.sh"
  cat > "$resolved" <<'EOF'
gamma()
{
  echo 1
}
gamma()
{
  echo 2
}
EOF
  run new_duplicate_symbols "$resolved" "/nonexistent/base.sh" "/nonexistent/branch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'fn:gamma\t2'* ]]
}

@test "new_duplicate_symbols: a correct union resolution is clean" {
  run new_duplicate_symbols "$FIX/resolved_clean.sh" "$FIX/parent_base.sh" "$FIX/parent_branch.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC #6 — no false positive on legitimately large diffs / pre-existing dups
# ---------------------------------------------------------------------------

@test "new_duplicate_symbols: does not flag a symbol already duplicated in a parent" {
  run new_duplicate_symbols "$FIX/resolved_large_legit.sh" "$FIX/parent_predup.sh" "$FIX/parent_base.sh"
  [ "$status" -eq 0 ]
  # legacy_shim was already declared twice in the parent — carrying it through
  # unchanged is legitimate, not corruption.
  [[ "$output" != *"legacy_shim"* ]]
  # Many new single-declaration functions in a large diff are not flagged.
  [ -z "$output" ]
}

@test "new_duplicate_symbols: missing parent blobs are treated as empty (new file)" {
  run new_duplicate_symbols "$FIX/resolved_corrupted.sh" "/nonexistent/base.sh" "/nonexistent/branch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'fn:run_writer\t2'* ]]
}

# ---------------------------------------------------------------------------
# format_integrity_findings — the actionable comment body
# ---------------------------------------------------------------------------

@test "format_integrity_findings: names the file and the duplicated symbols" {
  local findings
  findings="$(new_duplicate_symbols "$FIX/resolved_corrupted.sh" "$FIX/parent_base.sh" "$FIX/parent_branch.sh")"
  run format_integrity_findings "scripts/engine.sh" "$findings"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/engine.sh"* ]]
  [[ "$output" == *"run_writer"* ]]
  [[ "$output" == *"parse_reset_time"* ]]
}
