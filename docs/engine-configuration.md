# Engine configuration (AI_ENGINES)

pr-review and dev-lead can run on three LLM engines: **Claude**, **Gemini** and
**Copilot**. Which engines are used, and in what order, is set with GitHub
Actions **variables** (org or repo level). Switching providers needs no code
change and no release: the next run picks the new value up.

The parsing lives in [`scripts/lib/engine-chain.sh`](../scripts/lib/engine-chain.sh).

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `AI_ENGINES` | `claude,gemini,copilot` | Ordered list of **enabled** engines. An engine that is not listed is never used, not even as a fallback. The order is the fallback order, and the **first** entry is the primary engine. |
| `AI_DUCK_ENGINE` | automatic | Engine for pr-review's rubber-duck second opinion: `claude`, `gemini`, `copilot`, or `none` to turn it off. |
| `AI_DUCK_MODEL` | engine default | Model id for the duck. Used only when the duck runs on the engine named in `AI_DUCK_ENGINE`. |
| `AI_MODELS_CLAUDE` | see below | Claude's model list, one chain per tier. |
| `AI_MODELS_GEMINI` | see below | Gemini's model list: the `flash` and `pro` chains, and the duck model. |
| `AI_MODELS_COPILOT` | `model=openai/o4-mini` | The GitHub Models id Copilot uses for every tier. |
| `GEMINI_FLASH_MODEL` | unset | Replaces only the first model of the Gemini `flash` chain. |
| `GEMINI_PRO_MODEL` | unset | Replaces only the first model of the Gemini `pro` chain. |
| `REVIEW_ENGINE` | unset | **Legacy** primary override for pr-review. When set, it wins over the first `AI_ENGINES` entry, as long as `AI_ENGINES` enables it. Delete it to let `AI_ENGINES` decide. |
| `DEV_LEAD_ENGINE` | unset | **Legacy** primary override for dev-lead; same rule as `REVIEW_ENGINE`. |
| `DEV_LEAD_ENGINES` | unset | **Legacy** name for `AI_ENGINES` (dev-lead, #1546). Read only when `AI_ENGINES` is unset. |

`AI_ENGINES` is comma- or space-separated and case-insensitive, for example
`claude,gemini`. Start the value with an engine name (no leading space): the
workflows read the primary from the start of the value.

## Model lists (AI_MODELS_*)

Each provider's models live in one variable, so a retired or renamed model is a
variable edit, not a code change. The parsing and the defaults are in
[`scripts/lib/engine-models.sh`](../scripts/lib/engine-models.sh).

Each entry is `<key>=<model>[,<fallback>,…]`. Separate entries with `;` or new
lines. Keys are case-insensitive and spaces around names are ignored. A key you
leave out keeps its default. A chain is walked left to right on a rate limit,
before the next engine in `AI_ENGINES` is tried. The `duck` and `model` keys take
one model; given several, they warn and use the first.

| Variable | Key | Used for | Default |
|---|---|---|---|
| `AI_MODELS_CLAUDE` | `triage` | classify the PR | `claude-haiku-4-5-20251001,claude-sonnet-5` |
| | `deep` | agentic review | `claude-opus-5-5,claude-opus-4-8,claude-sonnet-5` |
| | `audit` | security audit | `claude-fable-5,claude-opus-4-8,claude-opus-4-7` |
| | `action` | dev-lead writer | `claude-sonnet-5,claude-opus-4-8` |
| | `single` | single-reviewer mode | `claude-fable-5,claude-opus-4-8,claude-opus-4-7` |
| | `duck` | Claude as the rubber duck | `claude-sonnet-4-6` |
| `AI_MODELS_GEMINI` | `flash` | triage and action | `gemini-3.8-flash,gemini-3.1-pro-preview` |
| | `pro` | deep, audit and single | `gemini-3.1-pro-preview,gemini-3.8-flash` |
| | `duck` | Gemini as the rubber duck | the first `flash` model |
| `AI_MODELS_COPILOT` | `model` | every tier | `openai/o4-mini` |

Example, Gemini with a newer pro model and no change to the rest:

```text
AI_MODELS_GEMINI = pro=gemini-3.1-pro-preview,gemini-3.8-flash
```

Example, Claude with two tiers changed (the other tiers keep their defaults):

```text
AI_MODELS_CLAUDE = deep=claude-opus-4-8,claude-sonnet-5; triage=claude-sonnet-5
```

A more specific variable still wins over `AI_MODELS_*`, so existing overrides
keep working: `CLAUDE_<TIER>_MODEL_CHAIN`, `GEMINI_FLASH_MODEL_CHAIN` /
`GEMINI_PRO_MODEL_CHAIN`, `GEMINI_FLASH_MODEL` / `GEMINI_PRO_MODEL` (these two
replace only the first model) and `COPILOT_API_MODEL`.

An unknown key, an entry without `=`, or a malformed model id is ignored, and
that tier keeps its default. Each problem is logged once per run as a
`::warning::`. The run log's `engine:` line shows the chains in use, for
example `deep: opus 5.5 [opus 4.8, sonnet 5]`.

## Common switches

| Goal | Set |
|---|---|
| Turn Copilot off | `AI_ENGINES=claude,gemini` |
| Make Gemini primary, Claude the fallback | `AI_ENGINES=gemini,claude` |
| Claude only, no cross-provider fallback | `AI_ENGINES=claude` |
| Keep the duck on Claude (same vendor, different model) | `AI_DUCK_ENGINE=claude`, `AI_DUCK_MODEL=claude-sonnet-5` |
| Turn the duck off | `AI_DUCK_ENGINE=none` |
| Replace a retired Gemini pro model | `AI_MODELS_GEMINI=pro=<new-model>,gemini-3.8-flash` |
| Pin Claude's deep review to Opus 4.8 | `AI_MODELS_CLAUDE=deep=claude-opus-4-8,claude-sonnet-5` |

## Behaviour

- **Unknown engine names.** A typo such as `claude,cluade` invalidates the
  whole value: the default chain is used and the run logs a `::warning::`, so a
  typo can never silently drop fallbacks.
- **Pre-flight probe.** `validate-engines.sh` checks each **enabled** engine
  before the first review. Disabled engines are reported with a notice and not
  probed. The primary is skipped when the probe finds it unusable, and a
  rate-limit fallback skips every unusable engine:
  - Gemini is usable while **any** of `GOOGLE_API_KEY`, `GOOGLE_API_KEY_2` and
    `GOOGLE_API_KEY_3` has credits. The run warns, by key name, about any key
    that is depleted.
  - Copilot is unusable with a classic PAT (`ghp_`), which Copilot rejects.
- **Rate limits.** On a rate limit (exit 2), pr-review moves forward through
  `AI_ENGINES` from the current engine, and the switch sticks for the rest of
  the batch. If later engines are configured but none is usable, the PR is
  skipped with one notice and the batch continues. If the chain has no later
  engine at all, the session stops and retries on the next scheduled run.
- **Rubber duck.** The duck prefers `AI_DUCK_ENGINE`, then the built-in
  cross-engine default (Copilot when Claude is primary, Claude when Gemini is
  primary, Gemini when Copilot is primary). After that it takes the first other
  usable engine in `AI_ENGINES`. When none is usable, the duck is skipped with a
  notice instead of failing on every review.
- **Model chains inside a provider** (for example Claude's deep tier
  `claude-opus-5-5 → claude-opus-4-8 → claude-sonnet-5`) are walked before any
  cross-provider fallback. Set them with `AI_MODELS_*` (above).
