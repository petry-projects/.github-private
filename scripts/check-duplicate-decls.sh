#!/usr/bin/env bash
# check-duplicate-decls.sh — required CI gate against the #1485 corruption class.
#
# Fails when any shell script in the scanned directory declares the same
# top-level FUNCTION more than once. Bash last-definition-wins semantics mean a
# duplicated function silently shadows its earlier copies, so the test suite
# stays green while the file content is wrong — the mechanism that let the
# #1292 and #1378 merges land wholesale duplicated scripts on main (see #1485
# for the incident record and #1520 for this gate's story).
#
# Deliberately narrow (#1520 AC):
#   - Tree-state, not diff-aware: standing corruption fails, whoever introduced
#     it. The parent-aware introduction detector is lib/conflict-integrity.sh
#     on the rebase path (#1482); this gate is the merge-blocking backstop.
#   - Functions only. Top-level VARIABLE reassignment at column 0 is legitimate
#     shell (defaults overwritten conditionally), so var duplicates are not
#     gated — the corruption signature that reached trunk twice was duplicated
#     function bodies.
#   - No escape hatch by design. If an intentional duplicate is ever genuinely
#     needed, amend this script in a reviewed diff.
#
# Usage: check-duplicate-decls.sh [dir]   (default: the scripts/ dir this file
#        lives in, i.e. the repo's own scripts tree in CI)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/conflict-integrity.sh
source "$SCRIPT_DIR/lib/conflict-integrity.sh"

SCAN_DIR="${1:-$SCRIPT_DIR}"
if [ ! -d "$SCAN_DIR" ]; then
  echo "::error::check-duplicate-decls: scan directory does not exist: ${SCAN_DIR}" >&2
  exit 2
fi

fail=0
report=""
while IFS= read -r f; do
  # `grep` exits 1 on a file with no functions at all — that is a clean result,
  # not an error, so neutralize the pipeline status under `set -o pipefail`.
  findings="$(extract_top_level_symbols "$f" \
    | { grep '^fn:' || true; } \
    | sed 's/^fn://' \
    | LC_ALL=C sort | uniq -c \
    | awk '$1 > 1 { print $2 "\t" $1 }')"
  if [ -n "$findings" ]; then
    fail=1
    report="${report}$(format_integrity_findings "$f" "$findings")
"
  fi
done < <(find "$SCAN_DIR" -name '*.sh' -type f | LC_ALL=C sort)

if [ "$fail" -ne 0 ]; then
  echo "::error::Duplicate top-level function declarations found — the #1485 corruption class. This merge is blocked."
  printf '%s\n' "$report"
  echo "This is the signature of a botched automated conflict resolution (see #1485"
  echo "for the incident record and restoration playbook, #1520 for this gate)."
  echo "Fix by removing the duplicated definitions — do not patch around the check."
  exit 1
fi

echo "duplicate-decl-gate: no duplicate top-level function declarations under ${SCAN_DIR}"
