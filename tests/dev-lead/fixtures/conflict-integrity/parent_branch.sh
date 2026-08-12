#!/usr/bin/env bash
# Fixture: the BRANCH (PR head) side of the #1449 conflict — each top-level
# symbol declared exactly once, with the branch's own edits (run_writer gains a
# model arg, plus a branch-only run_reviewer).
set -euo pipefail

MAX_RETRIES=3

run_writer() {
  local prompt="$1"
  local model="$2"
  echo "writing $prompt with $model"
}

extract_verdict_json() {
  local log="$1"
  grep -oE '\{.*\}' "$log"
}

parse_reset_time() {
  local header="$1"
  date -d "$header" +%s
}

build_prompt() {
  echo "prompt"
}

run_reviewer() {
  echo "review"
}
