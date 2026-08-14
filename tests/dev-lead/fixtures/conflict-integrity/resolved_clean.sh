#!/usr/bin/env bash
# Fixture: a CORRECT resolution of the #1449 conflict — the union of both sides,
# each top-level symbol declared exactly once. Must produce NO integrity finding.
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
