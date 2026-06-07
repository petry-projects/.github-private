# Engine model rollout — Gemini per-tier overrides + fallback chain

The `dev-lead` and `pr-review` agents share [`scripts/engine.sh`](../scripts/engine.sh).
When `REVIEW_ENGINE=gemini`, the per-tier model IDs and the in-engine fallback
chain are configurable via environment variables. This is the supported mechanism
for staged rollout of new Gemini models (e.g. `gemini-3.5-flash`) without touching
the script.

## Per-tier model overrides

Each cascade tier reads a default from `engine.sh` that can be overridden via an
env var:

| Tier   | Env var                 | Default            |
|--------|-------------------------|--------------------|
| triage | `GEMINI_TRIAGE_MODEL`   | `gemini-2.0-flash` |
| deep   | `GEMINI_DEEP_MODEL`     | `gemini-2.5-pro`   |
| audit  | `GEMINI_AUDIT_MODEL`    | `gemini-2.5-pro`   |
| action | `GEMINI_ACTION_MODEL`   | `gemini-2.5-pro`   |
| single | `GEMINI_SINGLE_MODEL`   | `gemini-2.5-pro`   |

Setting `GEMINI_DEEP_MODEL=gemini-3.5-flash` makes the deep-review tier run on
`gemini-3.5-flash` for that job. The two agents can be configured independently
by setting the vars in their respective workflow files.

## Per-tier fallback chains

Each tier also accepts a comma-separated `GEMINI_*_MODEL_CHAIN` for staged
rollout. The chain is walked left-to-right; on rate-limit the next model is
tried. Only when every model in the chain is rate-limited does the call return
exit code 2, which triggers the cross-provider fallback (gemini → copilot).

| Tier   | Env var                       |
|--------|-------------------------------|
| triage | `GEMINI_TRIAGE_MODEL_CHAIN`   |
| deep   | `GEMINI_DEEP_MODEL_CHAIN`     |
| audit  | `GEMINI_AUDIT_MODEL_CHAIN`    |
| action | `GEMINI_ACTION_MODEL_CHAIN`   |
| single | `GEMINI_SINGLE_MODEL_CHAIN`   |

A non-rate-limit failure (exit 1) from any model in the chain propagates
immediately without trying the next entry — same contract as the Claude
chain.

### Example: phased rollout to `gemini-3.5-flash`

```yaml
# Phase 1 — opt-in (set in one workflow run)
env:
  REVIEW_ENGINE: gemini
  GEMINI_DEEP_MODEL: gemini-3.5-flash
  GEMINI_DEEP_MODEL_CHAIN: gemini-3.5-flash,gemini-2.5-pro
```

```yaml
# Phase 2 — default on for one agent (set in dev-lead.yml)
env:
  REVIEW_ENGINE: gemini
  GEMINI_TRIAGE_MODEL: gemini-3.5-flash
  GEMINI_DEEP_MODEL: gemini-3.5-flash
  GEMINI_ACTION_MODEL: gemini-3.5-flash
  GEMINI_DEEP_MODEL_CHAIN: gemini-3.5-flash,gemini-2.5-pro
  GEMINI_ACTION_MODEL_CHAIN: gemini-3.5-flash,gemini-2.5-pro
```

```yaml
# Phase 3 — default on for both agents (set in pr-review.yml + dev-lead.yml)
env:
  REVIEW_ENGINE: gemini
  GEMINI_TRIAGE_MODEL: gemini-3.5-flash
  GEMINI_DEEP_MODEL: gemini-3.5-flash
  GEMINI_AUDIT_MODEL: gemini-3.5-flash
  GEMINI_ACTION_MODEL: gemini-3.5-flash
  GEMINI_SINGLE_MODEL: gemini-3.5-flash
```

## Fail-closed behavior

- **Empty chain (whitespace-only):** treated as a configuration error
  (`rc=1`), not a rate-limit. Returning `rc=2` would falsely trigger the
  cross-provider fallback as though quotas were exhausted.
- **All models rate-limited:** the chain returns `rc=2` and writes the parsed
  reset time to `/tmp/dev-lead-rate-limit-reset` for the marker on the PR.
- **First non-rate-limit error:** propagates immediately. The chain does not
  retry transient/deterministic non-quota errors across model variants.

## Token logging

Per-call records emitted to `TOKEN_LOG_FILE` (when set) record the model that
actually produced the output, not the first model in the chain. This means a
phase-1 record where flash was rate-limited and pro served the call will tag
the record with `gemini-2.5-pro`.
