#!/usr/bin/env python3
"""Compliance test: pr-review-mention.yml must use secrets: inherit.

The org standard template (petry-projects/.github/standards/workflows/pr-review-mention.yml)
uses `secrets: inherit` so the reusable receives all available org secrets without
explicit mapping. Explicit secret expansion (secrets.GH_PAT_WORKFLOWS etc.) causes
`action_required` outcomes when the calling context cannot expand one or both secrets,
which the Fleet Monitor counts as failures.

Run: python3 tests/test_pr_review_mention_stub.py
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

WORKFLOW_PATH = ".github/workflows/pr-review-mention.yml"
JOB_KEY = "pr-review-mention"
REUSABLE_REF = "petry-projects/.github/.github/workflows/pr-review-mention-reusable.yml"


def load_workflow() -> dict:
    with open(WORKFLOW_PATH, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def main() -> int:
    try:
        wf = load_workflow()
    except FileNotFoundError:
        print(f"FAIL: {WORKFLOW_PATH} not found — run from repo root", file=sys.stderr)
        return 1

    jobs = wf.get("jobs") or {}
    job = jobs.get(JOB_KEY)
    if job is None:
        print(f"FAIL: no job named '{JOB_KEY}' in {WORKFLOW_PATH}")
        return 1

    uses = job.get("uses", "")
    if REUSABLE_REF not in uses:
        print(f"FAIL: job '{JOB_KEY}' does not call the expected reusable")
        print(f"  expected: uses containing '{REUSABLE_REF}'")
        print(f"  actual:   {uses!r}")
        return 1
    print(f"OK: uses = {uses!r}")

    secrets_val = job.get("secrets")
    if secrets_val != "inherit":
        print(f"FAIL: job '{JOB_KEY}' must use 'secrets: inherit'")
        print()
        print("  Explicit secret mappings cause 'action_required' outcomes when the")
        print("  calling context cannot expand the listed secrets. Fix: replace the")
        print("  explicit 'secrets:' block with 'secrets: inherit'.")
        return 1
    print("OK: secrets: inherit")

    print()
    print(f"PASS: {WORKFLOW_PATH} conforms to the org standard stub contract.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
