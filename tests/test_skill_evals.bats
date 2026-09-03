#!/usr/bin/env bats
# Tests for the deterministic eval scorer (scripts/evals/run-eval.sh).
#
# The scorer invokes the skill through scripts/engine.sh's run_triage by default,
# but accepts an EVAL_ENGINE_CMD override so these tests drive it against a stub
# engine + fixture cases with NO network — mirroring the DRY_RUN-offline
# discipline of tests/test_initiative_planner.bats.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCORER="$ROOT/scripts/evals/run-eval.sh"
  TMP="$(mktemp -d)"

  # Fixture held-out set: one approve case, one escalate case. Each input carries
  # a unique marker so the stub engine can return a deterministic answer per case.
  mkdir -p "$TMP/evals/triage/holdout"
  cat >"$TMP/evals/triage/holdout/cases.jsonl" <<'JSONL'
{"id": "case-approve", "input": "MARKER_APPROVE\nTitle: Fix docs typo\n\nDocs-only change, no high-risk files.", "expected": {"escalate": false, "risk": "LOW"}}
{"id": "case-escalate", "input": "MARKER_ESCALATE\nTitle: Rotate auth token\n\nTouches **/auth/** and secrets.", "expected": {"escalate": true, "risk": "HIGH"}}
JSONL

  # Stub engine: takes a prompt file ($1), greps for the case marker, emits the
  # CORRECT triage JSON for each fixture case. run_triage's contract is
  # `run_triage <prompt_file>` writing the model's stdout — the stub matches it.
  STUB_OK="$TMP/stub_ok.sh"
  cat >"$STUB_OK" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q MARKER_APPROVE "$prompt"; then
  echo '{"escalate": false, "risk": "LOW", "signals": [], "summary": "docs only"}'
elif grep -q MARKER_ESCALATE "$prompt"; then
  echo '{"escalate": true, "risk": "HIGH", "signals": ["auth"], "summary": "auth/secrets touched"}'
else
  echo 'no marker found'
fi
SH
  chmod +x "$STUB_OK"

  # Stub engine that always approves — wrong for the escalate case.
  STUB_WRONG="$TMP/stub_wrong.sh"
  cat >"$STUB_WRONG" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo '{"escalate": false, "risk": "LOW", "signals": [], "summary": "always approve"}'
SH
  chmod +x "$STUB_WRONG"

  # Stub engine that emits non-JSON prose.
  STUB_PROSE="$TMP/stub_prose.sh"
  cat >"$STUB_PROSE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 'This PR looks fine to me, I would approve it.'
SH
  chmod +x "$STUB_PROSE"

  # Stub engine that always THROTTLES: exits non-zero after emitting no parseable
  # output — mimics every model in engine.sh's fallback chain being throttled
  # (#920). The non-zero EXIT is the infra signal the scorer must read so a
  # transient outage scores as an infra error (exit 2), not a regression.
  STUB_THROTTLE="$TMP/stub_throttle.sh"
  cat >"$STUB_THROTTLE" <<'SH'
#!/usr/bin/env bash
echo '::warning::[claude] all models throttled (rc=1)' >&2
exit 1
SH
  chmod +x "$STUB_THROTTLE"

  # Stub engine for a MIXED run: answers the approve case correctly (rc 0) but
  # throttles the escalate case (rc!=0, no output). Used to pin the deterministic
  # rule for a partially-throttled run.
  STUB_MIXED="$TMP/stub_mixed.sh"
  cat >"$STUB_MIXED" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q MARKER_APPROVE "$prompt"; then
  echo '{"escalate": false, "risk": "LOW", "signals": [], "summary": "docs only"}'
  exit 0
fi
echo '::warning::[claude] all models throttled (rc=1)' >&2
exit 1
SH
  chmod +x "$STUB_MIXED"

  # Stub engine that wraps its (correct) JSON decision in a ```json markdown
  # fence — the live Haiku-tier output the strict parser used to reject, which
  # produced the production triage 0/5 (every case `got null`, #762).
  STUB_FENCED="$TMP/stub_fenced.sh"
  cat >"$STUB_FENCED" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q MARKER_APPROVE "$prompt"; then
  printf '```json\n{"escalate": false, "risk": "LOW", "signals": [], "summary": "docs only"}\n```\n'
