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
| `GEMINI_FLASH_MODEL` | `gemini-3.8-flash` | Gemini speed-tier model (triage, action, Gemini duck). |
| `GEMINI_PRO_MODEL` | `gemini-2.5-pro` | Gemini quality-tier model (deep, audit, single). |
| `REVIEW_ENGINE` | unset | **Legacy** primary override for pr-review. When set, it wins over the first `AI_ENGINES` entry, as long as `AI_ENGINES` enables it. Delete it to let `AI_ENGINES` decide. |
| `DEV_LEAD_ENGINE` | unset | **Legacy** primary override for dev-lead; same rule as `REVIEW_ENGINE`. |
| `DEV_LEAD_ENGINES` | unset | **Legacy** name for `AI_ENGINES` (dev-lead, #1546). Read only when `AI_ENGINES` is unset. |

`AI_ENGINES` is comma- or space-separated and case-insensitive, for example
`claude,gemini`. Start the value with an engine name (no leading space): the
workflows read the primary from the start of the value.

## Common switches

| Goal | Set |
|---|---|
| Turn Copilot off | `AI_ENGINES=claude,gemini` |
| Make Gemini primary, Claude the fallback | `AI_ENGINES=gemini,claude` |
| Claude only, no cross-provider fallback | `AI_ENGINES=claude` |
| Keep the duck on Claude (same vendor, different model) | `AI_DUCK_ENGINE=claude`, `AI_DUCK_MODEL=claude-sonnet-5` |
| Turn the duck off | `AI_DUCK_ENGINE=none` |

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
- **Model chains inside Claude** (for example the deep tier's
  `claude-opus-5-5 → claude-opus-4-8 → claude-sonnet-5`) are separate: they are
  walked before any cross-provider fallback. See `set_engine_config` in
  [`scripts/engine.sh`](../scripts/engine.sh).
