# BMAD Method — Scrum Master orchestration

The initiative-planner runs the **real BMAD Method** skills, vendored
**agent-agnostically** under `frameworks/` (not in a vendor-specific
`.<tool>/skills` directory). Per the repo standard, installed agentic frameworks
live under `frameworks/` (`CLAUDE.md`, `AGENTS.md`).

## Where the skills live

| Path | Source (pinned) | Contents |
|------|-----------------|----------|
| `frameworks/bmad-method/` | `bmad-code-org/BMAD-METHOD` @ v6.8.0 | `src/bmm-skills` + `src/core-skills` (Scrum Master, create-story, sprint-planning, …) |
| `frameworks/bmad-test-architecture/` | `bmad-code-org/bmad-method-test-architecture-enterprise` @ v1.19.0 | `src/` — the Test Architect (`bmad-tea`, behind the `qa-lead` persona) + `testarch` workflows |

Only the upstream `src/` skill trees are vendored (no website/docs/build tooling);
see each dir's `VENDOR.md` for provenance and the refresh command. The trees are
marked `linguist-vendored` (`.gitattributes`) and excluded from markdownlint;
a path-scoped gitleaks allowlist covers the Test Architect's illustrative auth
examples.

## How the planner consumes it (vendor-neutral)

`.github/workflows/initiative-planner.yml` runs `claude-code-action`, but the
skills are consumed **by path** — plain markdown read with Read/Bash — so the
approach is not tied to any single agent runtime. [`scrum-master.md`](./scrum-master.md)
is the orchestration wrapper: it has Bob follow the vendored
sprint-planning + create-story skills (and the Test Architect where useful) and
emit our `plan.json` (→ `apply-plan.sh`) instead of the skills' default
interactive, file-writing output.

> A per-tool projection (e.g. Claude Code's `.claude/skills/`) is intentionally
> **not committed** (gitignored) — it's a generated, vendor-specific artifact.
> The canonical, agent-agnostic source of truth is `frameworks/`.

## Updating

Re-vendor from a newer upstream tag (see each `VENDOR.md`); commit the result.
Do not hand-edit files under `frameworks/`.
