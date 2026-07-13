# Incubation overlays — shared headless contract

Every `producer-*.md` and `validate-*.md` overlay in this directory follows this
contract. It is the incubation adaptation of bmad-prd's headless discipline
(`frameworks/bmad-method/src/bmm-skills/2-plan-workflows/bmad-prd/references/headless.md`
+ `assets/headless-schemas.md`). Read this before the artifact-specific overlay.

## Headless is mandatory

These overlays always run **non-interactively** (GitHub Actions, no TTY, no user
message stream). **Never ask, never greet, never wait.** Complete the intent from
what is provided; if the intent is genuinely impossible, halt with a `blocked`
JSON status and a one-sentence `reason` — do not prompt.

## Inputs the caller provides (first message)

- `intent` — `create` | `update` | `validate`.
- `slug` — the idea slug; the artifact path is **always** `ideas/<slug>/<file>`.
- `idea_context` — the idea's framing (title, problem, source Discussion link).
- `discussion_thread` — the idea Discussion body + comments (the human⇄agent
  workspace). Primary ground truth.
- `prior_artifacts` — the artifacts already in the package (e.g. an existing
  `brainstorm.md` when producing `market-research.md`). Build on them; do not
  contradict them silently.
- For `update` / `validate` — the existing target file (or the `ideas/<slug>/`
  directory containing it).

Anything not provided is inferred from the inputs or recorded — never invented
(see No fabrication).

## Output contract (the incubation gate — authoritative in `ideas/package-spec.json`)

The gate (`incubator/scripts/incubation-gate.sh`) keeps the incubation PR red
until every required artifact is:

1. **At the exact path** `ideas/<slug>/<file>` (filename per `package-spec.json`).
2. **Frontmatter `status: final`** — YAML frontmatter with at least `artifact:`
   and `status:`. Templates ship `status: draft`; a finished artifact is `final`.
3. **Carrying its required section headers** (the `required_sections` for that
   file in `package-spec.json` — restated in each producer overlay; the header
   match is prefix-based, so `## The gap / wedge` satisfies `The gap`).
4. **Free of template placeholders** (`<Idea Title>`, `<slug>`, `<YYYY-MM-DD>`,
   `<link>`, `TODO — needs discovery`, empty `| | |` table rows, …).

Frontmatter block every producer writes:

```yaml
---
artifact: <name>     # matches package-spec.json (brainstorm | market-research | brief | prd)
status: final        # gate requires final; use draft only if halting partial
---
```

> This `{artifact, status}` schema is the **incubator** contract. It is
> deliberately different from bmad-bgreat-suite's `{status, stepsCompleted}` and
> from the vendored skills' own template frontmatter. Emit the incubator schema.

## No fabrication / provenance (hard rule — ref .github-private#1160)

Ground every claim in real input (`discussion_thread`, `prior_artifacts`, or
verifiable research you actually did). **Do not invent** market figures,
competitors, user quotes, or success metrics to fill a section. Instead:

- Tag inferred values inline (e.g. *"(assumption — not confirmed in the thread)"*)
  and collect them in `assumptions[]`.
- Leave a section **honestly thin** with a one-line note on what's missing rather
  than padding it with plausible fiction.
- Cite sources for any external figure; mark estimates as estimates.
- Route unresolved gaps to `open_questions[]`.

A thin-but-true section that trips the gate is correct behavior — it signals the
idea needs more discovery, which is the point.

## JSON status (end every run with exactly one)

### create / update

```json
{
  "status": "complete",
  "intent": "create",
  "artifact": "market-research",
  "path": "ideas/<slug>/market-research.md",
  "assumptions": [],
  "open_questions": []
}
```

`status`: `complete` = stands on its own, gate-ready; `partial` = written but
`open_questions[]` non-empty or critical inputs inferred (caller should review);
`blocked` = no artifact produced (include `reason`).

### validate

```json
{
  "status": "complete",
  "intent": "validate",
  "artifact": "market-research",
  "report_path": "ideas/<slug>/.validation/market-research.md",
  "blockers": [],
  "findings_summary": { "critical": 0, "high": 0, "medium": 0, "low": 0 },
  "offer_to_update": true
}
```

`blockers[]` are the findings the content-quality tier treats as gate-failing
(anything critical/high, or a required section that is present-but-empty). Each
element is a structured object:

```json
{ "severity": "critical", "section": "Market signal", "reason": "section present but empty" }
```

Fields: `severity` (`"critical"` | `"high"`), `section` (the heading that failed),
`reason` (one sentence). A `validate` run always writes `report_path`, even with
zero findings.

### blocked

```json
{ "status": "blocked", "intent": "create", "artifact": "brainstorm", "reason": "one sentence" }
```

## Determinism

Same inputs → same path, same filename, same frontmatter keys. The only variation
is the grounded content. Never rename the file or move it out of `ideas/<slug>/`.
