#!/usr/bin/env bats
# Unit tests for scripts/lib/review-change-evidence.sh (#1567).
#
# These cover the PURE decision logic that moves the dev-lead status=applied
# claim from "a commit happened" to "the commit is non-trivial and touches the
# regions the review named": region parsing, per-item coverage, and the
# applied / partial / not-applied classification.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/review-change-evidence.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── rce_named_regions: extract path/line from OPEN_THREADS_JSON ────────────────

@test "rce_named_regions: emits path<TAB>line per unresolved thread" {
  local json='[{"isResolved":false,"path":"docs/adr.md","line":42},
               {"isResolved":false,"path":"scripts/run.sh","line":10}]'
  run rce_named_regions "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/adr.md"$'\t'"42"* ]]
  [[ "$output" == *"scripts/run.sh"$'\t'"10"* ]]
}

@test "rce_named_regions: null line becomes 0" {
  local json='[{"isResolved":false,"path":"docs/adr.md","line":null}]'
  run rce_named_regions "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == "docs/adr.md"$'\t'"0" ]]
}

@test "rce_named_regions: empty array yields no output" {
  run rce_named_regions '[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rce_named_regions: skips entries without a path" {
  local json='[{"isResolved":false,"path":null,"line":5},{"isResolved":false,"path":"a.md","line":1}]'
  run rce_named_regions "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == "a.md"$'\t'"1" ]]
}

# ── rce_parse_hunks: pre-image ranges from a unified diff ──────────────────────

@test "rce_parse_hunks: emits path and pre-image line range per hunk" {
  local diff='diff --git a/docs/adr.md b/docs/adr.md
--- a/docs/adr.md
+++ b/docs/adr.md
@@ -40,2 +40,2 @@ heading
-old line
+new line'
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | rce_parse_hunks" _ "$diff"
  [ "$status" -eq 0 ]
  [[ "$output" == "docs/adr.md"$'\t'"40"$'\t'"41" ]]
}

@test "rce_parse_hunks: single-line hunk (no count) has start==end" {
  local diff='diff --git a/a.sh b/a.sh
--- a/a.sh
+++ b/a.sh
@@ -7 +7 @@
-x
+y'
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | rce_parse_hunks" _ "$diff"
  [ "$status" -eq 0 ]
  [[ "$output" == "a.sh"$'\t'"7"$'\t'"7" ]]
}

# ── rce_region_covered ────────────────────────────────────────────────────────

@test "rce_region_covered: line inside a changed hunk is covered" {
  local changed="docs/adr.md"$'\t'"40"$'\t'"45"
  run rce_region_covered "docs/adr.md" "42" "$changed" 2
  [ "$status" -eq 0 ]
}

@test "rce_region_covered: line in a different file is not covered" {
  local changed="scripts/run.sh"$'\t'"40"$'\t'"45"
  run rce_region_covered "docs/adr.md" "42" "$changed" 2
  [ "$status" -ne 0 ]
}

@test "rce_region_covered: line far from any hunk is not covered" {
  local changed="docs/adr.md"$'\t'"40"$'\t'"41"
  run rce_region_covered "docs/adr.md" "200" "$changed" 2
  [ "$status" -ne 0 ]
}

@test "rce_region_covered: unknown line (0) falls back to file-level touch" {
  local changed="docs/adr.md"$'\t'"40"$'\t'"41"
  run rce_region_covered "docs/adr.md" "0" "$changed" 2
  [ "$status" -eq 0 ]
}

# ── rce_classify ──────────────────────────────────────────────────────────────

@test "rce_classify: non-substantive change is never applied" {
  run rce_classify "false" "docs/adr.md"$'\t'"42" "docs/adr.md"$'\t'"40"$'\t'"45"
  [ "$status" -eq 0 ]
  [ "$output" = "not-applied" ]
}

@test "rce_classify: substantive change covering all named regions is applied" {
  local named="docs/adr.md"$'\t'"42"
  local changed="docs/adr.md"$'\t'"40"$'\t'"45"
  run rce_classify "true" "$named" "$changed" 2
  [ "$status" -eq 0 ]
  [ "$output" = "applied" ]
}

@test "rce_classify: no named regions falls back to applied on a substantive change" {
  run rce_classify "true" "" "docs/adr.md"$'\t'"40"$'\t'"45"
  [ "$status" -eq 0 ]
  [ "$output" = "applied" ]
}

@test "rce_classify: substantive change covering none of the named regions is not-applied" {
  local named="docs/adr.md"$'\t'"200"
  local changed="docs/adr.md"$'\t'"40"$'\t'"41"
  run rce_classify "true" "$named" "$changed" 2
  [ "$status" -eq 0 ]
  [ "$output" = "not-applied" ]
}

@test "rce_classify: #1567 shape — one edit inside a multi-region review is partial, not applied" {
  # Review named five regions; the pass only touched one (the §4 cross-ref edit).
  local named="docs/adr.md"$'\t'"20
docs/adr.md"$'\t'"40
docs/adr.md"$'\t'"70
docs/adr.md"$'\t'"80
docs/adr.md"$'\t'"100"
  local changed="docs/adr.md"$'\t'"40"$'\t'"41"
  run rce_classify "true" "$named" "$changed" 2
  [ "$status" -eq 0 ]
  [ "$output" = "partial" ]
}

# ── rce_enumerate ─────────────────────────────────────────────────────────────

@test "rce_enumerate: reports applied vs not applied per requested item" {
  local named="docs/adr.md"$'\t'"40
docs/adr.md"$'\t'"100"
  local changed="docs/adr.md"$'\t'"40"$'\t'"41"
  run rce_enumerate "$named" "$changed" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/adr.md:40\` — applied"* ]]
  [[ "$output" == *"docs/adr.md:100\` — not applied"* ]]
}
