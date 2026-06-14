# Initiative: MCP-Powered CI Review Enrichment

**Status:** Reference — recommended server set + enablement knob (Phase 2 of epic [#676](https://github.com/petry-projects/.github-private/issues/676))
**Author:** dev-lead / Claude Code
**Date:** 2026-06-14
**Scope (confirmed):** The self-hosted Claude review engine (`scripts/engine.sh`, invoked by
`pr-review.yml`). Covers (a) which MCP servers to recommend per downstream stack, and (b) how to turn
MCP-enriched review on via the engine knob. Does **not** change default review behavior — MCP is
strictly opt-in and inert when unconfigured.
**Constraints (confirmed):** GitHub-native + the existing engine only — no new infrastructure. MCP is
opt-in via committed env knobs (no thin-caller workflow edit required). Security-first: a downstream
pilot happens **only after** the in-flight security-hardening work lands. Claims about server
availability are grounded in discussion [#650](https://github.com/petry-projects/.github-private/discussions/650)
(body + the 2026-06-13 weekly update) and must not overstate maturity.

---

## 1. Why MCP-enriched review

Reviews today draw solely on the model's training data, which can lag the latest library releases by
months — risking missed breaking changes and deprecated-API patterns. Downstream repos span **React,
Python, and Go**, so framework-specific, version-aware review benefits from live context. MCP (Model
Context Protocol) servers let a review pull **real-time** documentation and external security/quality
signal at review time instead of relying on stale training data alone.

This work delivers the MCP *plumbing* (the engine knob + graceful degradation) independently of the
broader review-engine rework tracked in epic [#610](https://github.com/petry-projects/.github-private/issues/610)
(generalize `pr-review` into a context-adaptive review agent). The MCP knob lands on its own so it does
not wait on the artifact-contract changes in #610.

---

## 2. Recommended servers per stack

Pick the smallest server set that covers the stack. Context7 is the lowest-friction starting point for
any stack (free, stateless, no authentication); the GitHub and SonarQube servers add
security/quality signal on top.

| Server | What it adds | Auth / cost | Maturity (per #650, 2026-06-13) | Best fit |
|---|---|---|---|---|
| **Context7** | Real-time library/framework documentation; catches deprecated APIs and breaking changes that static training data misses | Free, stateless, **no auth** | Available; lowest failure surface | **All stacks** — React (component/library docs), Python (package docs), Go (module docs) |
| **GitHub MCP — secret scanning** | Scans for exposed secrets during agent code generation, honoring repo/org push-protection settings | `GITHUB_TOKEN` (no PAT); integrates with existing repo security settings | **GA (May 2026)** | Any stack; security-sensitive repos |
| **GitHub MCP — dependency scanning** | Flags vulnerable dependencies before merge (repos with Dependabot alerts enabled) | `GITHUB_TOKEN`; Dependabot alerts enabled | **Public preview** (not GA) | Any stack with a dependency manifest |
| **SonarQube MCP** | Enriches review with existing code-quality data (smells, coverage, hotspots) | SonarQube instance + token | Available where a SonarQube project exists | Repos already running SonarQube |

> **Availability caveat.** GitHub MCP **secret scanning is GA**; **dependency scanning is public
> preview**, not GA. Do not represent the preview surface as production-ready.

Suggested per-stack starters:

- **React / TypeScript** — Context7 (library docs) + GitHub MCP secret scanning.
- **Python** — Context7 (package docs) + GitHub MCP secret scanning + dependency scanning (preview).
- **Go** — Context7 (module docs) + GitHub MCP secret scanning; add SonarQube MCP where a SonarQube
  project already exists.

---

## 3. The engine knob (how to turn MCP review on)

MCP review is enabled by two environment variables read by `scripts/engine.sh`. Both are **opt-in**:
when `REVIEW_MCP_CONFIG` is unset, empty, or points at an unreadable path, the engine threads **no**
MCP flags and the review behaves byte-for-byte as before.

| Env var | Purpose |
|---|---|
| `REVIEW_MCP_CONFIG` | Path to an MCP-servers JSON config file. When set to a readable file, the engine appends `--mcp-config <file> --strict-mcp-config` to the Claude call. `--strict-mcp-config` means **only** the servers in this file are used (ambient MCP config is ignored). |
| `REVIEW_MCP_ALLOWED_TOOLS` | Comma-separated MCP tool globs (e.g. `mcp__context7__*`) merged into the per-tier `--allowed-tools` list so the model may actually invoke the server's tools. |

**Which review tiers get MCP.** The flags are threaded into the **agentic (deep)** and **rubber-duck**
Claude tiers only. The **triage** tier stays fast and restricted (it uses `--disallowed-tools` only and
never receives MCP flags), so the cheap first-pass is unaffected.

The base allowed-tools list for the MCP-eligible tiers is `Bash,Read,Grep,Glob`. When
`REVIEW_MCP_ALLOWED_TOOLS` is set, it is appended to that base; when it is unset, the base list is used
unchanged.

### 3.1 Worked example — Context7

1. Commit an MCP config file (path is what `REVIEW_MCP_CONFIG` points at), e.g.
   `.github/mcp/context7.json`:

   ```json
   {
     "mcpServers": {
       "context7": {
         "command": "npx",
         "args": ["-y", "@upstash/context7-mcp"]
       }
     }
   }
   ```

2. Set the two knobs in the review environment (committed config; no thin-caller workflow edit needed):

   ```bash
   REVIEW_MCP_CONFIG=.github/mcp/context7.json
   REVIEW_MCP_ALLOWED_TOOLS=mcp__context7__*
   ```

3. With both set, the engine invokes the Claude agentic/duck tiers with:

   ```
   --mcp-config .github/mcp/context7.json --strict-mcp-config \
   --allowed-tools Bash,Read,Grep,Glob,mcp__context7__*
   ```

   The triage tier is untouched. Unset both knobs and the call reverts to
   `--allowed-tools Bash,Read,Grep,Glob` with no MCP flags.

---

## 4. Graceful degradation — Fail Loud, Never Fake

When MCP is configured and a server is unavailable, the review **degrades visibly and continues** — it
never aborts the run and never fabricates an "all clear" verdict. Concretely, the engine:

- emits a single GitHub Actions warning annotation, naming the affected server(s) when it can extract
  them, e.g.:

  ```
  ::warning::[mcp] server(s) unavailable: context7 — review continues on the model's base capabilities (no MCP tool context)
  ```

  (when no server name can be parsed, a generic `::warning::[mcp] an MCP server was unavailable …`
  is emitted instead);
- leaves the model's verdict and the caller's exit code **untouched** — the review completes on the
  model's base capabilities, just without the MCP-sourced context;
- is **inert when MCP was never configured**: with `REVIEW_MCP_CONFIG` unset, no MCP warning is ever
  emitted, even if unrelated text in the output resembles a failure marker.

This means an unreachable MCP server costs you the *enrichment*, not the *review*. The behavior is
implemented in `scripts/engine.sh` (`_emit_mcp_failure_warning`) and regression-tested in
`tests/dev-lead/unit/test_engine_mcp.bats`.

---

## 5. Security-first sequencing & the revised starter

**Sequencing.** The organization's immediate priorities are security hardening (action allowlisting,
input sanitization). A downstream MCP pilot ([#681](https://github.com/petry-projects/.github-private/issues/681))
happens **only after** that in-flight security work lands — not before.

**Revised starter recommendation.** The original #650 proposal (2026-05-29) suggested starting with
either Context7 or GitHub MCP secret scanning. The **2026-06-13 weekly update revised this**: because
GitHub MCP secret scanning is now **GA** (and dependency scanning is in public preview), both require
no authentication beyond `GITHUB_TOKEN`, and both integrate with existing repo security settings, the
lowest-risk first step is now **GitHub MCP Server (secret + dependency scanning)** rather than
Context7. This aligns with the security-first priorities and delivers immediate, measurable value
(catching secrets/vulnerabilities during agent code generation) before adding library-documentation
enrichment via Context7.

> **Net guidance:** for the *pilot*, start with **GitHub MCP secret scanning**. For *broad per-stack
> enrichment* afterward, Context7 remains the lowest-friction add for every stack.

---

## 6. References

- Discussion [#650](https://github.com/petry-projects/.github-private/discussions/650) — proposal body
  - 2026-06-13 weekly update (server availability + revised starter).
- Epic [#676](https://github.com/petry-projects/.github-private/issues/676) — MCP-powered review
  enrichment; stories #677 (engine knob), #678 (graceful degradation), #679 (workflow surface),
  #680 (this doc), #681 (downstream pilot).
- Epic [#610](https://github.com/petry-projects/.github-private/issues/610) — broader context-adaptive
  review-engine rework (MCP plumbing lands independently of this).
- `scripts/engine.sh` — `REVIEW_MCP_CONFIG` / `REVIEW_MCP_ALLOWED_TOOLS` threading and
  `_emit_mcp_failure_warning`.
- `tests/dev-lead/unit/test_engine_mcp.bats` — knob-threading + graceful-degradation tests.
- `docs/initiatives/agentic-release-strategy.md` — initiative-doc header shape.
