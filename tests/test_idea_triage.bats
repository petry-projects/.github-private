#!/usr/bin/env bats
# Tests for the idea-triage queue upsert (scripts/idea-triage/upsert-queue.sh).
# Only the DRY_RUN path is exercised (no network).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRIAGE_DIR="$ROOT/scripts/idea-triage"
  TMP="$(mktemp -d)"
  BODY="$TMP/body.md"
  LOG="$TMP/dry.jsonl"
  printf '# Idea Promotion Queue\n\nRipe: #562\n' >"$BODY"
}

teardown() { rm -rf "$TMP"; }

@test "upsert-queue (DRY_RUN) logs the intended upsert with a non-empty body" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    QUEUE_BODY_PATH="$BODY" run bash "$TRIAGE_DIR/upsert-queue.sh"
  [ "$status" -eq 0 ]
  grep -q '"op":"upsert_queue"' "$LOG"
  # body_len recorded and > 0
  [ "$(jq -r 'select(.op=="upsert_queue") | .body_len' "$LOG")" -gt 0 ]
}

@test "upsert-queue fails on a missing/empty body" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    QUEUE_BODY_PATH="$TMP/does-not-exist.md" run bash "$TRIAGE_DIR/upsert-queue.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or empty"* ]]
}