elif grep -q MARKER_ESCALATE "$prompt"; then
  printf '```json\n{"escalate": true, "risk": "HIGH", "signals": ["auth"], "summary": "auth/secrets touched"}\n```\n'
else
  echo 'no marker found'
fi
SH
  chmod +x "$STUB_FENCED"
}

teardown() { rm -rf "$TMP"; }

@test "scores a correct stub as all-pass (score 1, exit 0)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '.total'  <<<"$output")" -eq 2 ]
  [ "$(jq '.passed' <<<"$output")" -eq 2 ]
  [ "$(jq '.failed' <<<"$output")" -eq 0 ]
  [ "$(jq '.score'  <<<"$output")" = "1" ]
  # Passing cases stay lean — no raw_excerpt field.
  [ "$(jq '.cases[0] | has("raw_excerpt")' <<<"$output")" = "false" ]
}

@test "per-case results carry id, pass, expected and actual decisions" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  approve="$(jq -c '.cases[] | select(.id=="case-approve")' <<<"$output")"
  [ "$(jq -r '.pass'             <<<"$approve")" = "true" ]
  [ "$(jq -r '.expected.escalate' <<<"$approve")" = "false" ]
  [ "$(jq -r '.actual.escalate'   <<<"$approve")" = "false" ]
  [ "$(jq -r '.actual.risk'       <<<"$approve")" = "LOW" ]
}

@test "a wrong escalate/risk decision scores fail (exit 1)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_WRONG" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  # The approve case still matches; the escalate case is mis-approved -> fail.
  [ "$(jq '.passed' <<<"$output")" -eq 1 ]
  [ "$(jq '.failed' <<<"$output")" -eq 1 ]
  esc="$(jq -c '.cases[] | select(.id=="case-escalate")' <<<"$output")"
  [ "$(jq -r '.pass' <<<"$esc")" = "false" ]
}

@test "unparseable (non-JSON) model output counts as a failure" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_PROSE" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  [ "$(jq '.passed' <<<"$output")" -eq 0 ]
  [ "$(jq '.failed' <<<"$output")" -eq 2 ]
  # Unparseable output yields a null actual decision.
  [ "$(jq -r '.cases[0].actual' <<<"$output")" = "null" ]
  # …and captures a short excerpt of the raw output for diagnosis.
  [[ "$(jq -r '.cases[0].raw_excerpt' <<<"$output")" == *"would approve it"* ]]
}

@test "fenced JSON output is tolerated and scored — regression for the live triage 0/5 (#762)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_FENCED" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '.passed' <<<"$output")" -eq 2 ]
  [ "$(jq '.failed' <<<"$output")" -eq 0 ]
  approve="$(jq -c '.cases[] | select(.id=="case-approve")'  <<<"$output")"
  [ "$(jq -r '.actual.escalate' <<<"$approve")" = "false" ]
  [ "$(jq -r '.actual.risk'     <<<"$approve")" = "LOW" ]
  esc="$(jq -c '.cases[] | select(.id=="case-escalate")' <<<"$output")"
  [ "$(jq -r '.actual.escalate' <<<"$esc")" = "true" ]
  [ "$(jq -r '.actual.risk'     <<<"$esc")" = "HIGH" ]
}

# --- role-generic prompt resolution: persona advisory prompt fallback (#1630) --
#
# Personas keep their prompt at prompts/<role>/advisory.md, not prompts/<role>.md.
# For the shared harness to score ANY persona eval tree (AC #4 — unblock the
# other seven drafted personas, not just solution-architect), run-eval.sh must
# fall back to prompts/<role>/advisory.md when prompts/<role>.md is absent. This
# proves the fallback loads the advisory prompt (a marker unique to advisory.md
# reaches the engine) and scores against it. EVAL_PROMPTS_DIR overrides the prompt
# root the same way EVALS_DIR overrides the cases root, so the test stays offline.

