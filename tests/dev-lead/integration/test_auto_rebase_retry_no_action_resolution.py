#!/usr/bin/env python3
"""Guard that auto-rebase-retry.yml can run during an action-resolution outage.

The Auto-rebase retry handler exists to self-heal a *failed* Auto-rebase run
caused by a transient GitHub infra hiccup (AGENTS.md §"Workflow Files"
exception). The DEGRADED metric in #1473 was caused by exactly such a hiccup:
the Auto-rebase run failed in "Set up job" with
``Failed to resolve action download info. Error: Service Unavailable`` (a 503
from the action-resolution service). The retry handler fired but hung and was
cancelled — because its own "Set up job" had to resolve ``actions/checkout``
during the very same outage.

Regression guard: the retry job must not depend on resolving any marketplace
action. A job with zero ``uses:`` steps skips the "Prepare all required actions"
phase entirely, so an action-resolution outage cannot block the self-heal. The
job instead fetches the retry script with the pre-installed ``gh`` CLI (the REST
contents API, a distinct service), which requires ``contents: read``.
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    yaml = None

WORKFLOW = ".github/workflows/auto-rebase-retry.yml"
RETRY_SCRIPT = "scripts/auto-rebase-retry.sh"


def main() -> int:
    if yaml is None:
        print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
        return 2

    try:
        with open(WORKFLOW, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"FAIL: {WORKFLOW} not found")
        return 1

    if not isinstance(doc, dict):
        print(f"FAIL: {WORKFLOW} did not parse as a YAML mapping")
        return 1

    jobs = doc.get("jobs") or {}
    retry = jobs.get("retry") if isinstance(jobs, dict) else None
    if not isinstance(retry, dict):
        print(f"FAIL: {WORKFLOW} has no 'retry' job")
        return 1

    failures: list[str] = []

    # 1. No step may resolve a marketplace action — that is the "Set up job"
    #    dependency that shares the outage the handler exists to heal (#1473).
    steps = retry.get("steps") or []
    if not isinstance(steps, list) or not steps:
        failures.append("  retry job has no steps")
        steps = []
    uses_steps = [
        s.get("uses")
        for s in steps
        if isinstance(s, dict) and isinstance(s.get("uses"), str)
    ]
    if uses_steps:
        failures.append(
            "  retry job resolves marketplace action(s) in a step: "
            f"{uses_steps!r}\n"
            "  A self-heal handler must not depend on action resolution during\n"
            "  'Set up job' — that is the transient outage class it exists to heal\n"
            "  (#1473). Fetch the script via the pre-installed gh CLI instead."
        )

    # 2. The retry logic must still be exercised via the tested script.
    run_bodies = "\n".join(
        s["run"] for s in steps if isinstance(s, dict) and isinstance(s.get("run"), str)
    )
    if RETRY_SCRIPT not in run_bodies:
        failures.append(
            f"  retry job does not invoke {RETRY_SCRIPT} — the retry logic must\n"
            "  stay in the unit-tested script, not be reimplemented inline."
        )

    # 3. Permissions: actions:write to re-run, contents:read to fetch the script.
    perms = retry.get("permissions")
    if not isinstance(perms, dict):
        failures.append("  retry job must declare an explicit permissions mapping")
    else:
        if perms.get("actions") != "write":
            failures.append("  retry job must keep 'actions: write' (gh run rerun --failed)")
        if perms.get("contents") != "read":
            failures.append(
                "  retry job must declare 'contents: read' to fetch the retry\n"
                "  script via the gh REST contents API (no actions/checkout)."
            )

    if failures:
        print(f"FAIL: {WORKFLOW} is not resilient to an action-resolution outage:")
        for msg in failures:
            print(msg)
        return 1

    print(f"PASS: {WORKFLOW} retry job resolves no actions and self-fetches {RETRY_SCRIPT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
