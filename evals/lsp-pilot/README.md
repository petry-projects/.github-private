# `evals/lsp-pilot/` — frozen comparative corpus + immutable LSP-off baseline

This held-out set backs the LSP pilot (epic
[#839](https://github.com/petry-projects/.github-private/issues/839), scoping doc
[`docs/lsp-pilot.md`](../../docs/lsp-pilot.md)). It exists so candidate LSP-MCP
servers are compared against a **fixed target that cannot be tuned to** — the
go/no-go must reflect real generalization, not overfitting to a few PRs.

It reuses the standard held-out machinery (see [`../README.md`](../README.md)): the
`dev/` (proposer-visible) vs `holdout/` (gate-scored) split, the directory
validator (`evals/validate-cases.py`), and the hard immutability gate
(`scripts/lib/holdout-guard.sh` + `.github/workflows/holdout-guard.yml`, keyed on
`HOLDOUT_GUARDED_PREFIXES` whose default `evals/` already covers this tree). No new
immutability mechanism is invented here.

## Layout

```
evals/lsp-pilot/
  dev/cases.jsonl                 # proposer-visible smoke PRs
  holdout/cases.jsonl             # frozen scored corpus (the comparison target)
  holdout/baseline-lsp-off.jsonl  # immutable LSP-off control, captured ONCE
  runs/<candidate>.jsonl          # captured LSP-on candidate runs (story #844 inputs)
```

`runs/` is not a held-out split — it is not validated by `evals/validate-cases.py`
(which only walks `dev/`/`holdout/`) and holds **candidate run captures**, one JSONL
per candidate LSP server, in the comparison-harness record shape (see
[`../../scripts/lsp_pilot_compare.sh`](../../scripts/lsp_pilot_compare.sh)). They are
the LSP-on inputs the comparative report
([`../../scripts/lsp_pilot_report.sh`](../../scripts/lsp_pilot_report.sh) →
[`../../docs/lsp-pilot-report.md`](../../docs/lsp-pilot-report.md)) scores against the
frozen baseline. A run may carry two optional honesty fields — `lsp_skipped` (the SLA
auto-skip fired) and `mcp_degraded` (the MCP server ran degraded), each with a
`skip_reason` — so a skipped/degraded run is reported, never silently dropped. Like the
corpus and baseline, the committed runs are **synthetic, de-identified seeds** until the
real pilot PR set is wired.

## The frozen corpus (`cases.jsonl`)

Each case pins one pilot PR by **immutable identifiers** — `repo` + `pr_number` +
`head_sha` — plus a unique `id` and a `description` of the navigation claim it
exercises (find-references or diagnostics, per the scoping doc §2). Pinning the
head SHA freezes *exactly which revision* is reviewed, so the corpus is a moving
target for nobody.

> The identifiers committed here are **synthetic, de-identified seeds** (note the
> zero-padded `head_sha`s), consistent with the de-identification requirement in
> [`../README.md`](../README.md). They are replaced with the real pinned pilot PR
> set when the server is wired and the controls are run (story
> [#842](https://github.com/petry-projects/.github-private/issues/842)). The
> structure, schema, and immutability guarantee are what this story freezes.

## The immutable LSP-off baseline (`baseline-lsp-off.jsonl`)

The LSP-off control is captured **once** and committed as a frozen artifact, so
later stories compare against it rather than re-deriving it (a re-derived baseline
is a moving target — a reward-hacking vector). One JSON object per corpus PR:

| field | meaning |
|---|---|
| `pr` | `repo#pr_number@head_sha` — the join key against a candidate run |
| `variant` / `candidate` | `lsp-off` / `baseline` |
| `nav_tokens` | navigation tool-call tokens (the headline cost metric) |
| `tool_calls` | navigation tool-call count |
| `findings` / `false_positives` | the review-quality proxy (see below) |
| `cold_start_s` | `null` — **N/A** for the LSP-off control (no server to launch) |
| `wall_time_s`, `model`, `*_tokens` | speed + cost inputs (ET/USD) |

## The review-quality proxy (explicit, not ad hoc)

Quality is `(findings, false_positives)` per PR. A candidate is a **quality
regression on a PR when its `false_positives` exceeds the frozen baseline's** —
i.e. precision got worse. This is the same definition the harness
([`scripts/lsp_pilot_compare.sh`](../../scripts/lsp_pilot_compare.sh)) renders and
enforces, so the go/no-go is reproducible. Per the success metric, a navigation-
token win that costs precision is a **no-go**, so this metric is mandatory, not
optional.

## Comparing a candidate against the baseline

```bash
bash scripts/lsp_pilot_compare.sh \
  evals/lsp-pilot/holdout/baseline-lsp-off.jsonl \
  <candidate-lsp-on>.jsonl
```

The harness renders per-PR and aggregate speed/cost/quality deltas and **exits
non-zero if any candidate PR has no baseline counterpart** — a partial corpus can
never masquerade as a clean comparison.