@test "prompt resolution: falls back to prompts/<role>/advisory.md for a persona (no <role>.md)" {
  local root="$TMP/persona"
  mkdir -p "$root/evals/sample-persona/holdout" "$root/prompts/sample-persona"

  cat >"$root/evals/sample-persona/holdout/cases.jsonl" <<'JSONL'
{"id": "p-approve", "input": "MARKER_APPROVE", "expected": {"escalate": false, "risk": "LOW"}}
JSONL

  # No prompts/sample-persona.md — ONLY the advisory prompt exists. It carries a
  # unique marker so the stub can confirm THIS file was the one concatenated.
  cat >"$root/prompts/sample-persona/advisory.md" <<'MD'
# Sample persona advisory
ADVISORY_PROMPT_MARKER
MD

  local stub="$root/stub.sh"
  cat >"$stub" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
# Only answer when the advisory prompt (its marker) was actually loaded, proving
# the fallback resolved prompts/<role>/advisory.md rather than dying on a missing
# prompts/<role>.md.
if grep -q ADVISORY_PROMPT_MARKER "$prompt" && grep -q MARKER_APPROVE "$prompt"; then
  echo '{"escalate": false, "risk": "LOW"}'
else
  echo 'advisory prompt not loaded'
fi
SH
  chmod +x "$stub"

  EVALS_DIR="$root/evals" EVAL_PROMPTS_DIR="$root/prompts" EVAL_ENGINE_CMD="$stub" \
    run --separate-stderr bash "$SCORER" sample-persona
  [ "$status" -eq 0 ]
  [ "$(jq '.passed' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.cases[0].pass' <<<"$output")" = "true" ]
}

# --- infra failure vs. quality regression (throttle classification, #920) ------
#
# A throttle (every model in the engine fallback chain exits non-zero) means the
# skill was never actually scored — it must NOT read as a held-out regression.
# The scorer captures the engine's per-case exit status (engine_rc) and, when
# every failing case is an infra failure, exits 2 (-> outcome=error) instead of 1
# (-> regression). A genuine quality miss (engine exits 0, output wrong) is
# unchanged: exit 1.

@test "all-throttled run (every engine call exits non-zero) is an infra error -> exit 2 (#920)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_THROTTLE" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 2 ]
  # Both cases failed and every failing case carries a non-zero engine_rc.
  [ "$(jq '.failed' <<<"$output")" -eq 2 ]
  [ "$(jq '[.cases[] | select(.engine_rc != 0)] | length' <<<"$output")" -eq 2 ]
}

@test "mixed run (one answered, one throttled) classifies as infra error -> exit 2 (#920)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_MIXED" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 2 ]
  ap="$(jq -c '.cases[] | select(.id=="case-approve")' <<<"$output")"
  [ "$(jq -r '.pass'      <<<"$ap")" = "true" ]
  [ "$(jq -r '.engine_rc' <<<"$ap")" = "0" ]
  esc="$(jq -c '.cases[] | select(.id=="case-escalate")' <<<"$output")"
  [ "$(jq -r '.pass' <<<"$esc")" = "false" ]
  [ "$(jq -r '.engine_rc' <<<"$esc")" != "0" ]
}

@test "a genuine quality miss (engine exits 0, wrong answer) stays a regression -> exit 1 (#920)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_WRONG" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  # The failing case ran the engine successfully (rc 0) — a quality miss, not infra.
  esc="$(jq -c '.cases[] | select(.id=="case-escalate")' <<<"$output")"
  [ "$(jq -r '.engine_rc' <<<"$esc")" = "0" ]
}

@test "unparseable output with a clean engine exit is a regression, not infra -> exit 1 (#920)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_PROSE" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  # Engine exited 0 for every case (the output was just wrong/unparseable).
  [ "$(jq '[.cases[] | select(.engine_rc == 0)] | length' <<<"$output")" -eq 2 ]
}

@test "passing cases carry engine_rc 0 (clean response wiring, #920)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '[.cases[] | select(.engine_rc == 0)] | length' <<<"$output")" -eq 2 ]
}

