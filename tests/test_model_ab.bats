#!/usr/bin/env bats
# Tests for the model A/B non-regression comparator (scripts/evals/model-ab.sh).
#
# model-ab.sh scores a CANDIDATE model against an INCUMBENT model on one or more
# held-out sets by driving scripts/evals/run-eval.sh once per (model, set) arm,
# pinning ONLY the generator model per arm (the judge is held fixed), then reading
# the two aggregate scores directly and applying a `>=` non-regression bar (NOT
# gate.sh's strict `>`). It is the Phase-1 evidence producer for the Sonnet 5 vs
# Sonnet 4.6 go/no-go (#1097, epic #1095).
#
# These tests drive it fully offline: the generator/judge engines are stubs whose
# behavior keys off the pinned model id (CLAUDE_TRIAGE_MODEL_CHAIN), so we can
# simulate a non-regression, a regression, a tie, and an infra throttle with no
# network — mirroring the DRY_RUN-offline discipline of tests/test_skill_evals.bats.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AB="$ROOT/scripts/evals/model-ab.sh"
  TMP="$(mktemp -d "$BATS_TEST_TMPDIR/model_ab_test.XXXXXX")"
  JUDGE_MODEL_LOG="$TMP/judge_models.log"
  export JUDGE_MODEL_LOG

  # ---- triage (deterministic) holdout fixture: one approve, one escalate -------
  mkdir -p "$TMP/evals/triage/holdout"
  cat >"$TMP/evals/triage/holdout/cases.jsonl" <<'JSONL'
{"id": "case-approve", "input": "MARKER_APPROVE\nTitle: Fix docs typo\n\nDocs-only change.", "expected": {"escalate": false, "risk": "LOW"}}
{"id": "case-escalate", "input": "MARKER_ESCALATE\nTitle: Rotate auth token\n\nTouches **/auth/** and secrets.", "expected": {"escalate": true, "risk": "HIGH"}}
JSONL

  # ---- deep-review (llm-judge) holdout fixture --------------------------------
  mkdir -p "$TMP/evals/deep-review/holdout"
  cat >"$TMP/evals/deep-review/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "judge.md", "pass_threshold": 0.7}
JSON
  cat >"$TMP/evals/judge.md" <<'MD'
# Eval judge
Score the candidate deep-review output against the expected reference.
Emit a single JSON object: {"score": <0..1>, "reason": "..."}.
MD
  cat >"$TMP/evals/deep-review/holdout/cases.jsonl" <<'JSONL'
{"id": "deep-approve", "input": "MARKER_APPROVE\nTitle: Fix docs typo\n\nDocs-only change.", "expected": {"decision": "approve", "risk": "LOW", "key_findings": []}}
{"id": "deep-escalate", "input": "MARKER_ESCALATE\nTitle: Add user search\n\nSQL built by string concatenation.", "expected": {"decision": "escalate", "risk": "HIGH", "key_findings": ["sql injection"]}}
JSONL

  # Generator stub (EVAL_ENGINE_CMD). Correctness keys off the pinned generator
  # model in CLAUDE_TRIAGE_MODEL_CHAIN so a MODEL A/B is simulated offline:
  #   *perfect*  -> both cases correct (triage 1.0 / deep-review high)
  #   *half*     -> approve correct only (triage 0.5)
  #   *throttle* -> exits non-zero (infra: every model in the chain "throttled")
  # For deep-review it embeds its own model id into the candidate output so the
  # judge stub can grade generator quality — proving the generator model varied.
  GEN_STUB="$TMP/gen_stub.sh"
  cat >"$GEN_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="${1:-}"
chain="${CLAUDE_TRIAGE_MODEL_CHAIN:-UNPINNED}"
case "$chain" in
  *throttle*) echo "::warning::[claude] all models throttled (rc=1)" >&2; exit 1 ;;
esac
if grep -q MARKER_APPROVE "$prompt"; then
  # deep-review approve case carries the generator model token for the judge.
  if grep -q "deep-review output" "$prompt" 2>/dev/null; then :; fi
  echo "{\"escalate\": false, \"risk\": \"LOW\", \"decision\": \"approve\", \"gen_model\": \"$chain\"}"
