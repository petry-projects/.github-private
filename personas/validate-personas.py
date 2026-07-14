#!/usr/bin/env python3
"""Validate agentic persona manifests.

Every `personas/<id>/persona.yml` is validated against the canonical persona
schema (owned by petry-projects/.github) PLUS the cross-invariants the JSON
schema cannot express on its own:

  * `id` == the persona directory name == `canary.agent`
  * every `definition.layers[].path` exists on disk
  * a `framework-agent` layer's `framework.vendor_pin` actually appears in the
    referenced `frameworks/<name>/VENDOR.md` (pin ↔ vendored version agree)
  * `evals.path` exists and carries both `dev/cases.jsonl` and
    `holdout/cases.jsonl`
  * a non-`draft` persona has a matching `agents.<id>` entry in the canary ring
    registry (`canary-rings.json`), so status never outruns registration

Schema resolution order:
  1. --schema PATH                     (explicit local file; used by tests)
  2. $PERSONA_SCHEMA_FILE              (local file)
  3. fetch from petry-projects/.github at $PERSONA_SCHEMA_REF (default: main)

The schema lives in the org standards repo, not here — this validator reads it
the same way any consumer repo reads a published standard. When run against the
canary registry check, the registry is read the same way.

Usage:
  validate-personas.py [personas_root] [--schema PATH] [--registry PATH]

Exit 0 on success; non-zero with a diagnostic on the first failure class found.
"""
import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path
from typing import NoReturn

SCHEMA_REPO = "petry-projects/.github"
SCHEMA_PATH_IN_REPO = "standards/personas/persona.schema.json"
REGISTRY_PATH_IN_REPO = "standards/canary-rings.json"
MANIFEST_NAME = "persona.yml"


def fail(msg: str) -> NoReturn:
    print(f"::error::persona manifest invalid: {msg}", file=sys.stderr)
    sys.exit(1)


def _raw_url(ref: str, path: str) -> str:
    return f"https://raw.githubusercontent.com/{SCHEMA_REPO}/{ref}/{path}"


def _fetch_json(path: str, what: str) -> dict:
    """Fetch a JSON file from the standards repo, trying the configured ref then
    falling back to main (self-healing once a feature branch merges/deletes)."""
    ref = os.environ.get("PERSONA_SCHEMA_REF", "main")
    refs = [ref] if ref == "main" else [ref, "main"]
    last = None
    for r in refs:
        url = _raw_url(r, path)
        try:
            with urllib.request.urlopen(url, timeout=20) as resp:  # noqa: S310 (fixed host)
                return json.loads(resp.read().decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            last = f"{url}: {exc}"
    fail(f"could not fetch {what} from {SCHEMA_REPO} (tried {', '.join(refs)}): {last}. "
         f"Ensure {SCHEMA_REPO} carries {path}, or pass a local override.")


def load_schema(explicit: str | None) -> dict:
    candidate = explicit or os.environ.get("PERSONA_SCHEMA_FILE")
    if candidate:
        try:
            return json.loads(Path(candidate).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"could not read/parse schema {candidate}: {exc}")
    return _fetch_json(SCHEMA_PATH_IN_REPO, "persona schema")


def load_registry(explicit: str | None) -> dict:
    candidate = explicit or os.environ.get("PERSONA_REGISTRY_FILE")
    if candidate:
        try:
            return json.loads(Path(candidate).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"could not read/parse registry {candidate}: {exc}")
    return _fetch_json(REGISTRY_PATH_IN_REPO, "canary registry")


def registry_has_agent(registry: dict, persona_id: str) -> bool:
    agents = registry.get("agents", {})
    return isinstance(agents, dict) and persona_id in agents


def discover_manifests(root: Path) -> list[Path]:
    return sorted(p / MANIFEST_NAME for p in root.iterdir()
                  if p.is_dir() and (p / MANIFEST_NAME).is_file())


def check_invariants(manifest: dict, manifest_path: Path, repo_root: Path,
                     registry_arg: str | None) -> None:
    persona_dir = manifest_path.parent
    pid = manifest["id"]

    if pid != persona_dir.name:
        fail(f"{manifest_path}: id '{pid}' != directory name '{persona_dir.name}'")
    if manifest["canary"]["agent"] != pid:
        fail(f"{manifest_path}: canary.agent '{manifest['canary']['agent']}' != id '{pid}'")

    for i, layer in enumerate(manifest["definition"]["layers"]):
        lpath = repo_root / layer["path"]
        if not lpath.exists():
            fail(f"{manifest_path}: definition.layers[{i}].path '{layer['path']}' does not exist")
        if layer["kind"] == "framework-agent":
            fw = layer["framework"]
            vendor_md = repo_root / "frameworks" / fw["name"] / "VENDOR.md"
            if not vendor_md.is_file():
                fail(f"{manifest_path}: framework '{fw['name']}' has no VENDOR.md at {vendor_md}")
            if fw["vendor_pin"] not in vendor_md.read_text(encoding="utf-8"):
                fail(f"{manifest_path}: vendor_pin '{fw['vendor_pin']}' not found in {vendor_md} "
                     f"(manifest pin and vendored version disagree)")

    evals_dir = repo_root / manifest["evals"]["path"] if "evals" in manifest else None
    if evals_dir is not None:
        for split in ("dev", "holdout"):
            cases = evals_dir / split / "cases.jsonl"
            if not cases.is_file():
                fail(f"{manifest_path}: evals.path missing {split} split (expected {cases})")

    if manifest["status"] != "draft":
        registry = load_registry(registry_arg)
        if not registry_has_agent(registry, pid):
            fail(f"{manifest_path}: status '{manifest['status']}' is past draft but no "
                 f"agents.{pid} entry exists in {REGISTRY_PATH_IN_REPO} (register once)")


def main() -> None:
    ap = argparse.ArgumentParser(description="Validate persona manifests.")
    ap.add_argument("root", nargs="?", default="personas",
                    help="personas root directory (default: personas)")
    ap.add_argument("--schema", help="path to a local persona.schema.json (else fetched)")
    ap.add_argument("--registry", help="path to a local canary-rings.json (else fetched)")
    args = ap.parse_args()

    try:
        import yaml
    except ImportError:
        fail("PyYAML not installed (pip install pyyaml)")
    try:
        import jsonschema
    except ImportError:
        fail("jsonschema not installed (pip install 'jsonschema>=4')")

    root = Path(args.root)
    if not root.is_dir():
        print(f"no personas root at {root} — nothing to validate.")
        return
    repo_root = root.parent

    manifests = discover_manifests(root)
    if not manifests:
        print(f"no persona manifests found under {root} — nothing to validate.")
        return

    schema = load_schema(args.schema)
    jsonschema.Draft202012Validator.check_schema(schema)
    validator = jsonschema.Draft202012Validator(schema)

    for manifest_path in manifests:
        try:
            manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as exc:
            fail(f"could not read/parse {manifest_path}: {exc}")
        error = next(validator.iter_errors(manifest), None)
        if error is not None:
            loc = "/".join(str(p) for p in error.absolute_path) or "<root>"
            fail(f"{manifest_path}: schema violation at {loc}: {error.message}")
        check_invariants(manifest, manifest_path, repo_root, args.registry)

    print(f"OK: {len(manifests)} persona manifest(s) valid, invariants hold.")


if __name__ == "__main__":
    main()
