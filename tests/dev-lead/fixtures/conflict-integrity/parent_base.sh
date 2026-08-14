#!/usr/bin/env bash
# Fixture: the BASE (main) side of the #1449 conflict — each top-level symbol
# declared exactly once. Represents scripts/engine.sh on `main`.
set -euo pipefail

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
