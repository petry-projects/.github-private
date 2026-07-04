#!/usr/bin/env python3
"""Validate an initiative plan JSON against plan.schema.json.

Beyond JSON-Schema structural checks, enforces the semantic invariants the
downstream sub-issue/blocked_by DAG depends on:

  - story ids are unique
  - every blocked_by edge references a story id that exists in the plan
  - no story blocks itself
  - the blocked_by graph is acyclic (a cycle = a deadlock the driver can
    never release)
  - at least one story has no blockers (an entry point the driver can start)

Usage: validate-plan.py <plan.json> [schema.json]
Exit 0 on success; non-zero with a message on failure.
"""
import json
import subprocess
import sys
from pathlib import Path
from typing import NoReturn


def fail(msg: str) -> NoReturn:
    # stdout (not stderr) so the reason is visible in workflow logs and capturable
    # by tests; the ::error:: prefix still renders as a GitHub annotation.
    print(f"::error::initiative plan invalid: {msg}")
    sys.exit(1)


# Extensions that mark a bare (slash-less) citation as a file path rather than
# prose, e.g. "AGENTS.md#standards". Kept conservative on purpose.
_PATH_EXTENSIONS = (
    ".py", ".sh", ".md", ".yml", ".yaml", ".json", ".tsv", ".txt", ".toml", ".cfg",
)


def repo_root() -> Path:
    """Resolve the repo root explicitly, never from the current working directory.

    Prefer `git rev-parse --show-toplevel` (run from the script's own directory so
    it is independent of cwd); fall back to the script location when git is
    unavailable (validate-plan.py lives at scripts/initiative-planner/, so the
    root is two parents up).
    """
    here = Path(__file__).resolve()
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=here.parent,
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(out.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return here.parents[2]


def looks_like_path(entry: str) -> bool:
    """Decide whether a references/target_surface string is a repo path vs prose.

    references/target_surface are free-form strings, so they mix real paths
    ('scripts/engine.sh#tier-routing') with prose ('discussion #593', URLs,
    descriptive notes). We only enforce existence for entries that clearly name a
    file, and skip everything else to avoid false failures:

      - skip URLs (start with 'http')
      - skip bare cross-references ('discussion #593', anchor-only '#foo')
      - treat as a path only if it contains a '/' or ends in a known extension.
    """
    s = entry.strip()
    if not s or s.startswith(("http", "#", "discussion")):
        return False
    candidate = s.split("#", 1)[0].strip()
    if not candidate or len(candidate.split()) > 1:
        return False
    if "/" in candidate:
        return True
    return candidate.lower().endswith(_PATH_EXTENSIONS)


def check_grounding(stories: list, root: Path) -> None:
    """Fail if any path-like references/target_surface entry does not resolve.

    Strips the first '#anchor' before the existence test (the anchor points at a
    section within the file, not a separate path).
    """
    for s in stories:
        for field in ("references", "target_surface"):
            for entry in s.get(field, []) or []:
                if not looks_like_path(entry):
                    continue
                rel = entry.split("#", 1)[0].strip().lstrip("/")
                if not (root / rel).exists():
                    fail(f"story {s['id']} cites unresolved path in {field}: {rel}")


def main() -> None:
    if len(sys.argv) < 2:
        fail("usage: validate-plan.py <plan.json> [schema.json]")
    plan_path = Path(sys.argv[1])
    schema_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).with_name("plan.schema.json")

    try:
        plan = json.loads(plan_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read/parse {plan_path}: {exc}")

    try:
        import jsonschema
    except ImportError:
        fail("jsonschema not installed (pip install 'jsonschema>=4')")

    try:
        schema = json.loads(schema_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read/parse schema {schema_path}: {exc}")
    try:
        jsonschema.validate(plan, schema)
    except jsonschema.ValidationError as exc:
        loc = "/".join(str(p) for p in exc.absolute_path) or "<root>"
        fail(f"schema violation at {loc}: {exc.message}")

    stories = plan["stories"]
    ids = [s["id"] for s in stories]
    if len(ids) != len(set(ids)):
        fail("story ids are not unique")
    id_set = set(ids)

    graph = {}
    for s in stories:
        deps = s.get("blocked_by", []) or []
        for d in deps:
            if d == s["id"]:
                fail(f"story {s['id']} blocks itself")
            if d not in id_set:
                fail(f"story {s['id']} blocked_by {d}, which is not a story id in this plan")
        graph[s["id"]] = list(deps)

    has_startable_entry = any(not graph[i] for i in graph)
    if not has_startable_entry:
        fail("no entry-point story (every story has a blocker) — the initiative can never start")

    # Cycle detection via DFS colouring.
    WHITE, GREY, BLACK = 0, 1, 2
    color = {i: WHITE for i in graph}

    def visit(node: int, stack: list) -> None:
        color[node] = GREY
        stack.append(node)
        for nxt in graph[node]:
            if color[nxt] == GREY:
                cycle = " -> ".join(str(x) for x in stack[stack.index(nxt):] + [nxt])
                fail(f"blocked_by graph has a cycle: {cycle}")
            if color[nxt] == WHITE:
                visit(nxt, stack)
        stack.pop()
        color[node] = BLACK

    for i in graph:
        if color[i] == WHITE:
            visit(i, [])

    # open_questions object form may carry affected_story_ids (critic findings
    # routed here by route-findings.sh); each must reference a real story id.
    # It may also carry a proposed_story (#706): an accepted finding must have
    # one, else acceptance would silently materialize nothing.
    for q in plan.get("open_questions", []) or []:
        if isinstance(q, dict):
            for sid in q.get("affected_story_ids", []) or []:
                if sid not in id_set:
                    fail(f"open question affected_story_ids references {sid}, "
                         "which is not a story id in this plan")
            if q.get("accepted") and not q.get("proposed_story"):
                fail("open question is accepted but carries no proposed_story to "
                     "materialize — acceptance would create nothing")

    check_grounding(stories, repo_root())

    print(f"plan OK: {len(stories)} stories, "
          f"{sum(1 for i in graph if not graph[i])} entry-point(s), acyclic.")


if __name__ == "__main__":
    main()
