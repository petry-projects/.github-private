#!/usr/bin/env bats
# Tests for the model A/B dispatch helper (scripts/evals/model-ab-dispatch.sh).
#
# model-ab-dispatch.sh is the thin, testable wrapper the workflow_dispatch runner
# (.github/workflows/model-ab.yml, #1950) calls. It owns the two pieces of logic
# that must be exercised OFFLINE — before any token is spent — so a live CI run
# never wastes budget on a fat-fingered input:
#   * input validation / clamping: `runs` is clamped to the epic cost cap 1..3,
#     and every requested set must have an evals/<set>/holdout directory (else the
#     run fails FAST, before a single arm executes);
#   * retry policy: it re-runs model-ab.sh ONLY when the previous attempt was
#     classed infra (exit 2), up to `runs` attempts, and NEVER re-runs a scored
#     verdict (exit 0 accept / exit 1 regression) — a scored number is final.
#
# These tests drive it fully offline: model-ab.sh is replaced by a stub
# (MODEL_AB_CMD) whose per-invocation exit code is scripted, so accept / regression
# / infra-then-recover / infra-exhausted can all be simulated with no network —
# mirroring the DRY_RUN-offline discipline of tests/test_model_ab.bats.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DISPATCH="$ROOT/scripts/evals/model-ab-dispatch.sh"
  TMP="$(mktemp -d "$BATS_TEST_TMPDIR/model_ab_dispatch.XXXXXX")"
  [ -n "$TMP" ] && [ -d "$TMP" ] || return 1

  # Minimal held-out tree: only the holdout DIRECTORIES need exist for validation.
  mkdir -p "$TMP/evals/triage/holdout" "$TMP/evals/deep-review/holdout"

  # Scripted model-ab.sh stub. Emits one exit code per invocation from SEQ (a
  # colon-separated list; the last value repeats once exhausted) and records how
  # many times it was called in COUNTER, so a test can assert the retry count and
  # that a scored verdict is never re-run.
  COUNTER="$TMP/calls"
  : >"$COUNTER"
  EVALS_SEEN="$TMP/evals_seen"
  STUB="$TMP/model_ab_stub.sh"
  cat >"$STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
n="$(cat "$COUNTER" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$COUNTER"
# Record the EVALS_DIR the wrapper handed us so a test can assert validation and
# execution scored the SAME corpus (last write wins).
printf '%s' "${EVALS_DIR:-}" >"${EVALS_SEEN:-/dev/null}"
# Echo a JSON evidence blob so the wrapper's pass-through can be asserted.
printf '{"attempt":%s,"args":"%s","verdict":"stub"}\n' "$n" "$*"
IFS=: read -ra codes <<<"${SEQ:-0}"
idx=$((n - 1))
if [ "$idx" -ge "${#codes[@]}" ]; then idx=$((${#codes[@]} - 1)); fi
exit "${codes[idx]}"
SH
  chmod +x "$STUB"
  export COUNTER EVALS_SEEN
}

teardown() { rm -rf "$TMP"; }

_calls() { cat "$COUNTER"; }

# ── pure logic: clamp runs to the 1..3 cost cap ───────────────────────────────

@test "mad_clamp_runs clamps to the 1..3 epic cost cap and defaults to 1" {
  # shellcheck source=/dev/null
  source "$DISPATCH"
  [ "$(mad_clamp_runs 1)" = "1" ]
  [ "$(mad_clamp_runs 2)" = "2" ]
  [ "$(mad_clamp_runs 3)" = "3" ]
  [ "$(mad_clamp_runs 4)" = "3" ]     # above the cap -> clamped down to 3
  [ "$(mad_clamp_runs 99)" = "3" ]
  [ "$(mad_clamp_runs 0)" = "1" ]     # below the floor -> 1
  [ "$(mad_clamp_runs -5)" = "1" ]
  [ "$(mad_clamp_runs '')" = "1" ]    # empty -> default 1
  [ "$(mad_clamp_runs abc)" = "1" ]   # non-numeric -> default 1
  [ "$(mad_clamp_runs 2.5)" = "1" ]   # non-integer -> default 1
  # A digit-only value far beyond the 64-bit range must degrade to the cap, not
  # abort the shell on `$((10#$v))` overflow (#1952).
  [ "$(mad_clamp_runs 99999999999999999999999999999999)" = "3" ]
  [ "$(mad_clamp_runs 007)" = "3" ]   # leading zeros: decimal 7 (not octal) -> 3
  [ "$(mad_clamp_runs 000)" = "1" ]   # all-zero -> below floor -> 1
}

# ── pure logic: reject an unknown set ─────────────────────────────────────────

@test "mad_validate_sets accepts sets that have a holdout dir and rejects unknown ones" {
  # shellcheck source=/dev/null
  source "$DISPATCH"
  run mad_validate_sets "$TMP/evals" triage deep-review
  [ "$status" -eq 0 ]
  run mad_validate_sets "$TMP/evals" triage nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"nope"* ]]
  # an empty set list is rejected too
  run mad_validate_sets "$TMP/evals"
  [ "$status" -eq 1 ]
}

