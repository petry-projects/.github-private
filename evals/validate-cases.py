#!/usr/bin/env python3
"""Validate held-out eval cases under evals/<skill>/{dev,holdout}/cases.jsonl.

This enforces the held-out-hygiene contract (#691, epic #581): the proposer only
ever sees the *dev* split, and the gate scores against the *holdout* split. For
that to mean anything, a case must never live in both splits — otherwise the
proposer could see (and overfit to) a case the gate later scores against.

Per skill directory under the eval root, this checks:

  - both a dev/ and a holdout/ split exist (each with a cases.jsonl)
  - every non-blank line is a JSON object
  - every case has a non-empty string `id`
  - ids are unique within each split
  - ids are disjoint across the two splits (no case appears in both)

This is data/structure/validation only — it never invokes a scorer or a model
(consistent with #582). The case payload schema beyond `id` is owned by the
scorer story (#583); this validator is deliberately agnostic to it.

Usage: validate-cases.py [eval_root]
  eval_root defaults to the directory containing this script (the evals/ tree).
Exit 0 on success; non-zero with a message on failure.
"""
import json
import sys
from pathlib import Path
from typing import NoReturn

SPLITS = ("dev", "holdout")
CASES_FILENAME = "cases.jsonl"


def fail(msg: str) -> NoReturn:
    # Write to stderr so the reason is visible in workflow logs and capturable
    # by tests; the ::error:: prefix still renders as a GitHub annotation.
    print(f"::error::eval cases invalid: {msg}", file=sys.stderr)
    sys.exit(1)


def load_split_ids(cases_path: Path) -> list[str]:
    """Parse a cases.jsonl file and return its ordered list of case ids.

    Fails (exits non-zero) on malformed JSON, non-object lines, missing/empty
    ids, or duplicate ids within this single file.
    """
    try:
        raw = cases_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"could not read {cases_path}: {exc}")

    ids: list[str] = []
    seen: set[str] = set()
    for lineno, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue  # blank lines are allowed as separators
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
    """Validate one skill's dev/holdout split. Returns the total case count."""
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
    """A skill is any direct subdirectory that has a dev/ or holdout/ split."""
    skills = []
    for child in sorted(eval_root.iterdir()):
        if not child.is_dir():
            continue
        if any((child / split).is_dir() for split in SPLITS):
            skills.append(child)
    return skills


def main() -> None:
    eval_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent
    if not eval_root.is_dir():
        fail(f"eval root is not a directory: {eval_root}")

    skills = discover_skills(eval_root)
    if not skills:
        fail(f"no skills found under {eval_root} "
             f"(expected <skill>/dev/ and <skill>/holdout/ subdirectories)")

    total = 0
    for skill_dir in skills:
        total += validate_skill(skill_dir)

    print(f"OK: {len(skills)} skill(s), {total} case(s) across dev+holdout, "
          f"no cross-split id overlap.")


if __name__ == "__main__":
    main()
