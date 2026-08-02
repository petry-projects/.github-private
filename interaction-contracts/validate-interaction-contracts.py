#!/usr/bin/env python3
"""Validate the per-role agentic interaction contracts.

Each agentic role declares a machine-readable interaction contract in the shape
fixed by docs/agentic-interaction-model.md §8.1 (Story 2 / #1404). Contracts live
in two standalone locations (§8.2 chose option (b) — standalone repo-local files,
NOT a persona.yml block, so there is no cross-repo persona.schema.json dependency):

  * personas/<id>/interaction.yml      — the 8 personas, co-located with persona.yml
  * interaction-contracts/<name>.yml   — the non-persona runtimes (dev-lead,
                                         pr-review, ci-failure-analyst)

This validator is HERMETIC (no network, no live schema fetch). It confirms every
contract is WELL-FORMED and internally consistent:

  * required fields present and correctly typed (schema_version, role, kind,
    workflows, interaction.{triggers,emits,idempotency_key,concurrency_lane,
    stop_markers,budget})
  * each declared workflow path exists on disk (the contract is bound to a real
    workflow, so it cannot be aspirational — the DEEP match of triggers against
    each workflow's actual on: block is Story 4's validate-interaction-model,
    #1406, not this check)
  * every timer declares cron + role (backstop|safety-net|self-heal) +
    justification + stop_condition + event_fast_path (§6.1/§6.2)
  * emits never names an event class the role also subscribes to — the
    well-formedness half of the #860 rule-1 self-trigger prohibition (§7): a
    `dispatch:<type>` emit must not appear as a subscribed
    `repository_dispatch:<type>` event, and no emit token may equal a bare
    subscribed event name

Usage:
  validate-interaction-contracts.py [repo_root]   (default: current directory)

Exit 0 on success; non-zero with a single diagnostic on the first failure found.
"""
import sys
from pathlib import Path
from typing import NoReturn

TIMER_ROLES = frozenset({"backstop", "safety-net", "self-heal"})
KINDS = frozenset({"persona", "runtime"})
BUDGETS = frozenset({"pr-automation-budget", "none"})
EMIT_PREFIXES = ("label:", "comment:", "review:", "dispatch:", "commit", "push")


def fail(msg: str) -> NoReturn:
    print(f"::error::interaction contract invalid: {msg}", file=sys.stderr)
    sys.exit(1)


def discover_contracts(root: Path) -> list[Path]:
    found: list[Path] = []
    found += sorted((root / "personas").glob("*/interaction.yml"))
    found += sorted((root / "interaction-contracts").glob("*.yml"))
    return found


