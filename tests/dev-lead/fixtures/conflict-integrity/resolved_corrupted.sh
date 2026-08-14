#!/usr/bin/env bash
# Fixture: the BOTCHED resolution of the #1449 conflict — the merge duplicated
# whole blocks, so run_writer / extract_verdict_json / parse_reset_time (and the
# MAX_RETRIES constant) each appear TWICE, roughly doubling the file. This is the
# exact corruption signature that grew scripts/engine.sh from 2688 to 4011 lines.
set -euo pipefail

MAX_RETRIES=3
MAX_RETRIES=3

run_writer() {
  local prompt="$1"
  echo "writing $prompt"
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