# ── fail fast: an unknown set never spends a token ────────────────────────────

@test "an unknown set is a hard error (::error::, exit 2) BEFORE any arm runs" {
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --candidate claude-opus-5-5 --incumbent claude-opus-4-8 \
      --sets "triage does-not-exist" --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
  [ "$(_calls)" = "" ] || [ "$(_calls)" = "0" ]   # model-ab.sh was never invoked
}

@test "runs clamp is enforced end-to-end: runs=9 collapses to at most 3 attempts" {
  MODEL_AB_CMD="bash $STUB" SEQ="2" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 9 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]              # infra every attempt -> final verdict infra
  [ "$(_calls)" -eq 3 ]            # clamped to the cost cap, not 9
}

@test "the validated evals_dir is forwarded to model-ab.sh (no validate/execute divergence)" {
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 0 ]
  # model-ab.sh reads EVALS_DIR from the env; the wrapper must hand it the SAME
  # dir it validated against, so execution scores the corpus we checked.
  [ "$(cat "$EVALS_SEEN")" = "$TMP/evals" ]
}

# ── retry policy: only infra (exit 2) is re-run ───────────────────────────────

@test "infra (exit 2) then accept: retried, and exits with the scored verdict 0" {
  # --separate-stderr: the retry ::warning:: goes to stderr; keep $output pure JSON.
  MODEL_AB_CMD="bash $STUB" SEQ="2:2:0" \
    run --separate-stderr bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 3 --evals-dir "$TMP/evals"
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 3 ]
  # the final (scored) evidence blob is passed through unchanged
  [ "$(jq -r '.attempt' <<<"$output")" = "3" ]
}

@test "a scored regression (exit 1) is NEVER re-run" {
  MODEL_AB_CMD="bash $STUB" SEQ="1:0:0" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 3 --evals-dir "$TMP/evals"
  [ "$status" -eq 1 ]              # regression verdict propagated
  [ "$(_calls)" -eq 1 ]            # stopped after the first scored arm
}

@test "a scored accept (exit 0) is NEVER re-run" {
  MODEL_AB_CMD="bash $STUB" SEQ="0:2:2" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 3 --evals-dir "$TMP/evals"
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 1 ]
}

@test "infra on every attempt exhausts at 'runs' attempts and exits 2" {
  MODEL_AB_CMD="bash $STUB" SEQ="2:2:2:2" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 3 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [ "$(_calls)" -eq 3 ]            # never exceeds runs
}

@test "runs=1 performs exactly one attempt even on infra (no retry)" {
  MODEL_AB_CMD="bash $STUB" SEQ="2:0" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [ "$(_calls)" -eq 1 ]
}

# ── pass-through + --out ──────────────────────────────────────────────────────

@test "the final evidence JSON is written to --out and to stdout" {
  OUT="$TMP/evidence.json"
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --candidate claude-opus-5-5 --incumbent claude-opus-4-8 \
      --sets "triage" --runs 1 --evals-dir "$TMP/evals" --out "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  [ "$(jq -r '.verdict' "$OUT")" = "stub" ]
  # model-ab.sh received candidate, incumbent, then the sets as positional args
  [[ "$(jq -r '.args' "$OUT")" == "claude-opus-5-5 claude-opus-4-8 triage" ]]
}

