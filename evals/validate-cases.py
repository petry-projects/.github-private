#!/usr/bin/env python3
"""Validate held-out eval cases.

Two modes, selected by the type of the argument:

  File mode:  validate-cases.py <cases.jsonl> [schema.json]
    Validates a single JSONL file against case.schema.json (JSON-Schema
    2020-12). Checks per-case schema compliance and uniqueness of case ids
    within the file. Outputs "cases OK: N case(s)...".

  Directory mode:  validate-cases.py <eval_root>
    Validates the dev/holdout split hygiene for every skill directory under
    eval_root. Per skill: both dev/ and holdout/ splits must exist, every
    case must have a non-empty unique id, and ids must be disjoint across
    splits. Outputs "OK: N skill(s)...".

Exit 0 on success; non-zero with a diagnostic on failure.
"""
import json
import sys
from pathlib import Path
from typing import NoReturn

SPLITS = ("dev", "holdout")
CASES_FILENAME = "cases.jsonl"


def fail(msg: str) -> NoReturn:
    print(f"::error::eval cases invalid: {msg}", file=sys.stderr)
    sys.exit(1)


# ── File mode: schema + id-uniqueness validation ──────────────────────────────

def validate_file(cases_path: Path, schema_path: Path) -> None:
    try:
        import jsonschema
    except ImportError:
        fail("jsonschema not installed (pip install 'jsonschema>=4')")

    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read/parse schema {schema_path}: {exc}")

    try:
        raw = cases_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"could not read {cases_path}: {exc}")

    validator = jsonschema.Draft202012Validator(schema)
    ids: dict[str, int] = {}
    count = 0
    for lineno, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue
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


# ── Directory mode: dev/holdout split hygiene ─────────────────────────────────

def load_split_ids(cases_path: Path) -> list[str]:
    try:
        raw = cases_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"could not read {cases_path}: {exc}")

    ids: list[str] = []
    seen: set[str] = set()
    for lineno, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            case = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"{cases_path}:{lineno}: invalid JSON: {exc}")
        if not isinstance(case, dict):
            fail(f"{cases_path}:{lineno}: each case line must be a JSON object")
        if "id" not in case:
            fail(f"{cases_path}:{lineno}: case is missing required field 'id'")
        cid = case["id"]
        if not isinstance(cid, str) or not cid.strip():
            fail(f"{cases_path}:{lineno}: case 'id' must be a non-empty string")
        if cid in seen:
            fail(f"{cases_path}:{lineno}: duplicate id '{cid}' within this split")
        seen.add(cid)
        ids.append(cid)
    return ids


def validate_skill(skill_dir: Path) -> int:
    split_ids: dict[str, list[str]] = {}
    for split in SPLITS:
        cases_path = skill_dir / split / CASES_FILENAME
        if not cases_path.is_file():
            fail(f"skill '{skill_dir.name}' is missing its {split} split "
                 f"(expected {cases_path})")
        split_ids[split] = load_split_ids(cases_path)

    overlap = set(split_ids["dev"]) & set(split_ids["holdout"])
    if overlap:
        joined = ", ".join(sorted(overlap))
        fail(f"skill '{skill_dir.name}': id(s) appear in both dev and holdout "
             f"splits (a case must not be in both): {joined}")

    return sum(len(ids) for ids in split_ids.values())


def discover_skills(eval_root: Path) -> list[Path]:
    skills = []
    for child in sorted(eval_root.iterdir()):
        if not child.is_dir():
            continue
        if any((child / split).is_dir() for split in SPLITS):
            skills.append(child)
    return skills


def validate_directory(eval_root: Path) -> None:
    skills = discover_skills(eval_root)
    if not skills:
        fail(f"no skills found under {eval_root} "
             f"(expected <skill>/dev/ and <skill>/holdout/ subdirectories)")

    total = 0
    for skill_dir in skills:
        total += validate_skill(skill_dir)

    print(f"OK: {len(skills)} skill(s), {total} case(s) across dev+holdout, "
          f"no cross-split id overlap.")

# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) < 2:
        validate_directory(Path(__file__).parent)
        return

    arg = Path(sys.argv[1])
    if arg.is_file():
        schema_path = (Path(sys.argv[2]) if len(sys.argv) > 2
                       else Path(__file__).with_name("case.schema.json"))
        validate_file(arg, schema_path)
    elif arg.is_dir():
        validate_directory(arg)
    else:
        fail(f"argument is not a file or directory: {arg}")


if __name__ == "__main__":
    main()
