#!/usr/bin/env bats
# Unit tests for the merged-PR few-shot injection helper (issue #1093,
# epic #1088, Phase 2): scripts/lib/fewshot.sh.
#
# The deep tier is given a few-shot file of past review->merge outcomes so it
# calibrates to what this repo's maintainers actually accept and flag. The
# examples MUST come only from a proposer-visible / dev split — never from
# evals/**/holdout, the set the held-out gate later scores against — and must be
# de-identified (evals/README.md decision A3), opt-in, inert by default, and
# size-bounded so they stay within the ET cost cap.
#
# This suite pins the non-negotiable guarantees:
#   - fewshot_source_is_holdout hard-refuses any evals/**/holdout source path
#     (mirrors the holdout-guard rule);
#   - assemble_fewshot REFUSES a holdout source (never injects held-out cases);
#   - de-identification strips secrets/tokens/hostnames/emails before injection;
#   - the assembled block is bounded by max-examples and max-bytes;
#   - FEWSHOT_FILE is exported and points at the written file;
#   - a missing/empty source degrades to literal "(none)" (inert), exit 0.
#
# Run with: bats tests/dev-lead/unit/test_fewshot_assemble.bats

setup() {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/fewshot.sh"

  WORK="$(mktemp -d "$BATS_TEST_TMPDIR/fs.XXXXXX")"
  OUT_FILE="$WORK/fewshot.txt"
  SRC="$WORK/fewshot.jsonl"

  # A dev-split source line carrying content that MUST be scrubbed before it can
  # reach the reviewer prompt: an email, a GitHub token, an internal hostname.
  cat > "$SRC" << 'JSONL'
{"id":"fs-1","title":"Harden auth token handling","summary":"contact alice@example.com about db01.internal rotation","decision":"escalate","risk":"HIGH","rationale":"leaked ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 in a run step"}
{"id":"fs-2","title":"Add formatter tests","summary":"test-only change","decision":"approve","risk":"LOW","rationale":"all gates green"}
JSONL
}

teardown() {
  rm -rf "$WORK"
  unset FEWSHOT_FILE FEWSHOT_MAX_EXAMPLES FEWSHOT_MAX_BYTES
}

# ---------------------------------------------------------------------------
# Hard holdout guard (Task 3 / AC #2)
# ---------------------------------------------------------------------------

@test "fewshot_source_is_holdout flags an evals/**/holdout path" {
  run fewshot_source_is_holdout "evals/deep-review/holdout/cases.jsonl"
  [ "$status" -eq 0 ]
  run fewshot_source_is_holdout "evals/deep-review/holdout"
  [ "$status" -eq 0 ]
}

@test "fewshot_source_is_holdout passes a dev-split path" {
  run fewshot_source_is_holdout "evals/deep-review/dev/fewshot.jsonl"
  [ "$status" -ne 0 ]
  run fewshot_source_is_holdout "prompts/deep-review.md"
  [ "$status" -ne 0 ]
}

@test "assemble_fewshot REFUSES a holdout source and injects nothing" {
  local holdout="$WORK/holdout"
  mkdir -p "$holdout"
  # Give the holdout path a real, non-empty cases file so refusal is proven to
  # come from the path guard, not from an empty/missing source.
  cp "$SRC" "$holdout/cases.jsonl"
  run assemble_fewshot "evals/deep-review/holdout/cases.jsonl" "$OUT_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  # No example content leaked into the output file.
  run grep -q "Harden auth token handling" "$OUT_FILE"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# De-identification (Task 1 / A3)
# ---------------------------------------------------------------------------

@test "de-identification strips email, token, and internal hostname" {
  run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  # The raw sensitive strings must be gone.
  ! grep -q "alice@example.com" "$OUT_FILE"
  ! grep -q "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" "$OUT_FILE"
  ! grep -q "db01.internal" "$OUT_FILE"
  # A redaction marker is present in their place.
  grep -q "REDACTED" "$OUT_FILE"
  # Non-sensitive few-shot signal survives (the title / decision is still there).
  grep -q "Harden auth token handling" "$OUT_FILE"
}

@test "fewshot_scrub redacts secrets in an arbitrary string" {
  run fewshot_scrub "reach me at bob@corp.example with token AKIAIOSFODNN7EXAMPLE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"bob@corp.example"* ]]
  [[ "$output" != *"AKIAIOSFODNN7EXAMPLE"* ]]
  [[ "$output" == *"REDACTED"* ]]
}

# ---------------------------------------------------------------------------
# Export + happy path
# ---------------------------------------------------------------------------

@test "FEWSHOT_FILE is exported and points at the written file" {
  assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$FEWSHOT_FILE" = "$OUT_FILE" ]
  [ -f "$FEWSHOT_FILE" ]
}

@test "both dev-split examples render into the block" {
  run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "Harden auth token handling" "$OUT_FILE"
  grep -q "Add formatter tests" "$OUT_FILE"
}

# ---------------------------------------------------------------------------
# Bounds (AC #3 — stays within the ET cost cap)
# ---------------------------------------------------------------------------

@test "FEWSHOT_MAX_EXAMPLES caps the number of examples injected" {
  FEWSHOT_MAX_EXAMPLES=1 run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "Harden auth token handling" "$OUT_FILE"
  ! grep -q "Add formatter tests" "$OUT_FILE"
}

@test "the assembled block is truncated to the configured byte cap" {
  FEWSHOT_MAX_BYTES=40 run assemble_fewshot "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$OUT_FILE" ]
  [ "$(wc -c < "$OUT_FILE")" -le 40 ]
}

# ---------------------------------------------------------------------------
# Inert by default (AC #3)
# ---------------------------------------------------------------------------

@test "a missing source writes literal (none) and injects nothing" {
  run assemble_fewshot "$WORK/does-not-exist.jsonl" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT_FILE")" = "(none)" ]
}

@test "an empty source writes literal (none)" {
  : > "$WORK/empty.jsonl"
  run assemble_fewshot "$WORK/empty.jsonl" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT_FILE")" = "(none)" ]
}