@test "aggregate score is passed/total across a mixed set" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_WRONG" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 1 ]
  [ "$(jq '.score' <<<"$output")" = "0.5" ]
}

@test "scorer never writes to the held-out cases file" {
  before="$(md5sum "$TMP/evals/triage/holdout/cases.jsonl")"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  after="$(md5sum "$TMP/evals/triage/holdout/cases.jsonl")"
  [ "$before" = "$after" ]
}

@test "missing skill argument is a hard error (::error::, non-zero)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run bash "$SCORER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "unknown skill (no cases.jsonl) is a hard error (::error::, non-zero)" {
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run bash "$SCORER" nosuchskill
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "default engine command is run_triage from scripts/engine.sh" {
  # No EVAL_ENGINE_CMD override: the scorer must source engine.sh and resolve
  # run_triage as the engine command. We can't invoke a real provider offline,
  # so just assert the default wiring is documented/usable by checking the help
  # path rejects a bad skill cleanly (engine.sh sourced without error first).
  EVALS_DIR="$TMP/evals" run bash "$SCORER" nosuchskill
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "scorer reads holdout/ only — never the proposer-visible dev/ split" {
  # A dev/ case that, if the scorer read it, would change total. The scorer must
  # ignore dev/ entirely (#691 hygiene: only holdout/ is ever scored).
  mkdir -p "$TMP/evals/triage/dev"
  cat >"$TMP/evals/triage/dev/cases.jsonl" <<'JSONL'
{"id": "dev-decoy", "input": "MARKER_APPROVE\nDev-only case that must never be scored.", "expected": {"escalate": false, "risk": "LOW"}}
JSONL
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 2 ]
  [ -z "$(jq -r '.cases[] | select(.id=="dev-decoy")' <<<"$output")" ]
}

# --- LLM-judge scorer mode (deep-review, #585) ---------------------------------
#
# The comparator core selects its scorer mode from a per-skill scorer.json
# (deterministic vs llm-judge) — never by branching on the skill name. In
# llm-judge mode the skill output is scored by a Haiku-tier judge prompt that
# emits a numeric per-case score; a stubbed judge keeps these tests offline.

# Builds a deep-review skill fixture under $TMP/evals in llm-judge mode plus the
# skill-under-test stub. Each test supplies its own judge stub. The judge prompt
# lives at evals/judge.md (versioned, CODEOWNER-gated like the cases).
_setup_judge_skill() {
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
{"id": "deep-escalate", "input": "MARKER_ESCALATE\nTitle: Add user search\n\nSQL built by string concatenation of input.", "expected": {"decision": "escalate", "risk": "HIGH", "key_findings": ["sql injection via string concatenation"]}}
JSONL

  # Skill-under-test stub: emits a deep-review-shaped JSON decision per case,
  # tagged with CANDIDATE_TOKEN (shared) plus a per-decision token (DECISION_*).
  # The decision tokens live ONLY in the candidate output, so a judge stub keying
  # off them proves the scorer fed the candidate into the judge prompt (and the
  # tokens never collide with prose inside judge.md).
  SKILL_STUB="$TMP/skill_stub.sh"
  cat >"$SKILL_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q MARKER_ESCALATE "$prompt"; then
  echo '{"tier":"deep","decision":"escalate","risk":"HIGH","findings":[{"category":"sql-injection","message":"CANDIDATE_TOKEN DECISION_ESCALATE string concat"}]}'
elif grep -q MARKER_APPROVE "$prompt"; then
  echo '{"tier":"deep","decision":"approve","risk":"LOW","findings":[],"summary":"CANDIDATE_TOKEN DECISION_APPROVE docs only"}'
else
  echo 'no marker found'
fi
SH
  chmod +x "$SKILL_STUB"
}

@test "llm-judge mode: all-pass scores 1 (exit 0) with per-case numeric score" {
  _setup_judge_skill
  # Judge stub: always returns a passing score.
  JUDGE_STUB="$TMP/judge_pass.sh"
  cat >"$JUDGE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo '{"score": 1, "reason": "matches"}'
SH
  chmod +x "$JUDGE_STUB"

  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$SKILL_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    run --separate-stderr bash "$SCORER" deep-review
  [ "$status" -eq 0 ]
  [ "$(jq '.total'  <<<"$output")" -eq 2 ]
  [ "$(jq '.passed' <<<"$output")" -eq 2 ]
  [ "$(jq '.failed' <<<"$output")" -eq 0 ]
  [ "$(jq '.score'  <<<"$output")" = "1" ]
  # Each case carries a numeric score (AC #3).
  [ "$(jq '.cases[0].score' <<<"$output")" = "1" ]
  [ "$(jq '.cases[].score | numbers' <<<"$output" | wc -l)" -eq 2 ]
  # …and the engine exit status, so the throttle classification (#920) works in
  # llm-judge mode too. The skill stub answered cleanly here -> engine_rc 0.
  [ "$(jq '[.cases[] | select(.engine_rc == 0)] | length' <<<"$output")" -eq 2 ]
}

@test "llm-judge mode: a sub-threshold score fails the case (exit 1)" {
  _setup_judge_skill
  # Judge stub: approve case scores high, escalate case scores below threshold.
  JUDGE_STUB="$TMP/judge_mixed.sh"
  cat >"$JUDGE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q DECISION_ESCALATE "$prompt"; then
  echo '{"score": 0.3, "reason": "missed the injection finding"}'
else
  echo '{"score": 0.95, "reason": "good"}'
fi
SH
  chmod +x "$JUDGE_STUB"

  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$SKILL_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    run --separate-stderr bash "$SCORER" deep-review
  [ "$status" -eq 1 ]
  [ "$(jq '.passed' <<<"$output")" -eq 1 ]
  [ "$(jq '.failed' <<<"$output")" -eq 1 ]
  esc="$(jq -c '.cases[] | select(.id=="deep-escalate")' <<<"$output")"
  [ "$(jq -r '.pass'  <<<"$esc")" = "false" ]
  [ "$(jq -r '.score' <<<"$esc")" = "0.3" ]
}

@test "llm-judge mode: unparseable judge output counts as a failure (score 0)" {
  _setup_judge_skill
  JUDGE_STUB="$TMP/judge_prose.sh"
  cat >"$JUDGE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 'Looks great, I would give it full marks.'
SH
  chmod +x "$JUDGE_STUB"

  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$SKILL_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    run --separate-stderr bash "$SCORER" deep-review
  [ "$status" -eq 1 ]
  [ "$(jq '.failed' <<<"$output")" -eq 2 ]
  [ "$(jq '.cases[0].score' <<<"$output")" = "0" ]
}

@test "llm-judge mode: the judge prompt carries both the expected ref and the candidate" {
  _setup_judge_skill
  # Capturing judge stub: copies its assembled prompt out so we can assert the
  # scorer fed it BOTH the case's expected reference and the skill's candidate.
  JUDGE_STUB="$TMP/judge_capture.sh"
  cat >"$JUDGE_STUB" <<SH
#!/usr/bin/env bash
set -euo pipefail
cp "\$1" "$TMP/captured_judge_prompt.txt"
echo '{"score": 1}'
SH
  chmod +x "$JUDGE_STUB"

  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$SKILL_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    run --separate-stderr bash "$SCORER" deep-review
  [ "$status" -eq 0 ]
  # The judge prompt must include the judge rubric, the candidate (CANDIDATE_TOKEN
  # from the skill stub), and the expected reference (key_findings text).
  grep -q "Eval judge" "$TMP/captured_judge_prompt.txt"
  grep -q "CANDIDATE_TOKEN" "$TMP/captured_judge_prompt.txt"
  grep -q "sql injection via string concatenation" "$TMP/captured_judge_prompt.txt"
}

@test "llm-judge mode: scorer never writes the held-out cases file" {
  _setup_judge_skill
  JUDGE_STUB="$TMP/judge_pass.sh"
  cat >"$JUDGE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo '{"score": 1}'
SH
  chmod +x "$JUDGE_STUB"

  before="$(md5sum "$TMP/evals/deep-review/holdout/cases.jsonl")"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$SKILL_STUB" EVAL_JUDGE_CMD="$JUDGE_STUB" \
    run --separate-stderr bash "$SCORER" deep-review
  [ "$status" -eq 0 ]
  after="$(md5sum "$TMP/evals/deep-review/holdout/cases.jsonl")"
  [ "$before" = "$after" ]
}

@test "llm-judge mode: qa-lead resolves prompts/qa-lead/advisory.md and scores via the judge (#1645)" {
  # qa-lead is a prose advisory scored by the shared judge (evals/judge.md). This
  # exercises the reconciled prompt-path convention (run-eval.sh must resolve the
  # persona advisory path prompts/<skill>/advisory.md, not prompts/<skill>.md) AND
  # the llm-judge scorer end-to-end, fully offline via stubbed skill + judge.
  mkdir -p "$TMP/evals/qa-lead/holdout"
  cat >"$TMP/evals/qa-lead/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "judge.md", "pass_threshold": 0.7}
JSON
  cat >"$TMP/evals/judge.md" <<'MD'
# Eval judge
Score the candidate qa-lead advisory against the expected reference.
Emit a single JSON object: {"score": <0..1>, "reason": "..."}.
MD
  cat >"$TMP/evals/qa-lead/holdout/cases.jsonl" <<'JSONL'
{"id": "qa-hold-payment", "input": "MARKER_ESCALATE\nPR adds card-capture; only the success path is tested.", "expected": {"escalate": true, "risk": "HIGH", "recommend": "add declined/duplicate-submit/refund cases"}}
{"id": "qa-hold-refactor", "input": "MARKER_APPROVE\nBehavior-preserving rename in a well-covered module.", "expected": {"escalate": false, "risk": "LOW", "recommend": "no additional tests required"}}
JSONL

  # Skill-under-test stub standing in for the persona advisory. It carries a
  # CANDIDATE_TOKEN plus a per-case token so the judge stub can prove the scorer
  # fed it the candidate advisory (prose, not a JSON decision).
  QA_SKILL_STUB="$TMP/qa_skill_stub.sh"
  cat >"$QA_SKILL_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q MARKER_ESCALATE "$prompt"; then
  echo 'CANDIDATE_TOKEN DECISION_ESCALATE Risk tier: HIGH. What I'"'"'d shore up: add declined and idempotency cases. Escalate? yes.'
elif grep -q MARKER_APPROVE "$prompt"; then
  echo 'CANDIDATE_TOKEN DECISION_APPROVE Risk tier: LOW. Existing coverage is sufficient. Escalate? no.'
else
  echo 'no marker found'
fi
SH
  chmod +x "$QA_SKILL_STUB"

  # Judge stub: validates both the judge rubric and the candidate are present,
  # checks that expected guidance is honored, then returns a numeric score.
  QA_JUDGE_STUB="$TMP/qa_judge_stub.sh"
  cat >"$QA_JUDGE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
# Verify the judge prompt itself (rubric) is in the assembled prompt.
grep -q "Eval judge" "$prompt" || { echo '{"score": 0, "reason": "judge rubric missing from prompt"}'; exit 0; }
# Verify the candidate is present (proves scorer fed the skill output to judge).
grep -q CANDIDATE_TOKEN "$prompt" || { echo '{"score": 0, "reason": "candidate missing"}'; exit 0; }
# Verify the expected reference is in the prompt (contains the expected guidance).
grep -q "Expected reference" "$prompt" || { echo '{"score": 0, "reason": "expected reference not in prompt"}'; exit 0; }
echo '{"score": 0.9, "reason": "matches the expected risk tier and guidance"}'
SH
  chmod +x "$QA_JUDGE_STUB"

  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$QA_SKILL_STUB" EVAL_JUDGE_CMD="$QA_JUDGE_STUB" \
    run --separate-stderr bash "$SCORER" qa-lead
  [ "$status" -eq 0 ]
  [ "$(jq '.total'  <<<"$output")" -eq 2 ]
  [ "$(jq '.passed' <<<"$output")" -eq 2 ]
  [ "$(jq '.score'  <<<"$output")" = "1" ]
  # Per-case numeric judge score is recorded.
  [ "$(jq '.cases[0].score' <<<"$output")" = "0.9" ]
}

@test "llm-judge mode: qa-lead sub-threshold advisory fails the case (exit 1, #1645)" {
  mkdir -p "$TMP/evals/qa-lead/holdout"
  cat >"$TMP/evals/qa-lead/scorer.json" <<'JSON'
{"mode": "llm-judge", "judge_prompt": "judge.md", "pass_threshold": 0.7}
JSON
  cat >"$TMP/evals/judge.md" <<'MD'
# Eval judge
Emit {"score": <0..1>, "reason": "..."}.
MD
  cat >"$TMP/evals/qa-lead/holdout/cases.jsonl" <<'JSONL'
{"id": "qa-hold-payment", "input": "MARKER_ESCALATE\nMoney path, happy-only tests.", "expected": {"escalate": true, "risk": "HIGH", "recommend": "add declined/idempotency/refund"}}
JSONL
  QA_SKILL_STUB="$TMP/qa_skill_stub.sh"
  cat >"$QA_SKILL_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 'CANDIDATE_TOKEN Risk tier: LOW. Looks fine. Escalate? no.'
SH
  chmod +x "$QA_SKILL_STUB"
  # Judge scores the (wrong) advisory below threshold.
  QA_JUDGE_STUB="$TMP/qa_judge_stub.sh"
  cat >"$QA_JUDGE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo '{"score": 0.2, "reason": "missed the HIGH risk on the money path"}'
SH
  chmod +x "$QA_JUDGE_STUB"

  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$QA_SKILL_STUB" EVAL_JUDGE_CMD="$QA_JUDGE_STUB" \
    run --separate-stderr bash "$SCORER" qa-lead
  [ "$status" -eq 1 ]
  [ "$(jq '.failed' <<<"$output")" -eq 1 ]
  [ "$(jq '.cases[0].score' <<<"$output")" = "0.2" ]
}

@test "absent scorer.json defaults to deterministic mode (triage unchanged)" {
  # Triage has no scorer.json in the fixture; it must still score deterministically.
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$STUB_OK" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '.passed' <<<"$output")" -eq 2 ]
}

