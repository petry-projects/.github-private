# Token Cost Observatory — Weekly Report

Org-wide visibility into LLM token spend for the agentic workflows (pr-review and
dev-lead). Builds on the per-call JSONL logging added by the
[Token Cost Observatory](https://github.com/petry-projects/.github-private/discussions/332)
work — this layer aggregates that data across **every repo in the org** and
delivers it where humans actually look.

## The problem it solves

The agents emit a token-usage record per LLM call (`scripts/lib/token-metrics.sh`)
and upload it as a `token-usage-<run_id>` artifact. But because pr-review and
dev-lead run as **reusable workflows in each caller repo**, those artifacts land in
the *caller's* repo — not in `.github-private`. The original inline summary only
scanned `.github-private`, so it saw a few percent of real org spend. This report
scans all non-archived repos.

## Effective Tokens (ET)

GitHub's cost-normalisation metric:

```
ET = m × (1.0 × input + 0.1 × cache_read + 4.0 × output)
```

`m` is a model cost multiplier relative to haiku 4.5 (`scripts/lib/token-metrics.sh`):

| Model | Multiplier |
|---|---|
| haiku | 1× |
| sonnet | 3× |
| o4-mini, gemini-pro | 2× |
| gemini-flash | 0.5× |
| opus | 15× |

Output is weighted 4× and cache-read 0.1×, so ET tracks *cost*, not raw token count.

## Delivery

| Channel | Cadence | Where |
|---|---|---|
| **Tracking issue comment** | Weekly (Mon 08:00 UTC) | A single pinned issue in `.github-private` labelled `token-report`; each run adds a comment. |
| **Step Summary** | Weekly + on every fleet-monitor run | Actions run summary of `token-report.yml` and `actions-fleet-monitor.yml`. |

## Usage

Runs automatically every Monday. To trigger manually:

```bash
gh workflow run token-report.yml \
  --repo petry-projects/.github-private \
  --field org=petry-projects \
  --field lookback_days=7
```

To generate the report locally (requires a token with org-wide `actions:read`):

```bash
ORG=petry-projects LOOKBACK_DAYS=7 GH_TOKEN="$(gh auth token)" \
  bash scripts/token_report.sh
```

## Architecture

| File | Role |
|---|---|
| `scripts/token_report.sh` | Org-wide collection (`main`/`collect_org_jsonl`) + pure Markdown rendering (`render_token_report`, `aggregate_by_*`). |
| `tests/token_report.bats` | Unit tests for the pure aggregation/rendering functions. |
| `.github/workflows/token-report.yml` | Weekly cron → tracking-issue comment. |
| `.github/workflows/actions-fleet-monitor.yml` | Daily Step-Summary rollup (reuses the same script). |

## Environment variables (script)

| Variable | Description |
|---|---|
| `ORG` | Org to scan (default `petry-projects`). All non-archived repos discovered automatically. |
| `LOOKBACK_DAYS` | Rolling window of artifact history to include (default `7`). |
| `GH_TOKEN` | PAT with `actions:read` across the org — token-usage artifacts are per-repo. Uses `GH_PAT_WORKFLOWS` in CI. |
| `TOKEN_REPORT_OUT` | Optional path to also write the report to (used by the workflow to post the issue comment). |

## Known limitations

- **Artifact retention**: token-usage artifacts use GitHub's default retention. A
  lookback longer than the retention window will silently miss expired artifacts.
- **Cache tokens**: ET counts `cache_read_tokens` at 0.1×, but only when the engine
  reports them. Engines that don't surface cache usage contribute 0 cache.
- **Per-repo artifact API**: one `actions/artifacts` listing per repo per run. For
  very large orgs this is linear in repo count.
