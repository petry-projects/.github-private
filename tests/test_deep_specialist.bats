#!/usr/bin/env bats
# Unit tests for the issue-type classifier + specialist deep-review routing
# (issue #1091, epic #1088).
#
# Phase 2 of the bug-hunter initiative: the Haiku-tier triage now emits a `type`
# label in {security, logic, performance, style}; the cascade resolves the
# matching specialist deep-review prompt DATA-DRIVEN through the rubric registry
# (scripts/lib/review-registry.tsv `deep_specialist:<type>` rows), not a switch
# in review-one-pr.sh. An ambiguous/absent label or an unresolvable specialist
# must fall back to the monolithic prompts/deep-review.md so the deep tier never
# dead-ends (AC #4).
#
# These checks are deterministic and offline — the label itself is produced by
# the live model, but the shell classification, registry resolution, and
# fallback are pure logic and fully testable here.
#
# Run with: bats tests/test_deep_specialist.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/deep-specialist.sh"
  FALLBACK="prompts/deep-review.md"
}

# ---------------------------------------------------------------------------
# normalize_diff_type — canonicalizes the raw label; unknown -> "ambiguous"
# ---------------------------------------------------------------------------

@test "normalize_diff_type passes through each known class" {
  local c
  for c in security logic performance style; do
    run normalize_diff_type "$c"
    [ "$status" -eq 0 ]
    [ "$output" = "$c" ]
  done
}

@test "normalize_diff_type lowercases and trims surrounding whitespace" {
  run normalize_diff_type "  SECURITY  "
  [ "$status" -eq 0 ]
  [ "$output" = "security" ]
}

@test "normalize_diff_type maps an unknown label to ambiguous" {
  run normalize_diff_type "correctness"
  [ "$status" -eq 0 ]
  [ "$output" = "ambiguous" ]
}

@test "normalize_diff_type maps an empty label to ambiguous" {
  run normalize_diff_type ""
  [ "$status" -eq 0 ]
  [ "$output" = "ambiguous" ]
}

# ---------------------------------------------------------------------------
# classify_triage_type — extracts `.type` from the triage JSON
# ---------------------------------------------------------------------------

@test "classify_triage_type extracts each known label from triage JSON" {
  local c
  for c in security logic performance style; do
    run classify_triage_type "{\"escalate\":true,\"risk\":\"HIGH\",\"type\":\"$c\"}"
    [ "$status" -eq 0 ]
    [ "$output" = "$c" ]
  done
}

@test "classify_triage_type yields ambiguous when the type field is absent" {
  run classify_triage_type '{"escalate":true,"risk":"MEDIUM","signals":[]}'
  [ "$status" -eq 0 ]
  [ "$output" = "ambiguous" ]
}

@test "classify_triage_type yields ambiguous on invalid / non-JSON input" {
  run classify_triage_type 'not json at all'
  [ "$status" -eq 0 ]
  [ "$output" = "ambiguous" ]
}

@test "classify_triage_type yields ambiguous when type is an unknown value" {
  run classify_triage_type '{"type":"refactor"}'
  [ "$status" -eq 0 ]
  [ "$output" = "ambiguous" ]
}

# ---------------------------------------------------------------------------
# resolve_deep_specialist — type -> specialist prompt, else fallback (AC #3/#4)
# ---------------------------------------------------------------------------

@test "resolve_deep_specialist routes each class to its registered specialist prompt" {
  declare -A expected=(
    [security]="prompts/deep-review-security.md"
    [logic]="prompts/deep-review-logic.md"
    [performance]="prompts/deep-review-performance.md"
    [style]="prompts/deep-review-style.md"
  )
  local c
  for c in security logic performance style; do
    run resolve_deep_specialist "$c" "$FALLBACK"
    [ "$status" -eq 0 ]
    [ "$output" = "${expected[$c]}" ]
    # The resolved specialist prompt must exist on disk.
    [ -f "$REPO_ROOT/$output" ]
  done
}

@test "resolve_deep_specialist falls back to deep-review.md for an ambiguous label (AC #4)" {
  run resolve_deep_specialist "ambiguous" "$FALLBACK"
  [ "$status" -eq 0 ]
  [ "$output" = "$FALLBACK" ]
}

