#!/usr/bin/env bash
# Fixture: a parent that ALREADY declares `legacy_shim` twice (an intentional,
# pre-existing repetition upstream). The detector must not flag a symbol that was
# already duplicated in a parent — only duplication *introduced* by the merge.
set -euo pipefail

legacy_shim() {
  echo "shim v1"
}

legacy_shim() {
  echo "shim v2"
}

core_a() {
  echo a
}
