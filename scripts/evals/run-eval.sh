#!/usr/bin/env bash
set -euo pipefail
# run-eval.sh — held-out eval scorer for prompt-skills.
#
# Usage:
#   run-eval.sh <skill>
#
# Loads the skill's held-out cases (evals/<skill>/holdout/cases.jsonl), invokes the
# skill prompt once per case through the existing engine abstraction
# (scripts/engine.sh run_triage), then scores the output. Emits a single
# machine-readable JSON object to stdout containing a per-case `cases[]` array
# plus the aggregate score.
#
# Scorer mode is selected PER SKILL from an optional `evals/<skill>/scorer.json`
# config — never by branching on the skill name in the comparator core. Two modes:
#
#   deterministic (default; triage)
#     The model emits a JSON object; we parse it and compare `escalate` (and
#     `risk`) to the case's expected fields. A mismatch — or output that is not
#     parseable as the expected JSON shape — counts as a case failure.
#
#   llm-judge (deep-review)
#     deep-review emits a findings array plus a decision/risk (not a single
#     boolean), so equality cannot score it. The skill output is graded against
#     the case's expected reference by a versioned, CODEOWNER-gated judge prompt
#     (evals/<judge_prompt>) running on the Haiku-tier triage model. The judge
#     emits a numeric per-case score in [0,1]; the case passes when that score
#     meets `pass_threshold` (default 0.7).
#
# scorer.json schema (all fields optional unless noted):
#   { "mode": "deterministic" | "llm-judge",
#     "judge_prompt": "<path relative to EVALS_DIR>",   # required for llm-judge
#     "pass_threshold": <number in [0,1]> }             # llm-judge only (default 0.7)
# Absent file => deterministic mode (keeps existing skills unchanged).
#
# Engine abstraction (AC #3): every model invocation goes through the engine
# layer, NOT a re-implemented model call. By default the skill command is
# `run_triage` and the judge command is also `run_triage` (sourced from
# scripts/engine.sh, Haiku-tier, no tools, stdout capture). Both are injectable
# (EVAL_ENGINE_CMD / EVAL_JUDGE_CMD) exactly as engine.sh lets REVIEW_ENGINE be
# overridden, so offline tests can drive stubs with no network.
#
# Env overrides:
#   EVAL_ENGINE_CMD   skill-under-test command, invoked as `<cmd> <prompt_file>` (default: run_triage)
#   EVAL_JUDGE_CMD    llm-judge command, invoked as `<cmd> <prompt_file>` (default: run_triage)
#   SKILL_PROMPT_FILE skill markdown to score (default: prompts/<skill>.md). The
#                     strict-improvement gate (#586) sets this to an incumbent or
#                     candidate file to score either against the same held-out set.
#   EVALS_DIR         held-out cases root (default: <repo>/evals); read-only
#   TOKEN_LOG_FILE    optional per-call token capture (honored by engine.sh; unset = zero overhead)
#
# Exit codes:
#   0  run completed, every case passed
#   1  run completed, at least one case failed on QUALITY (a genuine regression)
#   2  hard error — bad usage / missing prompt or cases file / missing tooling,
#      OR an all-infra run where the skill was never actually scored (see below)
#
# Infra failure vs. quality regression (#920): each case records the engine's
# exit status (engine_rc). A failing case whose engine call exited NON-ZERO is an
# INFRA failure (e.g. every model in engine.sh's fallback chain throttled) — the
# model never answered, so there is no answer to call right or wrong. A failing
# case whose engine call exited ZERO is a QUALITY miss (the model answered, but
# the output was wrong or unparseable). The aggregate exit code, when >=1 case
# fails, is:
#   - every failing case is an infra failure (no quality miss anywhere) -> 2
#     (outcome=error). The held-out set is currently UN-scored; a transient
#     throttle must NOT open a false held-out regression tracker.
#   - otherwise (>=1 quality miss) -> 1 (regression), unchanged.
# A MIXED run with some cases answered (pass) and the rest throttled therefore
# exits 2: there is no parseable-but-wrong answer to call a regression.
#
# Cases are read-only here — the scorer never writes evals/<skill>/holdout/cases.jsonl.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EVALS_DIR="${EVALS_DIR:-$REPO_ROOT/evals}"
# EVAL_PROMPTS_DIR (not PROMPTS_DIR — that name is already used by the dev-lead
# runtime for an unrelated path) overrides the prompt root, mirroring EVALS_DIR,
# so offline tests can point it at a fixture tree.
EVAL_PROMPTS_DIR="${EVAL_PROMPTS_DIR:-$REPO_ROOT/prompts}"
EVAL_ENGINE_CMD="${EVAL_ENGINE_CMD:-run_triage}"
EVAL_JUDGE_CMD="${EVAL_JUDGE_CMD:-run_triage}"

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
# The skill markdown defaults to prompts/<skill>.md, but the strict-improvement
# gate (#586) scores an arbitrary incumbent/candidate file against the SAME
# held-out set — so SKILL_PROMPT_FILE overrides which file is scored while the
# cases stay fixed. Held-out cases remain read-only regardless of the override.
#
# Role-generic resolution (#1630, AC #4): personas keep their prompt at
# prompts/<role>/advisory.md, not prompts/<role>.md, so the shared harness scores
# ANY persona eval tree by falling back to the advisory prompt when the flat
# prompts/<role>.md is absent. EVAL_PROMPTS_DIR overrides the prompt root the same way
# EVALS_DIR overrides the cases root, keeping offline tests network-free.
if [ -n "${SKILL_PROMPT_FILE:-}" ]; then
  prompt_file_base="$SKILL_PROMPT_FILE"
