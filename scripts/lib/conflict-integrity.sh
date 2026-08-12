#!/usr/bin/env bash
# conflict-integrity.sh — post-conflict-resolution integrity check (#1482).
#
# A narrow, mechanical detector for the corruption class from #1449: a botched
# automated conflict resolution that duplicates whole blocks of a shell script
# (grew scripts/engine.sh from 2688 to 4011 lines, doubling run_writer /
# parse_reset_time / extract_verdict_json). Such a resolution "completes" and
# reports success, so nothing on the conflict-resolution path checks it — it only
# surfaces hours later when an unrelated test trips over the corrupted function.
#
# These helpers are pure (no network/git side effects) so they are unit-testable
# in isolation; the git/gh plumbing that feeds them lives in the caller
# (dev-lead-fix-reviews.sh's rebase intent). The detector is deliberately
# mechanical — duplicate top-level declarations — not a semantic "is this diff
# correct" analysis, which is neither tractable nor in scope.

# extract_top_level_symbols <file>
# Emit one line per top-level declaration in file order, tagged by kind:
#   fn:NAME   — a function declaration (`NAME() {` / `NAME()` / `function NAME`)
#   var:NAME  — a top-level variable assignment (optionally export/readonly/declare)
# "Top-level" means the declaration begins at column 0 (no leading whitespace),
# so nested functions and in-function `local` assignments are ignored. A symbol
# declared N times appears N times.
extract_top_level_symbols() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    # NAME() {   /   NAME()      (POSIX + ksh function forms), column 0 only.
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
      name = $0
      sub(/[[:space:]]*\(\).*$/, "", name)
      print "fn:" name
      next
    }
    # function NAME   (with or without trailing parens).
    /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      name = $2
      sub(/\(.*$/, "", name)
      print "fn:" name
      next
    }
    # [export|readonly|declare -x] NAME=...   top-level assignment, column 0.
    /^(export[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*=/ {
      line = $0
      sub(/^(export[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)/, "", line)
      name = line
      sub(/=.*$/, "", name)
      print "var:" name
      next
    }
  ' "$file"
}

# symbol_counts <file>
# Emit "SYMBOL<TAB>COUNT" for every top-level symbol, sorted.
symbol_counts() {
  extract_top_level_symbols "$1" | LC_ALL=C sort | uniq -c \
    | awk '{ print $2 "\t" $1 }'
}

# _count_of <counts-block> <symbol>
# Look up a symbol's count in a "SYMBOL<TAB>COUNT" block; 0 if absent.
_count_of() {
  local counts="$1" sym="$2" c
  c="$(printf '%s\n' "$counts" | awk -F'\t' -v s="$sym" '$1 == s { print $2; exit }')"
  printf '%s' "${c:-0}"
}

# new_duplicate_symbols <resolved> <parent_a> <parent_b>
# Emit "SYMBOL<TAB>COUNT" for each top-level symbol whose declaration count in
# the resolved file EXCEEDS its count in *both* parents — i.e., the resolution
# introduced extra copies. A symbol that already appeared N times in a parent and
# still appears N times is NOT flagged, so a legitimate large upstream merge (or
# an intentional pre-existing repetition) does not trip the check (AC #1, #6).
# A missing parent file counts as zero declarations (a brand-new file that itself
# ships duplicate declarations is still flagged).
new_duplicate_symbols() {
  local resolved="$1" parent_a="$2" parent_b="$3"
  {
    extract_top_level_symbols "$parent_a" | awk '{print "a\t" $0}'
    extract_top_level_symbols "$parent_b" | awk '{print "b\t" $0}'
    extract_top_level_symbols "$resolved"  | awk '{print "r\t" $0}'
  } | awk -F'\t' '
    $1 == "a" { count_a[$2]++ }
    $1 == "b" { count_b[$2]++ }
    $1 == "r" { count_r[$2]++ }
    END {
      for (sym in count_r) {
        rcount = count_r[sym]
        if (rcount > 1) {
          acount = count_a[sym] + 0
          bcount = count_b[sym] + 0
          maxp = (acount > bcount) ? acount : bcount
          if (rcount > maxp) {
            print sym "\t" rcount
          }
        }
      }
    }
  ' | LC_ALL=C sort
}

# format_integrity_findings <file> <findings>
# Render a Markdown bullet naming the file and each duplicated symbol, where
# <findings> is the "SYMBOL<TAB>COUNT" output of new_duplicate_symbols. Emits
# nothing when there are no findings.
format_integrity_findings() {
  local file="$1" findings="$2"
  [ -n "$findings" ] || return 0
  printf -- '- `%s` — duplicated top-level declarations after resolution:\n' "$file"
  printf '%s\n' "$findings" | while IFS="$(printf '\t')" read -r sym count; do
    [ -n "$sym" ] || continue
    printf -- '  - `%s` (declared %s times)\n' "$sym" "$count"
  done
}
