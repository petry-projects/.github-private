#!/usr/bin/env python3
"""Contract test for the engine-token preflight (#1587) in
.github/workflows/pr-review.yml.

#1587: during the 2026-08-23..30 outage, dev-lead failed 100% of runs at its
"Engine token preflight" step ("CLAUDE_CODE_OAUTH_TOKEN is not provided"), while
pr-review — which has NO preflight — kept reporting success (96/97 runs) having
reviewed nothing. A tokenless pr-review run fails OPEN: job conclusion is not
evidence that work happened. This test pins that pr-review now fails LOUD when the
engine token is absent, mirroring dev-lead-reusable.yml's #1525 step.

Asserts:
1. CLAUDE_CODE_OAUTH_TOKEN stays declared required:false — a required:true fails
   the CALLER at secrets evaluation, before any in-run preflight can classify the
   absence (the #1525 design that must be preserved).
2. The review job's FIRST step is an "Engine token preflight" step — placing it
   first means a missing token is discovered before any runner setup is burned.
3. That step reads CLAUDE_CODE_OAUTH_TOKEN, emits a single actionable error that
   names the secret and points at AGENTS_PAUSED for a deliberate pause, and
   exit 1 — so the run fails loudly instead of no-op'ing to a false success.

Pure offline YAML parse; returns 0/1 like the sibling stub tests.
"""
import sys

import yaml

WORKFLOW = ".github/workflows/pr-review.yml"
PREFLIGHT_STEP = "Engine token preflight"
REVIEW_JOB = "review"


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
        return fail("workflow_call trigger declaration is not a dict")
    wc = triggers.get("workflow_call")
    if not isinstance(wc, dict):
        return fail("workflow_call key not found or is not a dict")
    secrets = wc.get("secrets", {})
    if not isinstance(secrets, dict):
        return fail("secrets is not a dict")
    token = secrets.get("CLAUDE_CODE_OAUTH_TOKEN")
    if token is None:
        rc |= fail("CLAUDE_CODE_OAUTH_TOKEN is no longer declared in workflow_call secrets")
    elif not isinstance(token, dict):
        rc |= fail("CLAUDE_CODE_OAUTH_TOKEN is not a dict")
    elif token.get("required") is not False:
        rc |= fail(
            "CLAUDE_CODE_OAUTH_TOKEN must stay required:false — required:true fails "
            "callers at secrets evaluation before the preflight can run (#1525)"
        )

    jobs = doc.get("jobs", {})
    job = jobs.get(REVIEW_JOB) if isinstance(jobs, dict) else None
    if not isinstance(job, dict):
        return fail(f"expected job '{REVIEW_JOB}' not found")

    steps = job.get("steps", [])
    if not isinstance(steps, list) or not steps:
        return fail(f"job '{REVIEW_JOB}' has no steps")

    step_names = [str(s.get("name", "") if isinstance(s, dict) else "") for s in steps]
    if not any(PREFLIGHT_STEP in n for n in step_names):
        return fail(f"job '{REVIEW_JOB}' is missing the '{PREFLIGHT_STEP}' step")
    if PREFLIGHT_STEP not in step_names[0]:
        rc |= fail(
            f"job '{REVIEW_JOB}': '{PREFLIGHT_STEP}' must be the FIRST step — a later "
            "step could burn runner setup before discovering the token is absent"
        )

    preflight = next(s for s in steps if PREFLIGHT_STEP in str(s.get("name", "")))

    env = preflight.get("env", {})
    if not isinstance(env, dict) or "CLAUDE_CODE_OAUTH_TOKEN" not in env:
        rc |= fail("preflight step must map CLAUDE_CODE_OAUTH_TOKEN into its env")

    run = str(preflight.get("run", ""))
    if "CLAUDE_CODE_OAUTH_TOKEN" not in run:
        rc |= fail("preflight step must check CLAUDE_CODE_OAUTH_TOKEN")
    if "exit 1" not in run:
        rc |= fail("preflight step must 'exit 1' on a missing token (fail loud, not no-op)")
    if "is not provided" not in run:
        rc |= fail("preflight error must name the missing secret ('... is not provided ...')")
    if "AGENTS_PAUSED" not in run:
        rc |= fail("preflight error must point at AGENTS_PAUSED for a deliberate pause (#1525)")
    # pr-review is multi-engine (claude/copilot/gemini); copilot/gemini runs
    # legitimately have no CLAUDE_CODE_OAUTH_TOKEN. The hard failure must be gated
    # on the claude engine so the fix does not regress the other engines.
    if "REVIEW_ENGINE" not in run:
        rc |= fail(
            "preflight must gate the failure on REVIEW_ENGINE=claude — copilot/gemini "
            "engines run without the claude token and must not be failed by this check"
        )
    if "REVIEW_ENGINE" not in env:
        rc |= fail("preflight step must map REVIEW_ENGINE into its env to gate the check")

    if rc == 0:
        print(
            "PASS: pr-review.yml token required:false; 'Engine token preflight' is the "
            "first review step and fails loud (exit 1) with an actionable AGENTS_PAUSED hint"
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())
