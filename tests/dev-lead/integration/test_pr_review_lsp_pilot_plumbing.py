#!/usr/bin/env python3
"""Validate the LSP-pilot capture/decoupling plumbing in the pr-review workflows.

Issue #1031 (story #844, epic #839) closes two gaps that left the LSP pilot inert
in real CI:

  * Gap 1 — the capture gate is never plumbed. engine.sh's `_lsp_pilot_active()`
    and review-one-pr.sh's emit trap gate on the ENV var `LSP_PILOT_ENABLED`, but
    the workflow only referenced the repo variable `vars.LSP_PILOT_ENABLED`
    (never exported to the job env). This guards that pr-review.yml exports
    `LSP_PILOT_ENABLED` to the review job so a production run actually captures a
    transcript and emits a `lsp_pilot_run` record.

  * Gap 2 — capture and LSP wiring can't be decoupled. This guards that an
    independent `lsp_pilot_variant` (on|off|none) control exists: `on` wires the
    LSP MCP (lsp-on/B leg), `off` captures without wiring (lsp-off/A control leg),
    and the two LSP-wiring steps are gated so `off` skips them.

  * AC #5 (CORRECTED after incident 2026-07-03 / PR #1048) — the ring-0 trigger
    stub pr-review-trigger.yml pins the reusable at `@pr-review/next`. Forwarding
    `lsp_pilot_variant` to that channel BEFORE it declares the input makes every
    review `startup_fail` (an undeclared `with:` key is an invalid workflow). So
    the stub must NOT declare/forward the input until `pr-review/next` is advanced
    (via cut-release.sh) to a commit that declares it. This guard now enforces that
    channel-safety invariant (stub must not forward ahead of the pinned channel);
    the original "must forward" form (#1034) is what took production down.

Off-pilot (neither var nor input set) must stay byte-for-byte unchanged (AC #4):
the exported env resolves to empty and the wiring steps stay skipped.

Re-enable procedure for the stub-driven A/B: (1) advance `pr-review/next` to a
commit that declares the reusable `lsp_pilot_variant` input, (2) re-add the stub
dispatch input + forwarding, and (3) flip check_trigger below back to requiring
them (see git history at #1034 for the requiring form).
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    yaml = None

REUSABLE = ".github/workflows/pr-review.yml"
TRIGGER = ".github/workflows/pr-review-trigger.yml"
INPUT = "lsp_pilot_variant"


def _load(path: str):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _on(doc: dict | None):
    if not doc:
        return {}
    # PyYAML parses the bare `on:` key as the boolean True (YAML 1.1).
    return doc.get("on", doc.get(True)) or {}


def _review_job(doc: dict | None) -> dict:
    jobs = (doc or {}).get("jobs") or {}
    job = jobs.get("review")
    return job if isinstance(job, dict) else {}


def _steps(job: dict) -> list:
    steps = job.get("steps") or []
    return [s for s in steps if isinstance(s, dict)]


def check_reusable(fails: list[str]) -> None:
    doc = _load(REUSABLE)
    if not doc:
        fails.append(f"{REUSABLE}: failed to parse YAML (document is None/empty)")
        return
    on = _on(doc)

    # workflow_call input declared so a trigger stub can forward it.
    wc_inputs = ((on.get("workflow_call") or {}).get("inputs")) or {}
    if INPUT not in wc_inputs:
        fails.append(f"{REUSABLE}: workflow_call.inputs.{INPUT} is not declared")

    job = _review_job(doc)
    env = job.get("env") or {}

    enabled = str(env.get("LSP_PILOT_ENABLED", ""))
    if not enabled:
        fails.append(f"{REUSABLE}: review job env does not export LSP_PILOT_ENABLED (Gap 1)")
    else:
        # The capture gate must turn on for the legacy repo var AND for a
        # dispatched/defaulted on|off variant.
        for needle in ("vars.LSP_PILOT_ENABLED", "lsp_pilot_variant", "'on'", "'off'"):
            if needle not in enabled:
                fails.append(
                    f"{REUSABLE}: LSP_PILOT_ENABLED expression is missing {needle!r} "
                    f"(got: {enabled!r})"
                )

    variant = str(env.get("LSP_PILOT_VARIANT", ""))
    if not variant:
        fails.append(f"{REUSABLE}: review job env does not export LSP_PILOT_VARIANT (Gap 2)")
    else:
        if "lsp_pilot_variant" not in variant:
            fails.append(
                f"{REUSABLE}: LSP_PILOT_VARIANT must resolve from inputs.{INPUT} "
                f"(got: {variant!r})"
            )

    # The two LSP-wiring steps must run only for the legacy var OR variant 'on'
    # — never for the 'off' control leg (that's the decoupling).
    wiring_ids = {"lsp-cache"}
    wiring_names = {"Set up LSP pilot servers (opt-in)"}
    found = 0
    for step in _steps(job):
        is_wiring = step.get("id") in wiring_ids or step.get("name") in wiring_names
        if not is_wiring:
            continue
        found += 1
        cond = str(step.get("if", ""))
        if "== 'on'" not in cond:
            fails.append(
                f"{REUSABLE}: LSP-wiring step {step.get('name') or step.get('id')!r} "
                f"'if' does not gate on the 'on' variant (got: {cond!r})"
            )
        if "vars.LSP_PILOT_ENABLED == 'true'" not in cond:
            fails.append(
                f"{REUSABLE}: LSP-wiring step {step.get('name') or step.get('id')!r} "
                f"'if' dropped the legacy vars.LSP_PILOT_ENABLED gate (got: {cond!r})"
            )
    if found < 2:
        fails.append(
            f"{REUSABLE}: expected both LSP-wiring steps (cache + setup), found {found}"
        )


def check_trigger(fails: list[str]) -> None:
    # CHANNEL-SKEW SAFETY (incident 2026-07-03, PR #1048). The ring-0 stub pins the
    # reusable at `@pr-review/next`. A `with:` key the pinned reusable doesn't
    # declare is an invalid workflow → every review `startup_fail`s. The stub must
    # therefore NOT declare or forward `lsp_pilot_variant` until that channel is
    # advanced to a commit that declares it (then re-add both and flip this guard
    # back — see the module docstring's re-enable procedure).
    doc = _load(TRIGGER)
    if not doc:
        fails.append(f"{TRIGGER}: failed to parse YAML (document is None/empty)")
        return
    on = _on(doc)

    wd_inputs = ((on.get("workflow_dispatch") or {}).get("inputs")) or {}
    if INPUT in wd_inputs:
        fails.append(
            f"{TRIGGER}: workflow_dispatch.inputs.{INPUT} must NOT be declared while the "
            f"stub pins a channel that lacks it (channel-skew guard — see #1048)"
        )

    job = _review_job(doc)
    with_block = job.get("with") or {}
    if INPUT in with_block:
        fails.append(
            f"{TRIGGER}: review job must NOT forward {INPUT} to the pinned reusable — "
            f"forwarding an input @pr-review/next does not declare startup_fails every "
            f"review (channel-skew guard — see #1048)"
        )


def main() -> int:
    if yaml is None:
        print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
        return 2

    fails: list[str] = []
    for path, fn in ((REUSABLE, check_reusable), (TRIGGER, check_trigger)):
        try:
            fn(fails)
        except FileNotFoundError:
            fails.append(f"FAIL: {path} not found")

    if fails:
        print("FAIL: LSP-pilot plumbing checks failed:")
        for msg in fails:
            print(f"  - {msg}")
        return 1

    print("PASS: pr-review.yml exports the capture gate + variant and gates LSP wiring; "
          "pr-review-trigger.yml does not forward lsp_pilot_variant ahead of the pinned channel")
    return 0


if __name__ == "__main__":
    sys.exit(main())