@test "resolve_deep_specialist falls back for an unknown label (AC #4)" {
  run resolve_deep_specialist "correctness" "$FALLBACK"
  [ "$status" -eq 0 ]
  [ "$output" = "$FALLBACK" ]
}

@test "resolve_deep_specialist falls back when the type has no registry row (AC #4)" {
  # A registry with only pr_diff registered has no deep_specialist rows.
  local manifest="$BATS_TEST_TMPDIR/registry.tsv"
  printf '# schema_version: 99\n' > "$manifest"
  printf 'pr_diff\tprompts/triage.md,prompts/deep-review.md\tscripts/post-pr-review.sh\n' >> "$manifest"
  REVIEW_REGISTRY_MANIFEST="$manifest" run resolve_deep_specialist "security" "$FALLBACK"
  [ "$status" -eq 0 ]
  [ "$output" = "$FALLBACK" ]
}

@test "resolve_deep_specialist falls back when the registered specialist file is missing (AC #4)" {
  # Registry points a class at a nonexistent prompt file — must not route to it.
  local manifest="$BATS_TEST_TMPDIR/registry.tsv"
  printf '# schema_version: 99\n' > "$manifest"
  printf 'deep_specialist:logic\tprompts/does-not-exist.md\tscripts/post-pr-review.sh\n' >> "$manifest"
  REVIEW_REGISTRY_MANIFEST="$manifest" run resolve_deep_specialist "logic" "$FALLBACK"
  [ "$status" -eq 0 ]
  [ "$output" = "$FALLBACK" ]
}

# ---------------------------------------------------------------------------
# Registry rows — every deep_specialist:<type> resolves to an existing prompt
# via the shared review-registry.sh helper (AC #3: data-driven, not hardcoded).
# ---------------------------------------------------------------------------

@test "registry registers a specialist for every classifier class" {
  source "$REPO_ROOT/scripts/lib/review-registry.sh"
  local c prompt
  for c in security logic performance style; do
    run review_registry_lookup "deep_specialist:$c" rubric
    [ "$status" -eq 0 ]
    prompt="$output"
    [ -n "$prompt" ]
    [ -f "$REPO_ROOT/$prompt" ]
  done
}

@test "specialist registry rows do not disturb the pr_diff cascade (additive)" {
  source "$REPO_ROOT/scripts/lib/review-registry.sh"
  run review_registry_lookup pr_diff rubric
  [ "$status" -eq 0 ]
  [ "$output" = "prompts/triage.md,prompts/deep-review.md,prompts/synthesize.md" ]
}

# ---------------------------------------------------------------------------
# Cascade wiring — review-one-pr.sh drives the deep tier through the classifier
# (AC #1: classifier gates the deep prompt; AC #4: fallback is the rubric prompt)
# ---------------------------------------------------------------------------

@test "review-one-pr.sh sources the deep-specialist helper" {
  run grep -qE 'lib/deep-specialist\.sh' "$REPO_ROOT/scripts/review-one-pr.sh"
  [ "$status" -eq 0 ]
}

@test "review-one-pr.sh classifies the triage result and resolves a specialist prompt" {
  run grep -qE 'classify_triage_type[[:space:]]+"\$TRIAGE_RESULT"' "$REPO_ROOT/scripts/review-one-pr.sh"
  [ "$status" -eq 0 ]
  run grep -qE 'resolve_deep_specialist[[:space:]]+"\$TRIAGE_TYPE"[[:space:]]+"\$RUBRIC_DEEP_PROMPT"' "$REPO_ROOT/scripts/review-one-pr.sh"
  [ "$status" -eq 0 ]
}

@test "review-one-pr.sh runs the deep tier with the classifier-resolved prompt" {
  # The deep run_agentic call must use the resolved DEEP_TIER_PROMPT, not the raw
  # rubric prompt — that is what makes the classification gate the specialist.
  run grep -qE 'run_agentic[[:space:]]+"\$DEEP_TIER_PROMPT"[[:space:]]+"\$ENGINE_DEEP_MODEL"[[:space:]]+"deep"' "$REPO_ROOT/scripts/review-one-pr.sh"
  [ "$status" -eq 0 ]
}