@test "scorer honors SKILL_PROMPT_FILE to score an arbitrary skill file" {
  # The gate (#586) scores incumbent/candidate files against the SAME held-out
  # set. The scorer must accept a SKILL_PROMPT_FILE override pointing at any file
  # (not just prompts/<skill>.md) and inline it as the per-case prompt. The stub
  # below greps the prompt for QUALITY_PERFECT to confirm the override file content
  # reached the engine.
  skill_file="$TMP/candidate.md"
  printf '# Triage\nQUALITY_PERFECT\n' >"$skill_file"
  probe="$TMP/probe.sh"
  cat >"$probe" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
grep -q QUALITY_PERFECT "$prompt" || { echo 'override not applied'; exit 0; }
if grep -q MARKER_ESCALATE "$prompt"; then
  echo '{"escalate": true, "risk": "HIGH"}'
else
  echo '{"escalate": false, "risk": "LOW"}'
fi
SH
  chmod +x "$probe"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$probe" SKILL_PROMPT_FILE="$skill_file" \
    run --separate-stderr bash "$SCORER" triage
  [ "$status" -eq 0 ]
  [ "$(jq '.passed' <<<"$output")" -eq 2 ]
}

# --- strict-improvement gate (scripts/evals/gate.sh, #586) ---------------------
#
# The gate scores an incumbent skill file and a candidate skill file against the
# SAME held-out set (via run-eval.sh) and accepts (exit 0) ONLY when the candidate
# STRICTLY beats the incumbent. Ties and regressions are rejected (exit 1). These
# tests drive it offline with a stub engine whose correctness is keyed off a
# quality marker in the skill file, giving three deterministic score tiers:
#   QUALITY_PERFECT -> both cases correct  -> score 1.0
#   QUALITY_HALF    -> approve only        -> score 0.5
#   (anything else) -> non-JSON garbage    -> score 0.0
_gate_setup() {
  GATE="$ROOT/scripts/evals/gate.sh"

  GATE_STUB="$TMP/gate_stub.sh"
  cat >"$GATE_STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
if grep -q QUALITY_PERFECT "$prompt"; then
  if grep -q MARKER_ESCALATE "$prompt"; then
    echo '{"escalate": true, "risk": "HIGH"}'
  else
    echo '{"escalate": false, "risk": "LOW"}'
  fi
elif grep -q QUALITY_HALF "$prompt"; then
  echo '{"escalate": false, "risk": "LOW"}'
else
  echo 'not json'
fi
SH
  chmod +x "$GATE_STUB"

  PERFECT="$TMP/skill_perfect.md"; printf '# Triage\nQUALITY_PERFECT\n' >"$PERFECT"
  HALF="$TMP/skill_half.md";       printf '# Triage\nQUALITY_HALF\n'    >"$HALF"
  ZERO="$TMP/skill_zero.md";       printf '# Triage\nQUALITY_ZERO\n'    >"$ZERO"
}

