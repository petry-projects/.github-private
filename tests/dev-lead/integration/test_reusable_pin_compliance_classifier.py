#!/usr/bin/env python3
"""Classifier unit/behavior tests for the reusable-pin compliance scanner (#1493).

Exercises the #1184 legacy→major-scoped migration semantics that #687 ACs 7–9 add
on top of the original #687 scanner:

  - AC 7: the *canonical* form is the major-scoped channel `<name>/v<MAJOR>-<tier>`
    (or an immutable `<name>/vX.Y.Z`); a bare `<name>/<tier>` is NOT canonical.
  - AC 8: a bare `<name>/<tier>` is classified DEPRECATED — reported with file, line,
    and the major-scoped ref it should become — and during the migration window this
    is a WARNING, not a failure (exit 0 so `main` stays green).
  - AC 9: every legacy pin is inventoried with counts.

Standalone runner (repo convention: `python3 <file>`, exit 0 = pass). No pytest.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCANNER = HERE / "test_reusable_pin_compliance.py"

_spec = importlib.util.spec_from_file_location("pin_scanner", SCANNER)
assert _spec and _spec.loader
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)  # type: ignore[union-attr]

_failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        _failures.append(msg)
        print(f"  FAIL: {msg}")
    else:
        print(f"  ok: {msg}")


def test_classify_ref_canonical() -> None:
    print("test_classify_ref_canonical")
    for ref in (
        "dev-lead/v1-stable",
        "pr-review/v2-next",
        "agent-shield/v2-ring0",
        "ci-failure-analyst/v0-stable",
        "dev-lead/v1.2.3",
        "v1",
    ):
        status, detail = mod.classify_ref(ref)
        check(status == "ok" and detail is None, f"{ref!r} is canonical (ok) -> {status,detail}")


def test_classify_ref_deprecated() -> None:
    print("test_classify_ref_deprecated")
    cases = {
        "pr-review/next": "pr-review/v<MAJOR>-next",
        "ci-failure-analyst/stable": "ci-failure-analyst/v<MAJOR>-stable",
        "dev-lead/ring1": "dev-lead/v<MAJOR>-ring1",
    }
    for ref, want in cases.items():
        status, detail = mod.classify_ref(ref)
        check(
            status == "deprecated" and detail == want,
            f"{ref!r} is DEPRECATED with suggestion {want!r} -> {status,detail}",
        )


def test_classify_ref_violation() -> None:
    print("test_classify_ref_violation")
    for ref in (
        "",
        "a" * 40,  # SHA
        "main",
        "dev-lead/main",
        "not-a-tag",
    ):
        status, _ = mod.classify_ref(ref)
        check(status == "violation", f"{ref!r} is a violation -> {status}")


def _write(tmp: Path, name: str, body: str) -> Path:
    p = tmp / name
    p.write_text(body, encoding="utf-8")
    return p


def test_scan_file_captures_line_and_suggestion() -> None:
    print("test_scan_file_captures_line_and_suggestion")
    body = (
        "name: x\n"
        "on: [push]\n"
        "jobs:\n"
        "  review:\n"
        "    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations, f"no hard violations -> {violations}")
        check(checked == 1, f"one first-party ref checked -> {checked}")
        check(canonical == 0, f"zero canonical -> {canonical}")
        check(len(deprecations) == 1, f"one deprecation -> {len(deprecations)}")
        if deprecations:
            dep = deprecations[0]
            check(dep["line"] == 5, f"deprecation at line 5 -> {dep.get('line')}")
            check(dep["ref"] == "pr-review/next", f"ref recorded -> {dep.get('ref')}")
            check(
                dep["suggestion"] == "pr-review/v<MAJOR>-next",
                f"suggestion recorded -> {dep.get('suggestion')}",
            )


def test_scan_file_canonical_passes_clean() -> None:
    print("test_scan_file_canonical_passes_clean")
    body = (
        "jobs:\n"
        "  dl:\n"
        "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        violations, deprecations, checked, canonical = mod.scan_file(p)
        check(not violations and not deprecations, "canonical pin is clean")
        check(canonical == 1, f"one canonical -> {canonical}")


def _run_cli(files: list[str], env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, str(SCANNER), *files],
        capture_output=True,
        text=True,
        env=env,
    )


def test_cli_deprecated_is_warning_not_failure() -> None:
    print("test_cli_deprecated_is_warning_not_failure")
    body = (
        "jobs:\n"
        "  review:\n"
        "    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/next\n"
    )
    with tempfile.TemporaryDirectory() as d:
        summary = Path(d) / "summary.md"
        p = _write(Path(d), "wf.yml", body)
        proc = _run_cli([str(p)], {"GITHUB_STEP_SUMMARY": str(summary)})
        check(proc.returncode == 0, f"DEPRECATED-only exits 0 (main stays green) -> {proc.returncode}\n{proc.stdout}")
        check("DEPRECATED" in proc.stdout, "output labels the pin DEPRECATED")
        check("pr-review/v<MAJOR>-next" in proc.stdout, "output shows the suggested major-scoped ref")
        # AC 9: counts land in the run summary.
        text = summary.read_text(encoding="utf-8") if summary.exists() else ""
        check("legacy" in text.lower() and "1" in text, f"run summary carries the legacy count -> {text!r}")


def test_cli_sha_still_fails() -> None:
    print("test_cli_sha_still_fails")
    body = (
        "jobs:\n"
        "  dl:\n"
        "    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@"
        + "a" * 40
        + "\n"
    )
    with tempfile.TemporaryDirectory() as d:
        p = _write(Path(d), "wf.yml", body)
        proc = _run_cli([str(p)])
        check(proc.returncode == 1, f"SHA pin still fails -> {proc.returncode}")


def main() -> int:
    test_classify_ref_canonical()
    test_classify_ref_deprecated()
    test_classify_ref_violation()
    test_scan_file_captures_line_and_suggestion()
    test_scan_file_canonical_passes_clean()
    test_cli_deprecated_is_warning_not_failure()
    test_cli_sha_still_fails()
    if _failures:
        print(f"\nFAIL: {len(_failures)} classifier assertion(s) failed")
        return 1
    print("\nPASS: reusable-pin classifier migration semantics (#1493)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