else
  prompt_file_base="$EVAL_PROMPTS_DIR/$skill.md"
  if [ ! -f "$prompt_file_base" ] && [ -f "$EVAL_PROMPTS_DIR/$skill/advisory.md" ]; then
    prompt_file_base="$EVAL_PROMPTS_DIR/$skill/advisory.md"
  fi
fi
[ -f "$cases_file" ] || die "no cases for skill '$skill' (expected $cases_file)"
[ -f "$prompt_file_base" ] || die "no skill prompt for '$skill' (expected $EVAL_PROMPTS_DIR/$skill.md or $EVAL_PROMPTS_DIR/$skill/advisory.md)"

# Resolve the per-skill scorer mode from an optional config. This is the only
# place the mode is decided: the comparator core below dispatches on $SCORER_MODE,
# never on the skill name, so a third skill needs only a scorer.json — no edits
# here. Absent config => deterministic (back-compat for triage and friends).
scorer_config="$EVALS_DIR/$skill/scorer.json"
SCORER_MODE="deterministic"
JUDGE_PROMPT_FILE=""
PASS_THRESHOLD="0.7"
if [ -f "$scorer_config" ]; then
  SCORER_MODE="$(jq -r '.mode // "deterministic"' "$scorer_config")"
fi
case "$SCORER_MODE" in
  deterministic) ;;
  llm-judge)
    judge_rel="$(jq -r '.judge_prompt // ""' "$scorer_config")"
    [ -n "$judge_rel" ] || die "scorer.json for '$skill' selects llm-judge but sets no judge_prompt"
    JUDGE_PROMPT_FILE="$EVALS_DIR/$judge_rel"
    [ -f "$JUDGE_PROMPT_FILE" ] || die "judge prompt not found for '$skill' (expected $JUDGE_PROMPT_FILE)"
    PASS_THRESHOLD="$(jq -r '.pass_threshold // 0.7' "$scorer_config")"
    ;;
  *) die "unknown scorer mode '$SCORER_MODE' for skill '$skill' (expected: deterministic, llm-judge)" ;;
esac

# Source the engine abstraction so the default EVAL_ENGINE_CMD (run_triage) is
# defined. engine.sh prints an init line on load — send it to stderr so stdout
# stays a clean JSON document. When EVAL_ENGINE_CMD is overridden with a stub,
# run_triage simply goes unused.
# shellcheck source=../engine.sh
source "$REPO_ROOT/scripts/engine.sh" >&2