@test "gate: strictly-better candidate is ACCEPTED (exit 0)" {
  _gate_setup
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run --separate-stderr bash "$GATE" triage "$HALF" "$PERFECT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' <<<"$output")" = "accept" ]
  [ "$(jq -r '.accepted' <<<"$output")" = "true" ]
  [ "$(jq '.incumbent_score' <<<"$output")" = "0.5" ]
  [ "$(jq '.candidate_score' <<<"$output")" = "1" ]
}

@test "gate: regressed candidate is REJECTED (exit 1)" {
  _gate_setup
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run --separate-stderr bash "$GATE" triage "$PERFECT" "$HALF"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.verdict' <<<"$output")" = "reject" ]
  [ "$(jq -r '.accepted' <<<"$output")" = "false" ]
  [ "$(jq '.incumbent_score' <<<"$output")" = "1" ]
  [ "$(jq '.candidate_score' <<<"$output")" = "0.5" ]
}

@test "gate: a TIE is REJECTED — the gate is strict '>' not '>='" {
  _gate_setup
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run --separate-stderr bash "$GATE" triage "$HALF" "$HALF"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.accepted' <<<"$output")" = "false" ]
  [ "$(jq '.incumbent_score' <<<"$output")" = "$(jq '.candidate_score' <<<"$output")" ]
}