def _require_nonempty_str(value: object, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{where} must be a non-empty string, got {value!r}")
    return value


def _require_list(value: object, where: str) -> list:
    if not isinstance(value, list):
        fail(f"{where} must be a list, got {value!r}")
    return value


def check_timer(timer: object, where: str) -> None:
    if not isinstance(timer, dict):
        fail(f"{where} must be a mapping, got {timer!r}")
    _require_nonempty_str(timer.get("cron"), f"{where}.cron")
    role = timer.get("role")
    if role not in TIMER_ROLES:
        fail(f"{where}.role must be one of {sorted(TIMER_ROLES)} "
             f"(backstop | safety-net | self-heal), got {role!r}")
    _require_nonempty_str(timer.get("justification"), f"{where}.justification")
    _require_nonempty_str(timer.get("stop_condition"), f"{where}.stop_condition")
    # event_fast_path is required as a KEY (a null value is meaningful — it marks
    # the §6.3 leak, a timer that is the only path to event-driven work).
    if "event_fast_path" not in timer:
        fail(f"{where} is missing event_fast_path (use null to declare the "
             f"§6.3 no-fast-path leak explicitly)")
    efp = timer["event_fast_path"]
    if efp is not None and not (isinstance(efp, str) and efp.strip()):
        fail(f"{where}.event_fast_path must be a non-empty string or null, got {efp!r}")


def check_self_trigger(events: list, emits: list, where: str) -> None:
    """The well-formedness half of #860 rule 1 (§7): a role must not name, in its
    emits, an event class it also subscribes to. The DEEP semantic analysis
    (e.g. a `comment` emit vs an `issue_comment` subscription, which real roles
    do safely via actor/marker filtering) is Story 4's job — here we catch only
    the unambiguous cases: a self-dispatch, and a literal event/emit collision."""
    event_set = set(events)
    for emit in emits:
        if emit.startswith("dispatch:"):
            dispatched = emit.split(":", 1)[1]
            if f"repository_dispatch:{dispatched}" in event_set:
                fail(f"{where}: emit {emit!r} self-triggers — the role also "
                     f"subscribes to repository_dispatch:{dispatched} (#860 rule 1)")
        if emit in event_set:
            fail(f"{where}: emit {emit!r} is also a subscribed event — a role "
                 f"must never be triggered by its own output (#860 rule 1)")


def check_contract(path: Path, repo_root: Path) -> None:
    import yaml
    try:
        contract = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        fail(f"could not read/parse {path}: {exc}")
    if not isinstance(contract, dict):
        fail(f"{path}: top-level document must be a mapping")

    if contract.get("schema_version") != 1:
        fail(f"{path}: schema_version must be 1, got {contract.get('schema_version')!r}")

    role = _require_nonempty_str(contract.get("role"), f"{path}: role")
    if contract.get("kind") not in KINDS:
        fail(f"{path}: kind must be one of {sorted(KINDS)}, got {contract.get('kind')!r}")

    workflows = _require_list(contract.get("workflows"), f"{path}: workflows")
    if not workflows:
        fail(f"{path}: workflows must name at least one deployed workflow")
    for wf in workflows:
        _require_nonempty_str(wf, f"{path}: workflows[]")
        if not (repo_root / wf).is_file():
            fail(f"{path}: workflows entry '{wf}' does not exist (contract is bound "
                 f"to a real workflow — see AC #3)")

    interaction = contract.get("interaction")
    if not isinstance(interaction, dict):
        fail(f"{path}: interaction must be a mapping")

    triggers = interaction.get("triggers")
    if not isinstance(triggers, dict):
        fail(f"{path}: interaction.triggers must be a mapping")
    events = _require_list(triggers.get("events"), f"{path}: interaction.triggers.events")
    for ev in events:
        _require_nonempty_str(ev, f"{path}: interaction.triggers.events[]")
    timers = _require_list(triggers.get("timers"), f"{path}: interaction.triggers.timers")
    for i, timer in enumerate(timers):
        check_timer(timer, f"{path}: interaction.triggers.timers[{i}]")

    emits = _require_list(interaction.get("emits"), f"{path}: interaction.emits")
    if not emits:
        fail(f"{path}: interaction.emits must be non-empty (a role that produces "
             f"nothing has no self-trigger surface to prove safe — declare what it emits)")
    for emit in emits:
        _require_nonempty_str(emit, f"{path}: interaction.emits[]")
        if not emit.startswith(EMIT_PREFIXES):
            fail(f"{path}: interaction.emits entry '{emit}' must start with one of "
                 f"{list(EMIT_PREFIXES)} so its produced event class is declared")
    check_self_trigger(events, emits, f"{path}")

    _require_nonempty_str(interaction.get("idempotency_key"),
                          f"{path}: interaction.idempotency_key")
    _require_nonempty_str(interaction.get("concurrency_lane"),
                          f"{path}: interaction.concurrency_lane")
    stop_markers = _require_list(interaction.get("stop_markers"),
                                 f"{path}: interaction.stop_markers")
    for m in stop_markers:
        _require_nonempty_str(m, f"{path}: interaction.stop_markers[]")

    budget = interaction.get("budget")
    if budget not in BUDGETS:
        fail(f"{path}: interaction.budget must be one of {sorted(BUDGETS)} "
             f"(§9: obey the existing ceiling, do not invent a new numeric cap), "
             f"got {budget!r}")

    # A runtime that writes (declares the pr-automation-budget) must be able to
    # stand down when a human takes over.
    if budget == "pr-automation-budget" and not stop_markers:
        fail(f"{path}: role '{role}' obeys the pr-automation-budget but declares no "
             f"stop_markers — a write runtime must skip human-gated work (§6.2.3)")


def main() -> None:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    try:
        import yaml  # noqa: F401
    except ImportError:
        fail("PyYAML not installed (pip install pyyaml)")

    contracts = discover_contracts(root)
    if not contracts:
        print(f"no interaction contracts found under {root} — nothing to validate.")
        return
    for path in contracts:
        check_contract(path, root)
    print(f"OK: {len(contracts)} interaction contract(s) valid, invariants hold.")


if __name__ == "__main__":
    main()
