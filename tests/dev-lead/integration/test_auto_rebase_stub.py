#!/usr/bin/env python3
"""Validate that auto-rebase.yml uses the @v1 version tag, not a SHA.

AGENTS.md §"Release channel tags & the mutable-ref exception" exempts first-party
reusable workflows from the SHA-pin standard. The correct reference for the
auto-rebase reusable is the versioned tag `@v1`, matching the canonical stub at
standards/workflows/auto-rebase.yml in petry-projects/.github.

Regression guard: a SHA-pinned reference is a compliance violation (issue #139).
"""
from __future__ import annotations

import re
import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW = ".github/workflows/auto-rebase.yml"
REUSABLE = "petry-projects/.github/.github/workflows/auto-rebase-reusable.yml"
EXPECTED_REF = "@v1"
SHA_PATTERN = re.compile(r"@[0-9a-f]{40}\b")


def main() -> int:
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
    uses_values = [
        job["uses"]
        for job in jobs.values()
        if isinstance(job, dict) and "uses" in job
    ]

    reusable_refs = [u for u in uses_values if REUSABLE in u]

    if not reusable_refs:
        print(f"FAIL: {WORKFLOW} does not call {REUSABLE}")
        return 1

    failures = []
    for ref in reusable_refs:
        if SHA_PATTERN.search(ref):
            failures.append(
                f"  SHA-pinned: {ref!r}\n"
                f"  Expected:   '{REUSABLE}{EXPECTED_REF}'\n"
                "  Reason: first-party reusable workflows must use the @v1 version\n"
                "  tag, not a SHA (AGENTS.md §Release channel tags)."
            )
        elif not ref.endswith(EXPECTED_REF):
            failures.append(
                f"  Wrong ref: {ref!r}\n"
                f"  Expected:  '{REUSABLE}{EXPECTED_REF}'"
            )

    if failures:
        print(f"FAIL: {WORKFLOW} does not reference the reusable with {EXPECTED_REF}:")
        for msg in failures:
            print(msg)
        return 1

    print(f"PASS: {WORKFLOW} correctly references {REUSABLE}{EXPECTED_REF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
