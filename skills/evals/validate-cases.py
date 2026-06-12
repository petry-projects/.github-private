#!/usr/bin/env python3
"""Validate a held-out eval-case set (JSONL) against case.schema.json.

Each line of the .jsonl file is one case object. Beyond per-line JSON-Schema
structural checks this enforces the one cross-line invariant the held-out set
depends on:

  - case ids are unique (a duplicate id silently shadows a case)

This is intentionally a *validator only* — no scorer, no model invocation. The
held-out cases are the trust anchor of skill-quality measurement; this tool
exists so the set can be checked in CI the same way scripts/initiative-planner
checks plan.schema.json (python jsonschema, draft 2020-12).

Usage: validate-cases.py <cases.jsonl> [schema.json]
Exit 0 on success; non-zero with a message on failure.
"""
import json
import sys
from pathlib import Path
from typing import NoReturn


def fail(msg: str) -> NoReturn:
    # stdout (not stderr) so the reason is visible in workflow logs and capturable
    # by tests; the ::error:: prefix still renders as a GitHub annotation.
    print(f"::error::eval cases invalid: {msg}")
    sys.exit(1)


def main() -> None:
    if len(sys.argv) < 2:
        fail("usage: validate-cases.py <cases.jsonl> [schema.json]")
    cases_path = Path(sys.argv[1])
    schema_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).with_name("case.schema.json")

    try:
        import jsonschema
    except ImportError:
        fail("jsonschema not installed (pip install 'jsonschema>=4')")

    try:
        schema = json.loads(schema_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read/parse schema {schema_path}: {exc}")

    try:
        raw = cases_path.read_text()
    except OSError as exc:
        fail(f"could not read {cases_path}: {exc}")

    validator = jsonschema.Draft202012Validator(schema)
    ids: dict[str, int] = {}
    count = 0
    for lineno, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue  # tolerate blank separator lines
        try:
            case = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"line {lineno}: not valid JSON: {exc}")
        error = next(validator.iter_errors(case), None)
        if error is not None:
            loc = "/".join(str(p) for p in error.absolute_path) or "<root>"
            fail(f"line {lineno}: schema violation at {loc}: {error.message}")
        case_id = case["id"]
        if case_id in ids:
            fail(f"line {lineno}: duplicate case id '{case_id}' (first seen on line {ids[case_id]})")
        ids[case_id] = lineno
        count += 1

    if count == 0:
        fail(f"{cases_path} contains no cases")

    print(f"cases OK: {count} case(s), unique ids, schema-valid.")


if __name__ == "__main__":
    main()
