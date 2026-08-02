<!--
Thanks for the contribution. Fill in the summary, then complete the checklist.
Delete sections that do not apply to this PR.
-->

## Summary

<!-- What does this PR change, and why? -->

## Interaction contract

<!--
Complete this section ONLY if this PR adds or changes an agentic role — a workflow that
reacts to events or runs on a cadence and takes automated action. If it does not, tick
"N/A" and delete the rest.

See the runbook: docs/adding-an-agentic-role.md
Standard: docs/agentic-interaction-model.md
-->

- [ ] N/A — this PR does not add or change an agentic role.

If this PR **does** add or change an agentic role, confirm:

- [ ] The role's trigger class (1 / 2 / 3) is chosen per the standard, and its row in the
      §4 classification table of `docs/agentic-interaction-model.md` is added or updated to
      match the workflow's `on:` block.
- [ ] The machine-readable interaction contract is added or updated for
      every applicable lens (`personas/<id>/interaction.yml` and/or
      `interaction-contracts/<name>.yml`); include both when both lenses apply, with
      `triggers`, `emits`, `idempotency_key`, `concurrency_lane`, `stop_markers`, and `budget`.
- [ ] Event-first: the role subscribes to the event that represents the work, or crosses the
      `GITHUB_TOKEN` boundary only via a sanctioned bridge (PAT `repository_dispatch` or a
      stop-condition-gated backstop timer).
- [ ] If the role uses a timer (Class 2 or Class 3), its timer contract is declared
      (`justification`, `stop_condition`) and it is idempotent, skips human-gate markers,
      and obeys the off-peak schedule standard; for Class 2, also declares `role` and a
      non-null `event_fast_path`.

## Checklist

- [ ] `shellcheck scripts/*.sh` passes for any changed shell scripts.
- [ ] Docs updated where behavior or standards changed.