elif grep -q MARKER_ESCALATE "$prompt"; then
  if [[ "$chain" == *perfect* ]]; then
    echo "{\"escalate\": true, \"risk\": \"HIGH\", \"decision\": \"escalate\", \"gen_model\": \"$chain\"}"
  else
    echo "{\"escalate\": false, \"risk\": \"LOW\", \"decision\": \"approve\", \"gen_model\": \"$chain\"}"
  fi
else
  echo 'no marker found'
fi
SH
  chmod +x "$GEN_STUB"

  # Judge stub (base EVAL_JUDGE_CMD). Records the model the judge ran under so the
  # test can assert it was HELD FIXED across both arms (no generator confound),
  # and grades candidate quality off the generator model token embedded above.
  JUDGE_STUB="$TMP/judge_stub.sh"
  cat >"$JUDGE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="${1:-}"
printf '%s\n' "${CLAUDE_TRIAGE_MODEL_CHAIN:-UNPINNED}" >>"$JUDGE_MODEL_LOG"
if grep -q 'perfect' "$prompt"; then
  echo '{"score": 1, "reason": "matches"}'
else
  echo '{"score": 0.3, "reason": "weak"}'
fi
SH
  chmod +x "$JUDGE_STUB"
}

teardown() { rm -rf "$TMP"; }

# --- non-regression (>=) on both sets: ACCEPT ---------------------------------

@test "candidate >= incumbent on both sets is ACCEPTED (exit 0)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-perfect model-sonnet46-perfect triage deep-review
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict'  <<<"$output")" = "accept" ]
  [ "$(jq -r '.accepted' <<<"$output")" = "true" ]
  # Per-set evidence for BOTH models is present.
  tri="$(jq -c '.sets[] | select(.skill=="triage")' <<<"$output")"
  [ "$(jq -r '.candidate_score' <<<"$tri")" = "1" ]
  [ "$(jq -r '.incumbent_score' <<<"$tri")" = "1" ]
  [ "$(jq -r '.non_regression' <<<"$tri")" = "true" ]
}

@test "evidence JSON records the candidate, incumbent, and judge model ids" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-perfect model-sonnet46-perfect triage
  [ "$status" -eq 0 ]
  [ "$(jq -r '.candidate_model' <<<"$output")" = "model-sonnet5-perfect" ]
  [ "$(jq -r '.incumbent_model' <<<"$output")" = "model-sonnet46-perfect" ]
  [ "$(jq -r '.judge_model'     <<<"$output")" = "claude-sonnet-4-6" ]
}

# --- regression on one set: BLOCKING -----------------------------------------

@test "a candidate that regresses on triage is a BLOCKING regression (exit 1)" {
  # candidate=half (0.5) vs incumbent=perfect (1.0) on triage -> regression.
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-half model-sonnet46-perfect triage
  [ "$status" -eq 1 ]
  [ "$(jq -r '.verdict'  <<<"$output")" = "regression" ]
  [ "$(jq -r '.accepted' <<<"$output")" = "false" ]
  tri="$(jq -c '.sets[] | select(.skill=="triage")' <<<"$output")"
  [ "$(jq -r '.candidate_score' <<<"$tri")" = "0.5" ]
  [ "$(jq -r '.incumbent_score' <<<"$tri")" = "1" ]
  [ "$(jq -r '.non_regression' <<<"$tri")" = "false" ]
  [ "$(jq -r '.outcome' <<<"$tri")" = "regression" ]
}

# --- a TIE is ACCEPTED: >= not strict '>' ------------------------------------

@test "a TIE is ACCEPTED — the bar is '>=' non-regression, not gate.sh's strict '>'" {
  # Both arms score 0.5 on triage: a strict '>' gate would reject; '>=' accepts.
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-half model-sonnet46-half triage
  [ "$status" -eq 0 ]
  [ "$(jq -r '.accepted' <<<"$output")" = "true" ]
  tri="$(jq -c '.sets[] | select(.skill=="triage")' <<<"$output")"
  [ "$(jq -r '.candidate_score' <<<"$tri")" = "$(jq -r '.incumbent_score' <<<"$tri")" ]
  [ "$(jq -r '.non_regression' <<<"$tri")" = "true" ]
}

