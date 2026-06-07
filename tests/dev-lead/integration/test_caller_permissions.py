#!/usr/bin/env python3
"""Validate the dev-lead caller<->reusable GITHUB_TOKEN permission contract.

A reusable workflow's jobs can only use token permissions that the CALLER grants
at `jobs.<id>.permissions`. If any reusable job requests MORE than the caller
template grants, every consumer pinned to that reusable fails at startup
("startup_failure") — there is no runtime error, the run is simply invalid.

This is exactly what happened in petry-projects/.github#402: #435 added
`statuses: read` to the reusable's job permissions but the caller template was
never updated, so every @main consumer broke (.github was 15/15 startup_failure).

The contract: for every permission scope, the caller template must grant a level
>= the maximum any reusable job requests. This guard fails the build the moment
the reusable asks for something the template doesn't grant — at the PR that edits
the reusable, in the reusable's own repo, where the breaking change is made.

Reads:
  - reusable:  .github/workflows/dev-lead-reusable.yml   (this repo, local)
  - template:  standards/workflows/dev-lead.yml          (petry-projects/.github, fetched)
"""
from __future__ import annotations

import base64
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs it; clear message if not
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

LEVELS = {"none": 0, "read": 1, "write": 2}
INV = {v: k for k, v in LEVELS.items()}

TEMPLATE_REPO = "petry-projects/.github"
TEMPLATE_PATH = "standards/workflows/dev-lead.yml"
REUSABLE_PATH = ".github/workflows/dev-lead-reusable.yml"


def lvl(value) -> int:
    return LEVELS.get(str(value).strip().lower(), 0)


def load_local(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def fetch_template() -> dict:
    """Fetch the caller template from the public petry-projects/.github repo."""
    res = subprocess.run(
        ["gh", "api", f"repos/{TEMPLATE_REPO}/contents/{TEMPLATE_PATH}", "--jq", ".content"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        print(f"FAIL: could not fetch {TEMPLATE_REPO}:{TEMPLATE_PATH}\n{res.stderr.strip()}",
              file=sys.stderr)
        sys.exit(2)
    return yaml.safe_load(base64.b64decode(res.stdout))


def reusable_required(reusable: dict) -> dict[str, int]:
    """Max level each permission scope is requested across all reusable jobs."""
    required: dict[str, int] = {}
    for job in (reusable.get("jobs") or {}).values():
        perms = job.get("permissions") if isinstance(job, dict) else None
        if not isinstance(perms, dict):
            continue  # no per-job block => inherits top-level `permissions: {}` (none)
        for scope, level in perms.items():
            required[scope] = max(required.get(scope, 0), lvl(level))
    return required


def caller_granted(template: dict) -> dict[str, int] | None:
    """Permissions the template grants on the job that calls the reusable."""
    for job in (template.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        if "dev-lead-reusable" in str(job.get("uses", "")):
            perms = job.get("permissions") or {}
            return {scope: lvl(level) for scope, level in perms.items()}
    return None


def main() -> int:
    reusable = load_local(REUSABLE_PATH)
    template = fetch_template()

    required = reusable_required(reusable)
    granted = caller_granted(template)

    if granted is None:
        print(f"FAIL: no job in {TEMPLATE_REPO}:{TEMPLATE_PATH} calls dev-lead-reusable")
        return 1

    failures = []
    for scope, need in sorted(required.items()):
        if need == 0:
            continue
        have = granted.get(scope, 0)
        status = "OK" if have >= need else "MISSING"
        print(f"  [{status}] {scope}: reusable needs {INV[need]}, template grants {INV.get(have, 'none')}")
        if have < need:
            failures.append((scope, need, have))

    print()
    if failures:
        print("FAIL: caller template under-grants permissions the reusable requests.")
        for scope, need, have in failures:
            print(f"  - add `{scope}: {INV[need]}` to {TEMPLATE_REPO}:{TEMPLATE_PATH} "
                  f"jobs.dev-lead.permissions (currently {INV.get(have, 'none')})")
        print("\nWithout it, every @main consumer fails at startup (startup_failure).")
        return 1

    print("PASS: caller template grants >= every permission the reusable jobs request.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
