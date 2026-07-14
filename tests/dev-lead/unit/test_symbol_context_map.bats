#!/usr/bin/env bats
# Unit tests for the PURE half of the symbol-context assembler (issue #1090,
# epic #1088): sc_touched_functions <diff>.
#
# sc_touched_functions parses a unified diff and returns the set of function
# symbols the diff touches (added/removed/hunk-header signatures), with NO
# network / `gh` I/O — so the extraction is deterministic and unit-testable in
# isolation (mirrors the pure jq mapper in scripts/lib/downstream-impact.sh).
#
# Run with: bats tests/dev-lead/unit/test_symbol_context_map.bats

setup() {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/symbol-context.sh"
}

# ---------------------------------------------------------------------------
# Empty / no-function diffs
# ---------------------------------------------------------------------------

@test "empty diff yields no touched functions" {
  run sc_touched_functions ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a docs-only diff with no function definitions yields nothing" {
  local diff='--- a/README.md
+++ b/README.md
@@ -1,2 +1,2 @@
-old line
+new line
'
  run sc_touched_functions "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Language coverage
# ---------------------------------------------------------------------------

@test "bash function definitions (name() and function name) are extracted" {
  local diff='--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -10,3 +10,6 @@
+assemble_thing() {
+  :
+}
+function helper_fn {
+  :
+}
'
  run sc_touched_functions "$diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"assemble_thing"* ]]
  [[ "$output" == *"helper_fn"* ]]
}

@test "python def and js/ts function/const-arrow definitions are extracted" {
  local diff='--- a/app/util.py
+++ b/app/util.py
@@ -1,1 +1,2 @@
+def compute_total(items):
+    return 0
--- a/web/util.ts
+++ b/web/util.ts
@@ -1,1 +1,3 @@
+export function renderCard(props) {}
+const useThing = (x) => x
'
  run sc_touched_functions "$diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compute_total"* ]]
  [[ "$output" == *"renderCard"* ]]
  [[ "$output" == *"useThing"* ]]
}

@test "go func definitions (plain and method receiver) are extracted" {
  local diff='--- a/svc/handler.go
+++ b/svc/handler.go
@@ -1,1 +1,3 @@
+func ServeHTTP(w http.ResponseWriter, r *http.Request) {}
+func (s *Server) Start() error { return nil }
'
  run sc_touched_functions "$diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ServeHTTP"* ]]
  [[ "$output" == *"Start"* ]]
}

# ---------------------------------------------------------------------------
# Determinism: unique + sorted, and removed-line defs also count as "touched"
# ---------------------------------------------------------------------------

@test "the same function touched twice is reported once (unique)" {
  local diff='--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -10,2 +10,2 @@
-assemble_thing() {
+assemble_thing() {
'
  run sc_touched_functions "$diff"
  [ "$status" -eq 0 ]
  # exactly one line of output
  [ "$(printf '%s\n' "$output" | grep -c 'assemble_thing' || true)" -eq 1 ]
}
