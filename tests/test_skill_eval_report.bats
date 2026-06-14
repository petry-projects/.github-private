#!/usr/bin/env bats
# Tests for the Skill Eval Report workflow (.github/workflows/skill-eval-report.yml).
#
# This workflow wires the deterministic eval scorer (scripts/evals/run-eval.sh)
# into CI as a NON-BLOCKING report (issue #584). The contract these tests pin:
#
#   AC#1  runs run-eval.sh on a cron schedule AND workflow_dispatch, and
#         publishes the score report (artifact / step summary).
#   AC#2  report-only: a scorer regression (exit 1) must NOT fail the workflow
#         (explicit continue-on-error / non-blocking eval step).
#   AC#3  the real-model eval never runs on pull_request — only schedule/dispatch.
#   AC#4  third-party actions are SHA-pinned and the workflow declares
#         least-privilege top-level permissions.
#
# The assertions parse the workflow YAML rather than the rendered run, so they
# fail fast at the PR that edits the workflow — no live model call required.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WF="$ROOT/.github/workflows/skill-eval-report.yml"
}

# Query the workflow YAML via python. `q <python-expr>`: `doc` is the parsed
# mapping; print the expression's repr. PyYAML parses the bareword `on:` key as
# the boolean True (YAML 1.1), so `on_block` resolves the triggers either way.
q() {
  python3 - "$WF" "$1" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
on_block = doc.get("on", doc.get(True))
print(eval(sys.argv[2]))
PY
}

@test "workflow file exists" {
  [ -f "$WF" ]
}

@test "parses as a YAML mapping" {
  run q "isinstance(doc, dict)"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "AC#1/#3: triggers on a cron schedule" {
  run q "'cron' in str(on_block.get('schedule'))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "AC#1/#3: triggers on workflow_dispatch" {
  run q "'workflow_dispatch' in on_block"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "AC#3: never triggers on pull_request (no PR-time model eval)" {
  run q "'pull_request' in on_block or 'pull_request_target' in on_block"
  [ "$status" -eq 0 ]
  [ "$output" = "False" ]
}

@test "AC#1: exposes an optional skill dispatch input" {
  run q "'skill' in (on_block['workflow_dispatch'].get('inputs') or {})"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "AC#1: invokes scripts/evals/run-eval.sh" {
  grep -q 'scripts/evals/run-eval.sh' "$WF"
}

@test "AC#1: publishes the report (artifact upload or step summary)" {
  grep -Eq 'upload-artifact|GITHUB_STEP_SUMMARY' "$WF"
}

@test "AC#2: the eval step is non-blocking (continue-on-error: true)" {
  run python3 - "$WF" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
ok = False
for job in (doc.get("jobs") or {}).values():
    for step in (job.get("steps") or []):
        run = str(step.get("run", ""))
        if "run-eval.sh" in run and step.get("continue-on-error") is True:
            ok = True
print(ok)
PY
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "AC#4: declares a top-level permissions block" {
  run q "'permissions' in doc"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "AC#4: top-level permissions are least-privilege (not write-all)" {
  run python3 - "$WF" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
perms = doc.get("permissions")
# Acceptable: empty mapping (reset to none) or a read-only mapping. Never a
# write-all scalar or any 'write' grant at the top level.
if isinstance(perms, str):
    ok = perms == "read-all"
elif isinstance(perms, dict):
    ok = all(str(v) != "write" for v in perms.values())
else:
    ok = False
print(ok)
PY
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "AC#4: every third-party action is SHA-pinned (40-hex)" {
  run python3 - "$WF" <<'PY'
import re, sys
bad = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for ln in fh:
        m = re.search(r'uses:\s*([^\s#]+)', ln)
        if not m:
            continue
        ref = m.group(1)
        if ref.startswith("./") or ref.startswith("docker://"):
            continue
        after = ref.split("@", 1)
        if len(after) != 2 or not re.fullmatch(r'[0-9a-f]{40}', after[1]):
            bad.append(ref)
print("OK" if not bad else "UNPINNED: " + ",".join(bad))
PY
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
