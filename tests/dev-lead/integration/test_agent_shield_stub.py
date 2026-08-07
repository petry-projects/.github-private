#!/usr/bin/env python3
"""Validate that agent-shield.yml is the canonical org stub pinned to @agent-shield/v2-stable.

The org standard requires agent-shield.yml to be a thin caller stub that delegates
to the reusable at the major-scoped channel tag @agent-shield/v2-stable (#1184). A
bare @agent-shield/stable tier pin (missing the major scope) is drift (issue #1393).

Standard: petry-projects/.github/standards/ci-standards.md#centralization-tiers
Source of truth: petry-projects/.github/standards/workflows/agent-shield.yml
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW = ".github/workflows/agent-shield.yml"
EXPECTED_USES = "petry-projects/.github/.github/workflows/agent-shield-reusable.yml@agent-shield/v2-stable"
EXPECTED_JOB = "agent-shield"
REQUIRED_TRIGGERS = {"push", "pull_request"}


def validate_workflow(doc) -> None:
    if not isinstance(doc, dict):
        raise ValueError("Workflow configuration must be a dictionary")
    jobs = doc.get("jobs")
    if jobs is None:
        raise ValueError("Workflow configuration is missing the 'jobs' key")
    if not isinstance(jobs, dict):
        raise ValueError("The 'jobs' key in workflow configuration must be a dictionary")


def main() -> int:
    try:
        with open(WORKFLOW, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"FAIL: {WORKFLOW} not found")
        return 1
    except yaml.YAMLError as err:
        print(f"FAIL: {WORKFLOW} is not valid YAML: {err}")
        return 1

    try:
        validate_workflow(doc)
    except ValueError as err:
        print(f"FAIL: {WORKFLOW}: {err}")
        return 1

    # Validate required trigger configuration
    # PyYAML (YAML 1.1) parses `on:` as boolean True, so check both forms
    on = doc.get(True, doc.get("on")) or {}
    if isinstance(on, str):
        on = {on: None}
    missing_triggers = REQUIRED_TRIGGERS - set(on.keys())
    if missing_triggers:
        print(f"FAIL: {WORKFLOW} is missing required triggers: {sorted(missing_triggers)}")
        return 1

    # Validate top-level permissions block is present
    if "permissions" not in doc:
        print(f"FAIL: {WORKFLOW} is missing top-level 'permissions' key")
        return 1

    jobs = doc["jobs"]

    # Validate no extra inline jobs (thin-stub must only delegate via `uses:`)
    inline_jobs = [
        job_key for job_key, job in jobs.items()
        if isinstance(job, dict) and "uses" not in job
    ]
    if inline_jobs:
        print(f"FAIL: {WORKFLOW} has inline job(s) that bypass delegation: {inline_jobs}")
        return 1

    # Validate required job identity exists
    if EXPECTED_JOB not in jobs:
        print(f"FAIL: {WORKFLOW} is missing required job '{EXPECTED_JOB}'")
        return 1

    # Collect ALL reusable-workflow references (not just the first match)
    found_jobs = []
    for job_key, job in jobs.items():
        if not isinstance(job, dict):
            continue
        uses = job.get("uses")
        if isinstance(uses, str) and "agent-shield-reusable.yml" in uses:
            found_jobs.append((job_key, uses))

    if not found_jobs:
        print(
            f"FAIL: {WORKFLOW} has no job calling agent-shield-reusable.yml\n"
            f"  Expected a job with: uses: {EXPECTED_USES}"
        )
        return 1

    all_valid = True
    for job_key, uses in found_jobs:
        if uses != EXPECTED_USES:
            print(
                f"FAIL: {WORKFLOW} job '{job_key}' uses '{uses}'\n"
                f"  Expected: '{EXPECTED_USES}'\n"
                f"  Fix: replace the `uses:` value with the canonical @agent-shield/v2-stable ref."
            )
            all_valid = False

    if all_valid:
        print(f"PASS: All jobs delegate to {EXPECTED_USES}")
        return 0
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())