@test "gate: a worse-than-zero candidate (score 0) is REJECTED against a 0.5 incumbent" {
  _gate_setup
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run --separate-stderr bash "$GATE" triage "$HALF" "$ZERO"
  [ "$status" -eq 1 ]
  [ "$(jq '.candidate_score' <<<"$output")" = "0" ]
}

@test "gate: verdict JSON carries skill, both scores, and the accepted flag" {
  _gate_setup
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run --separate-stderr bash "$GATE" triage "$HALF" "$PERFECT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.skill' <<<"$output")" = "triage" ]
  [ "$(jq 'has("incumbent_score") and has("candidate_score") and has("accepted")' <<<"$output")" = "true" ]
}

@test "gate: missing arguments is a hard error (::error::, non-zero)" {
  _gate_setup
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run bash "$GATE" triage "$HALF"
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [[ "$output" == *"::error::"* ]]
}

@test "gate: a missing candidate file is a hard error (::error::, non-zero)" {
  _gate_setup
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run bash "$GATE" triage "$HALF" "$TMP/does-not-exist.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [[ "$output" == *"::error::"* ]]
}

@test "gate: never writes the held-out cases file" {
  _gate_setup
  before="$(md5sum "$TMP/evals/triage/holdout/cases.jsonl")"
  EVALS_DIR="$TMP/evals" EVAL_ENGINE_CMD="$GATE_STUB" \
    run --separate-stderr bash "$GATE" triage "$HALF" "$PERFECT"
  [ "$status" -eq 0 ]
  after="$(md5sum "$TMP/evals/triage/holdout/cases.jsonl")"
  [ "$before" = "$after" ]
}