# ── usage errors ──────────────────────────────────────────────────────────────

@test "missing --candidate/--incumbent is a hard error (exit 2)" {
  MODEL_AB_CMD="bash $STUB" \
    run bash "$DISPATCH" --sets "triage" --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

# ── set-matrix bounding: dedup, cap, multiline, engine-compat ─────────────────

@test "a duplicate set is a hard error BEFORE any arm runs" {
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage triage" --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate set 'triage'"* ]]
  [ "$(_calls)" = "" ] || [ "$(_calls)" = "0" ]
}

@test "more sets than the cap is a hard error BEFORE any arm runs" {
  for n in $(seq 1 9); do mkdir -p "$TMP/evals/set$n/holdout"; done
  local many; many="$(printf 'set%d ' $(seq 1 9))"
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "$many" --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [[ "$output" == *"too many sets"* ]]
  [ "$(_calls)" = "" ] || [ "$(_calls)" = "0" ]
}

@test "multiline --sets is rejected BEFORE any arm runs" {
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets $'triage\ndeep-review' --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [[ "$output" == *"multiline"* ]]
  [ "$(_calls)" = "" ] || [ "$(_calls)" = "0" ]
}

@test "a persona-engine set is rejected (triage-chain pin cannot vary it)" {
  mkdir -p "$TMP/evals/persona-set/holdout"
  printf '{"mode":"llm-judge","engine":"persona"}\n' >"$TMP/evals/persona-set/scorer.json"
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage persona-set" --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [[ "$output" == *"incompatible set 'persona-set'"* ]]
  [ "$(_calls)" = "" ] || [ "$(_calls)" = "0" ]
}

@test "a triage-engine scorer.json is accepted by mad_incompatible_set" {
  # shellcheck source=/dev/null
  source "$DISPATCH"
  printf '{"mode":"deterministic","engine":"triage"}\n' >"$TMP/evals/triage/scorer.json"
  run mad_incompatible_set "$TMP/evals" triage
  [ "$status" -eq 0 ]
  # an absent scorer.json defaults to triage and is compatible
  run mad_incompatible_set "$TMP/evals" deep-review
  [ "$status" -eq 0 ]
}

# ── --validate-only: offline gate that spends no tokens ───────────────────────

@test "--validate-only passes on a valid dispatch and runs NO arm" {
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --validate-only --candidate c --incumbent i \
      --sets "triage deep-review" --runs 2 --evals-dir "$TMP/evals"
  [ "$status" -eq 0 ]
  [[ "$output" == *"inputs valid"* ]]
  [ "$(_calls)" = "" ] || [ "$(_calls)" = "0" ]
}

@test "--validate-only fails on an unknown set and runs NO arm" {
  MODEL_AB_CMD="bash $STUB" SEQ="0" \
    run bash "$DISPATCH" --validate-only --candidate c --incumbent i \
      --sets "triage nope" --runs 1 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
  [ "$(_calls)" = "" ] || [ "$(_calls)" = "0" ]
}

# ── retry policy: a deterministic hard error (exit 2, no JSON) is NOT retried ──

@test "exit 2 with NO evidence JSON (hard error) is not retried" {
  # A stub that always exits 2 but prints an ::error:: line (not JSON), mimicking
  # model-ab.sh's die(): the wrapper must NOT retry it even with runs=3 (#1952).
  local hardstub="$TMP/hard_stub.sh"
  cat >"$hardstub" <<'SH'
#!/usr/bin/env bash
n="$(cat "$COUNTER" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$COUNTER"
echo "::error::model-ab: simulated hard error"
exit 2
SH
  chmod +x "$hardstub"
  MODEL_AB_CMD="bash $hardstub" \
    run bash "$DISPATCH" --candidate c --incumbent i \
      --sets "triage deep-review" --runs 3 --evals-dir "$TMP/evals"
  [ "$status" -eq 2 ]
  [ "$(_calls)" -eq 1 ]            # hard error: single attempt, no retry
}
