#!/usr/bin/env bash
set -euo pipefail
# run-eval.sh — deterministic eval scorer for prompt-skills.
#
# Usage:
#   run-eval.sh <skill>
#
# Loads the skill's held-out cases (evals/<skill>/holdout/cases.jsonl), invokes the
# skill prompt once per case through the existing engine abstraction
# (scripts/engine.sh run_triage), parses the model's JSON decision, and compares
# it to the case's expected fields. Emits a single machine-readable JSON object
# to stdout containing a per-case `cases[]` array plus the aggregate score.
#
# Scoring is deterministic for triage: the model emits a JSON object; we parse it
# and compare `escalate` (and `risk`) to expected. A mismatch — or output that is
# not parseable as the expected JSON shape — counts as a case failure.
#
# Engine abstraction (AC #3): the per-case invocation goes through the engine
# layer, NOT a re-implemented model call. By default the engine command is
# `run_triage` (sourced from scripts/engine.sh, Haiku-tier, no tools, stdout
# capture). It is injectable via EVAL_ENGINE_CMD exactly as engine.sh lets
# REVIEW_ENGINE be overridden, so offline tests can drive a stub with no network.
#
# Env overrides:
#   EVAL_ENGINE_CMD   engine command invoked as `<cmd> <prompt_file>` (default: run_triage)
#   EVALS_DIR         held-out cases root (default: <repo>/evals); read-only
#   TOKEN_LOG_FILE    optional per-call token capture (honored by engine.sh; unset = zero overhead)
#
# Exit codes:
#   0  run completed, every case passed
#   1  run completed, at least one case failed
#   2  hard error (bad usage / missing prompt or cases file / missing tooling)
#
# Cases are read-only here — the scorer never writes evals/<skill>/holdout/cases.jsonl.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EVALS_DIR="${EVALS_DIR:-$REPO_ROOT/evals}"
EVAL_ENGINE_CMD="${EVAL_ENGINE_CMD:-run_triage}"

die() {
  # stdout (not stderr) so the reason is visible in workflow logs and capturable
  # by tests; the ::error:: prefix still renders as a GitHub annotation.
  echo "::error::eval scorer: $1"
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

skill="${1:-}"
[ -n "$skill" ] || die "usage: run-eval.sh <skill>"

cases_file="$EVALS_DIR/$skill/holdout/cases.jsonl"
prompt_file_base="$REPO_ROOT/prompts/$skill.md"
[ -f "$cases_file" ] || die "no cases for skill '$skill' (expected $cases_file)"
[ -f "$prompt_file_base" ] || die "no skill prompt for '$skill' (expected $prompt_file_base)"

# Source the engine abstraction so the default EVAL_ENGINE_CMD (run_triage) is
# defined. engine.sh prints an init line on load — send it to stderr so stdout
# stays a clean JSON document. When EVAL_ENGINE_CMD is overridden with a stub,
# run_triage simply goes unused.
# shellcheck source=../engine.sh
source "$REPO_ROOT/scripts/engine.sh" >&2

results="$(mktemp)"
work_prompt="$(mktemp)"
trap 'rm -f "$results" "$work_prompt"' EXIT

# score_case <expected_escalate> <expected_risk> <raw_output> <case_id>
# Emits one compact result JSON object to stdout. Parses the model output; a
# non-JSON-object output yields a null actual decision (an automatic failure).
score_case() {
  local exp_esc="$1" exp_risk="$2" raw="$3" cid="$4"
  local actual pass

  # Parse only if the raw output is a single JSON object exposing the decision
  # fields. Anything else (prose, fences, partial JSON) -> null actual -> fail.
  actual="$(jq -ce 'if type=="object" and has("escalate") and has("risk")
                    then {escalate, risk} else empty end' <<<"$raw" 2>/dev/null || true)"

  if [ -z "$actual" ]; then
    pass=false
    actual=null
  elif [ "$(jq -r '.escalate' <<<"$actual")" = "$exp_esc" ] \
       && [ "$(jq -r '.risk' <<<"$actual")" = "$exp_risk" ]; then
    pass=true
  else
    pass=false
  fi

  jq -cn --arg id "$cid" --argjson pass "$pass" \
        --argjson exp_esc "$exp_esc" --arg exp_risk "$exp_risk" \
        --argjson actual "$actual" \
        '{id:$id, pass:$pass, expected:{escalate:$exp_esc, risk:$exp_risk}, actual:$actual}'
}

while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue   # tolerate blank separator lines

  cid="$(jq -r '.id' <<<"$line")"
  input="$(jq -r '.input' <<<"$line")"
  exp_esc="$(jq -r '.expected.escalate' <<<"$line")"
  exp_risk="$(jq -r '.expected.risk' <<<"$line")"

  # Build the per-case prompt: the skill markdown with the case input inlined
  # under the section triage.md reads ("## Pre-fetched PR context").
  {
    cat "$prompt_file_base"
    printf '\n\n## Pre-fetched PR context\n\n%s\n' "$input"
  } >"$work_prompt"

  # Invoke the skill through the engine command (default run_triage). Capture
  # stdout (the model decision); engine diagnostics flow to our stderr. A
  # non-zero engine exit leaves $raw empty -> scored as a failure.
  raw=""
  raw="$("$EVAL_ENGINE_CMD" "$work_prompt")" || raw=""

  score_case "$exp_esc" "$exp_risk" "$raw" "$cid" >>"$results"
done <"$cases_file"

# Assemble the aggregate report. score = passed/total (0 when there are no cases).
jq -s --arg skill "$skill" '
  {
    skill:  $skill,
    total:  length,
    passed: (map(select(.pass)) | length),
    failed: (map(select(.pass | not)) | length),
    score:  (if length == 0 then 0 else ((map(select(.pass)) | length) / length) end),
    cases:  .
  }' "$results"

failed="$(jq -s 'map(select(.pass | not)) | length' "$results")"
[ "$failed" -eq 0 ]