results="$(mktemp)"
work_prompt="$(mktemp)"
work_judge="$(mktemp)"
trap 'rm -f "$results" "$work_prompt" "$work_judge"' EXIT

# extract_json <raw> — strip markdown code-fence lines so a fenced (```json … ```)
# or lightly wrapped JSON payload parses as bare JSON. Live Haiku-tier models
# routinely fence their output despite a "no fences" instruction, which the strict
# jq parse below would otherwise reject — a null actual for EVERY case (the triage
# 0/5 production failure, #762). Shared by both scorer modes so they tolerate
# output identically. `|| true` keeps an all-fence/empty input (grep selects no
# lines, exit 1) from tripping `set -e`.
extract_json() { grep -v $'^[[:space:]]*\x60\x60\x60' <<<"$1" || true; }

# score_deterministic <expected_json> <raw_output> <case_id> <engine_rc>
# Equality scorer (triage). Parses the model output; a non-JSON-object output
# yields a null actual decision (an automatic failure). Every result carries a
# numeric `score` (1 pass / 0 fail) plus the engine exit status `engine_rc` (so
# an all-infra run can be told apart from a quality regression, #920) so the
# report shape matches the judge mode.
score_deterministic() {
  if [ "$#" -lt 3 ]; then
    die "score_deterministic requires expected, raw, and cid arguments"
  fi
  local expected="$1" raw="$2" cid="$3" eng_rc="${4:-0}"
  local exp_esc exp_risk actual pass score cleaned raw_excerpt=""
  exp_esc="$(jq -r '.escalate' <<<"$expected")"
  exp_risk="$(jq -r '.risk' <<<"$expected")"

  # Tolerate markdown-fenced output (strip fences), then parse only if the result
  # is a single JSON object exposing the decision fields. Anything else (prose,
  # no JSON object, partial JSON) -> null actual -> fail.
  cleaned="$(extract_json "$raw")"
  actual="$(jq -cse '
      if length==1
         and (.[0]|type=="object" and has("escalate") and has("risk"))
      then .[0] | {escalate, risk}
      else empty
      end
    ' <<<"$cleaned" 2>/dev/null || true)"

  if [ -z "$actual" ]; then
    pass=false
    actual=null
    # Capture a short single-line excerpt of the unparseable output so a blind
    # null-everywhere failure (engine/format drift) is diagnosable from the
    # eval-health report instead of needing the (undownloadable) artifact.
    raw_excerpt="${raw//[$'\r\n']/ }"
    raw_excerpt="${raw_excerpt:0:160}"
  elif [ "$(jq -r '.escalate' <<<"$actual")" = "$exp_esc" ] \
       && [ "$(jq -r '.risk' <<<"$actual")" = "$exp_risk" ]; then
    pass=true
  else
    pass=false
  fi
  [ "$pass" = true ] && score=1 || score=0

  # raw_excerpt is attached ONLY when the output failed to parse (actual=null), so
  # passing/mismatch cases keep the lean shape the report and tests expect.
  jq -cn --arg id "$cid" --argjson pass "$pass" --argjson score "$score" \
        --argjson engine_rc "$eng_rc" \
        --argjson exp_esc "$exp_esc" --arg exp_risk "$exp_risk" \
        --argjson actual "$actual" --arg raw_excerpt "$raw_excerpt" \
        '{id:$id, score:$score, pass:$pass, engine_rc:$engine_rc, expected:{escalate:$exp_esc, risk:$exp_risk}, actual:$actual}
         + (if $raw_excerpt == "" then {} else {raw_excerpt: $raw_excerpt} end)'
}