# --- infra throttle is un-scored, NOT a regression (#920 semantics) -----------

@test "a throttled arm is INFRA/un-scored -> exit 2, never counted as a regression" {
  # candidate throttles (run-eval exits 2); incumbent scores fine. The set is
  # un-scored: it must NOT be recorded as a Sonnet-5 regression.
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-throttle model-sonnet46-perfect triage
  [ "$status" -eq 2 ]
  [ "$(jq -r '.verdict' <<<"$output")" = "infra" ]
  tri="$(jq -c '.sets[] | select(.skill=="triage")' <<<"$output")"
  [ "$(jq -r '.outcome' <<<"$tri")" = "infra" ]
  [ "$(jq -r '.candidate_scored' <<<"$tri")" = "false" ]
  [ "$(jq -r '.candidate_rc' <<<"$tri")" = "2" ]
  # It is explicitly NOT a regression.
  [ "$(jq -r '.outcome' <<<"$tri")" != "regression" ]
}

# --- deep-review: judge held fixed while generator model varies ---------------

@test "deep-review: the judge model is HELD FIXED across both arms while the generator varies" {
  : >"$JUDGE_MODEL_LOG"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-perfect model-sonnet46-perfect deep-review
  [ "$status" -eq 0 ]
  # The judge ran on EVERY case of BOTH arms — always on the fixed judge model,
  # never on either generator arm's model. This is the confound control.
  [ "$(sort -u "$JUDGE_MODEL_LOG")" = "claude-sonnet-4-6" ]
  # And it actually ran (4 case-judgements: 2 cases x 2 arms).
  [ "$(wc -l <"$JUDGE_MODEL_LOG")" -eq 4 ]
}

# --- held-out immutability -----------------------------------------------------

@test "held-out artifacts (cases, judge, scorer) are byte-unchanged after a run" {
  before="$(cat "$TMP/evals/triage/holdout/cases.jsonl" \
                "$TMP/evals/deep-review/holdout/cases.jsonl" \
                "$TMP/evals/deep-review/scorer.json" \
                "$TMP/evals/judge.md" | sha256sum)"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-perfect model-sonnet46-perfect triage deep-review
  [ "$status" -eq 0 ]
  after="$(cat "$TMP/evals/triage/holdout/cases.jsonl" \
               "$TMP/evals/deep-review/holdout/cases.jsonl" \
               "$TMP/evals/deep-review/scorer.json" \
               "$TMP/evals/judge.md" | sha256sum)"
  [ "$before" = "$after" ]
}

@test "a run that mutates a held-out artifact is a hard error (::error::, exit 2)" {
  # Tamper stub: mutates a tracked read-only artifact (the shared judge prompt)
  # mid-run. The comparator's immutability guard must detect it and hard-fail.
  # (Tampering the *cases* file that run-eval is iterating would instead drive a
  # read-loop runaway — a different failure mode — so we perturb judge.md.)
  TAMPER="$TMP/tamper.sh"
  cat >"$TAMPER" <<SH
#!/usr/bin/env bash
set -euo pipefail
echo 'tampered' >>"$TMP/evals/judge.md"
echo '{"escalate": false, "risk": "LOW"}'
SH
  chmod +x "$TAMPER"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$TAMPER" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run bash "$AB" model-a model-b triage
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

# --- usage / hard errors -------------------------------------------------------

@test "missing model arguments is a hard error (::error::, exit 2)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    run bash "$AB" model-only-one
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

@test "default skill set is triage + deep-review when no skills are named" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GEN_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    AB_JUDGE_MODEL="claude-sonnet-4-6" \
    run --separate-stderr bash "$AB" model-sonnet5-perfect model-sonnet46-perfect
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.sets[].skill] | sort | join(",")' <<<"$output")" = "deep-review,triage" ]
}
