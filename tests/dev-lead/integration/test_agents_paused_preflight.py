#!/usr/bin/env python3
"""Contract test for the AGENTS_PAUSED pause state and engine-token preflight
(#1525) in .github/workflows/dev-lead-reusable.yml.

Asserts the three load-bearing properties whose loss would silently reintroduce
the 2026-08-16 outage mode (deliberate token withholding presenting as a
fleet-wide dispatch failure):

1. CLAUDE_CODE_OAUTH_TOKEN is declared required:false — a required:true fails
   the CALLER at secrets evaluation, before any in-run handling can classify
   the absence.
2. Every top-level job gates on vars.AGENTS_PAUSED != 'true', so a deliberate
   pause skips cleanly (neutral) instead of failing red.
3. The engine-consuming jobs (dispatch, resume) each carry an "Engine token
   preflight" step so a genuinely missing secret produces one actionable error
   naming the secret.

Pure offline YAML parse; returns 0/1 like the sibling stub tests.
"""
import sys

import yaml

WORKFLOW = ".github/workflows/dev-lead-reusable.yml"
PAUSE_EXPR = "vars.AGENTS_PAUSED != 'true'"
PREFLIGHT_STEP = "Engine token preflight"
ENGINE_JOBS = ("dispatch", "resume")


def fail(msg):
    print(f"FAIL: {msg}")
    return 1


def main():
    with open(WORKFLOW, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)

    rc = 0

    # PyYAML parses the bare `on:` key as boolean True.
    triggers = doc.get("on") or doc.get(True)
    if not isinstance(triggers, dict):
        rc |= fail("workflow_call trigger declaration is not a dict")
        return rc
    if "workflow_call" not in triggers or not isinstance(triggers["workflow_call"], dict):
        rc |= fail("workflow_call key not found or is not a dict")
        return rc
    secrets = triggers["workflow_call"].get("secrets", {})
    if not isinstance(secrets, dict):
        rc |= fail("secrets is not a dict")
        return rc
    token = secrets.get("CLAUDE_CODE_OAUTH_TOKEN")
    if token is None:
        rc |= fail("CLAUDE_CODE_OAUTH_TOKEN is no longer declared in workflow_call secrets")
    elif not isinstance(token, dict):
        rc |= fail("CLAUDE_CODE_OAUTH_TOKEN is not a dict")
    elif token.get("required") is not False:
        rc |= fail(
            "CLAUDE_CODE_OAUTH_TOKEN must be required:false — required:true fails "
            "callers at secrets evaluation before the preflight can run (#1525)"
        )

    jobs = doc.get("jobs", {})
    if not isinstance(jobs, dict):
        rc |= fail("jobs is not a dict")
        return rc
    if not jobs:
        rc |= fail("no jobs parsed from the reusable")

    for name, job in jobs.items():
        if not isinstance(job, dict):
            rc |= fail(f"job '{name}' is not a dict")
            continue
        cond = str(job.get("if", ""))
        if PAUSE_EXPR not in cond:
            rc |= fail(f"job '{name}' is missing the {PAUSE_EXPR} pause gate in its if:")

    for name in ENGINE_JOBS:
        job = jobs.get(name)
        if job is None:
            rc |= fail(f"expected engine job '{name}' not found")
            continue
        if not isinstance(job, dict):
            rc |= fail(f"job '{name}' is not a dict")
            continue
        steps = job.get("steps", [])
        if not isinstance(steps, list):
            rc |= fail(f"job '{name}' steps is not a list")
            continue
        step_names = [str(s.get("name", "") if isinstance(s, dict) else "") for s in steps]
        if not any(PREFLIGHT_STEP in n for n in step_names):
            rc |= fail(f"job '{name}' is missing the '{PREFLIGHT_STEP}' step")
        elif step_names and PREFLIGHT_STEP not in step_names[0]:
            rc |= fail(
                f"job '{name}': '{PREFLIGHT_STEP}' must be the FIRST step — a later "
                "step could burn work before discovering the token is absent"
            )

    if rc == 0:
        print(
            "PASS: AGENTS_PAUSED gates on all jobs; token required:false; "
            f"preflight first in {', '.join(ENGINE_JOBS)}"
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())