# score_llm_judge <expected_json> <raw_output> <case_id>
# Grades non-deterministic output (deep-review) with the versioned judge prompt
# on the Haiku-tier model. Assembles a judge prompt carrying the judge rubric,
# the case's expected reference, and the candidate skill output, invokes the
# judge engine (default run_triage), and parses its numeric `score`. Judge output
# that is not a JSON object with a numeric `score` scores 0 (an automatic failure).
score_llm_judge() {
  if [ "$#" -lt 3 ]; then
    die "score_llm_judge requires expected, candidate, and cid arguments"
  fi
  local expected="$1" candidate="$2" cid="$3" eng_rc="${4:-0}"
  local judge_raw judge_obj score pass

  {
    cat "$JUDGE_PROMPT_FILE"
    printf '\n\n## Expected reference\n\n```json\n%s\n```\n' "$expected"
    printf '\n## Candidate output (to score)\n\n```\n%s\n```\n' "$candidate"
  } >"$work_judge"

  judge_raw=""
  judge_raw="$("$EVAL_JUDGE_CMD" "$work_judge")" || judge_raw=""

  # Strip markdown code blocks if the model wrapped its JSON response in them,
  # then accept only a single JSON object with a numeric score. A number outside
  # [0,1] is clamped; anything unparseable -> null judge -> score 0 -> fail.
  local cleaned_raw
  cleaned_raw="$(extract_json "$judge_raw")"
  judge_obj="$(jq -cse '
      if length==1 and (.[0]|type=="object" and (.score|type=="number"))
      then (.[0] | {score: ([[.score,0]|max,1]|min), reason: (.reason // null)})
      else empty
      end
    ' <<<"$cleaned_raw" 2>/dev/null || true)"

  if [ -z "$judge_obj" ]; then
    judge_obj=null
    score=0
    pass=false
  else
    score="$(jq -r '.score' <<<"$judge_obj")"
    pass="$(jq -n --argjson s "$score" --argjson t "$PASS_THRESHOLD" '$s >= $t')"
  fi

  jq -cn --arg id "$cid" --argjson score "$score" --argjson pass "$pass" \
        --argjson engine_rc "$eng_rc" \
        --argjson expected "$expected" --argjson judge "$judge_obj" \
        --arg candidate "$candidate" \
        '{id:$id, score:$score, pass:$pass, engine_rc:$engine_rc, expected:$expected, judge:$judge, candidate:$candidate}'
}

while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue   # tolerate blank separator lines

  cid="$(jq -r '.id' <<<"$line")"
  input="$(jq -r '.input' <<<"$line")"
  expected="$(jq -c '.expected' <<<"$line")"

  # Build the per-case prompt: the skill markdown with the case input inlined
  # under the section the skill reads ("## Pre-fetched PR context").
  {
    cat "$prompt_file_base"
    printf '\n\n## Pre-fetched PR context\n\n%s\n' "$input"
  } >"$work_prompt"

  # Invoke the skill through the engine command (default run_triage). Capture
  # stdout (the model decision); engine diagnostics flow to our stderr. Preserve
  # the engine's exit status (eng_rc): a NON-ZERO exit means the call failed for
  # infra reasons (e.g. every model in the fallback chain throttled) — the only
  # signal that distinguishes a throttle from a model that answered wrong (#920).
  raw=""; eng_rc=0
  raw="$("$EVAL_ENGINE_CMD" "$work_prompt")" || eng_rc=$?

  # Dispatch on the per-skill scorer mode — never on the skill name. eng_rc is
  # threaded through so each case result records whether the engine actually ran.
  case "$SCORER_MODE" in
    deterministic) score_deterministic "$expected" "$raw" "$cid" "$eng_rc" >>"$results" ;;
    llm-judge)     score_llm_judge     "$expected" "$raw" "$cid" "$eng_rc" >>"$results" ;;
  esac
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

# Decide the exit code. Classify failing cases as infra (engine exited non-zero —
# throttle/outage, the model never answered) vs. quality (engine exited zero but
# the answer was wrong/unparseable). If EVERY failing case is infra, the skill
# was never actually scored: exit 2 -> outcome=error, so a transient throttle
# cannot open a false held-out regression (#920). Any quality miss keeps exit 1.
failed="$(jq -s 'map(select(.pass | not)) | length' "$results")"
if [ "$failed" -eq 0 ]; then
  exit 0
fi
quality_failed="$(jq -s 'map(select((.pass | not) and ((.engine_rc // 0) == 0))) | length' "$results")"
if [ "$quality_failed" -eq 0 ]; then
  exit 2
fi
exit 1
