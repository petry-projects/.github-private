# ADR-0007 collapse — pre-collapse billed-run baseline (`petry-projects/markets`)

This is the captured baseline required by epic
[#1723](https://github.com/petry-projects/.github-private/issues/1723) and cited by story
[#1729](https://github.com/petry-projects/.github-private/issues/1729) AC5, AC9 and AC10. The epic
lists it as an untracked prerequisite: *"A 1-week baseline of billed Actions run counts per role on
the first collapse-target repo, captured before Story 6."* AC9 makes it a hard input — AC5 must cite
this path — so that the post-collapse run-count bound is measurable rather than asserted.

Capturing it **before** the collapse is the whole point: once `agent-ingress.yml` lands, the
per-role run counts it replaces can no longer be observed.

## Window and method

| Field | Value |
|---|---|
| Repo | `petry-projects/markets` (the decided first collapse target) |
| Window | `2026-09-15` → `2026-09-22` (7 days) |
| Source | GitHub Actions REST API, `created>=2026-09-15` |
| Per-workflow counts | `/repos/{repo}/actions/workflows/{id}/runs` → `total_count` |
| Per-event counts | per-workflow run listing, grouped by `event` |
| Total runs, all workflows | **1552** |

**Methodology caveat, deliberately recorded.** The flat
`/repos/{repo}/actions/runs` listing is capped at 1000 results, and this window exceeds it — a naive
paginated listing returns 1000 runs and silently under-reports every role. The per-workflow figures
below come from each workflow's own `total_count`, which is not subject to that cap. Anyone
re-capturing this baseline, or capturing the *after* number, must use the same per-workflow method or
the comparison is invalid in the direction that flatters the collapse.

## Baseline — collapsible Class-1 event-driven thin callers

These are the stubs the collapse replaces. Their summed runs are the figure the post-collapse total
must not exceed.

| Role | Stub | Pinned ref | Runs (7d) |
|---|---|---|---|
| `dev-lead` | `dev-lead.yml` | `dev-lead/v139-stable` | **589** |
| `pr-review-mention` | `pr-review-mention.yml` | `pr-review-mention/v2-stable` | **332** |
| `pr-auto-review` | `pr-auto-review.yml` | `pr-auto-review/v1-stable` | **211** |
| `pr-review` | `pr-review.yml` | `pr-review/stable` ⚠️ | **189** |
| `ci-failure-analyst` | `ci-failure-analyst.yml` | bare SHA `e37e9eb4` ⚠️ | **35** |
| | | **Total** | **1356** |

### Per-event breakdown

Needed for the union `on:` block (AC2) and for the skip-kind analysis (AC10).

| Role | Events (7d) |
|---|---|
| `dev-lead` | `issue_comment` 192, `pull_request_review` 149, `pull_request_review_comment` 135, `repository_dispatch` 58, `check_run` 35, `pull_request` 12, `issues` 8 |
| `pr-review-mention` | `issue_comment` 192, `pull_request_review_comment` 135, `pull_request` 5 |
| `pr-auto-review` | `pull_request_review` 149, `check_suite` 33, `workflow_run` 17, `pull_request` 12 |
| `pr-review` | `pull_request_review` 149, `check_suite` 33, `pull_request` 7 |
| `ci-failure-analyst` | `check_run` 35 |

## AC10 — skip-kind classification is resolved for this repo

AC10 requires the two skip kinds to be measured separately, because a role that relied on an
**event-level `paths:` filter** starts paying a per-event runner cost once its filter moves inside
the reusable (kind **b**), while a job skipped by a job-level `if:` event filter is evaluated on the
Actions service and never assigned a runner (kind **a**).

**No collapsible caller in `markets` uses `paths:` or `paths-ignore:`** — verified across all five
stubs above; every one filters on event type and `types:` only. So in this repo **every post-collapse
skip is kind (a)** and no role incurs the kind (b) runner cost. AC10 is satisfiable here by measuring
kind (a) alone, and the finding should be re-verified per repo during fan-out rather than assumed —
`.github-private`'s own `dependency-advisory` shape is the known kind (b) case.

## Carve-outs and non-callers (excluded from the bound)

Excluded by the ADR and by #1729 AC1; listed so the eligible set is falsifiable.

| Workflow | Why excluded | Runs (7d) |
|---|---|---|
| `add-to-project.yml` | `pull_request_target` carve-out | 29 |
| `dependabot-automerge.yml` | `pull_request_target` carve-out | 12 |
| `dependabot-rebase.yml` | timer + `push` carve-out | (in Dependabot totals) |
| `auto-rebase.yml` | `push` + `workflow_dispatch`, keeps its own file | 5 |
| `apply-repo-settings.yml` | Class-2/3 timer | — |
| `feature-ideation.yml` | Class-2/3 timer (`schedule`/`discussion`) | 1 |
| `ci.yml`, `shell-tests.yml`, `sonarcloud.yml`, `copilot-setup-steps.yml`, `initiative-driver.yml` | not thin callers (inline logic) | 17 / 4 / 17 / — / 18 |

### Open classification, for the implementer to decide

`agent-shield.yml` (17 runs, `agent-shield/v2-stable`, `push`+`pull_request`) and
`dependency-audit.yml` (17 runs, `dependency-audit/v2-stable`, `pull_request`+`push`) are
first-party thin callers on Class-1 events, so the ADR's rule admits them, but both are **gates**
rather than agentic roles. #1729 AC1 requires the full eligible set to be enumerated explicitly —
include or exclude them deliberately and record the reason; do not let them be decided by omission.

## Two pin defects observed while capturing this

Neither blocks the baseline; both affect the collapse, since the ingress carries each role's pin
forward per-job.

1. **`pr-review.yml` pins `pr-review/stable`, which has not moved since 2026-06-20** (`ceab48a1`),
   while `pr-review/v1.10.0` exists. `markets` has been running three-month-old pr-review code. Do
   not carry a stale pin forward into the ingress unexamined.
2. **`ci-failure-analyst.yml` pins a bare SHA** (`e37e9eb4`) rather than a channel tag, so it
   receives no promotions at all. ADR-0002 makes the channel tag the canonical caller pin; the
   collapse is the natural point to correct this.
