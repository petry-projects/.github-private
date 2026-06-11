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
import sys
from pathlib import Path
from typing import NoReturn


def fail(msg: str) -> NoReturn:
    # stdout (not stderr) so the reason is visible in workflow logs and capturable
    # by tests; the ::error:: prefix still renders as a GitHub annotation.
    print(f"::error::initiative plan invalid: {msg}")
    sys.exit(1)


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

    print(f"plan OK: {len(stories)} stories, "
          f"{sum(1 for i in graph if not graph[i])} entry-point(s), acyclic.")


if __name__ == "__main__":
    main()
