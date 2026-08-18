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
    secrets = triggers["workflow_call"].get("secrets", {})
    token = secrets.get("CLAUDE_CODE_OAUTH_TOKEN")
    if token is None:
        rc |= fail("CLAUDE_CODE_OAUTH_TOKEN is no longer declared in workflow_call secrets")
    elif token.get("required") is not False:
        rc |= fail(
            "CLAUDE_CODE_OAUTH_TOKEN must be required:false — required:true fails "
            "callers at secrets evaluation before the preflight can run (#1525)"
        )

    jobs = doc.get("jobs", {})
    if not jobs:
        rc |= fail("no jobs parsed from the reusable")

    for name, job in jobs.items():
        cond = str(job.get("if", ""))
        if PAUSE_EXPR not in cond:
            rc |= fail(f"job '{name}' is missing the {PAUSE_EXPR} pause gate in its if:")

    for name in ENGINE_JOBS:
        job = jobs.get(name)
        if job is None:
            rc |= fail(f"expected engine job '{name}' not found")
            continue
        step_names = [str(s.get("name", "")) for s in job.get("steps", [])]
        if not any(PREFLIGHT_STEP in n for n in step_names):
            rc |= fail(f"job '{name}' is missing the '{PREFLIGHT_STEP}' step")
        elif PREFLIGHT_STEP not in step_names[0]:
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
