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
| Source | GitHub Actions REST API, `created=2026-09-15..2026-09-22` (UTC range as issued verbatim to the Actions API, applied identically to every per-workflow and per-event count below) |
| Per-workflow counts | `/repos/{repo}/actions/workflows/{id}/runs` → `total_count` |
| Per-event counts | per-workflow run listing, grouped by `event` |
| Total runs, all workflows | **1531** |

**Methodology caveat, deliberately recorded.** The flat
`/repos/{repo}/actions/runs` listing is capped at 1000 results, and this window exceeds it — a naive
paginated listing returns 1000 runs and silently under-reports every role. The per-workflow figures
below come from each workflow's own `total_count`, which is not subject to that cap. Anyone
re-capturing this baseline, or capturing the *after* number, must use the same per-workflow method or
the comparison is invalid in the direction that flatters the collapse.

## Baseline — collapsible Class-1 event-driven thin callers

These are the stubs the collapse replaces. Their summed runs are the figure the post-collapse total
must not exceed.

**The bound is measured in role-bearing job executions, not top-level ingress workflow runs.** After
the collapse, one `agent-ingress.yml` run fans out to several billable role jobs, so counting
top-level runs understates billed work. For example the 149 `pull_request_review` events are counted
separately under `dev-lead`, `pr-auto-review`, and `pr-review` (447 role invocations); post-collapse
those become 149 ingress runs but still 447 role jobs. The post-collapse figure that must not exceed
**1342** is therefore the sum of role-bearing job executions, not the ingress run count.

**Executed jobs, not workflow runs — measured on the same basis on both sides.** The table figures
below are each workflow's `total_count`, i.e. *workflow-run* counts, not executed-job counts. Each of
the five stubs carries job-level `if:` conditions that can skip role execution without preventing the
workflow run: `pr-auto-review` skips Dependabot-authored events (`pr-auto-review.yml:60`), `pr-review`
skips non-successful check_suites or non-approved/dismissed pull_request_review events
(`pr-review.yml:162-169`), and `ci-failure-analyst` skips non-failed check runs
(`templates/ci-failure-analyst.yml:41-43`). This means some workflow runs from each stub execute *no*
billable role job. Therefore the **1342** is thus an **upper bound** on executed role jobs across all
five stubs until each legacy run's jobs are queried and the skipped jobs excluded. This matters
directionally: the post-collapse side already drops them — `scripts/lib/run-attribution.sh` discards
all-skipped roles — so any re-capture (and the *after* number) must count executed (non-skipped) role
jobs on **both** sides, or the before figure is inflated relative to the after and the comparison
falsely favours the collapse.

**Runner minutes are a separate, unmeasured cost question.** No minute baseline was captured here:
every figure in this document is a run/invocation count from the Actions API `total_count`, not a
minute measurement. The 1342 bound is therefore a run-count / job-execution bound only (AC5) and must
not be silently widened into a minutes bound. If a runner-minutes cost comparison is judged necessary
for AC5, capture it as an explicitly **unmeasured** follow-up — summing each executed job's billable
duration from `GET /repos/{repo}/actions/runs/{run_id}/timing` (or the per-run jobs listing) over the
same window — rather than folding it into this bound.

| Role | Stub | Pinned ref | Runs (7d) |
|---|---|---|---|
| `dev-lead` | `dev-lead.yml` | `dev-lead/v139-stable` | **584** |
| `pr-review-mention` | `pr-review-mention.yml` | `pr-review-mention/v2-stable` | **330** |
| `pr-auto-review` | `pr-auto-review.yml` | `pr-auto-review/v1-stable` | **208** |
| `pr-review` | `pr-review.yml` | `pr-review/stable` ⚠️ | **187** |
| `ci-failure-analyst` | `ci-failure-analyst.yml` | bare SHA `e37e9eb4` ⚠️ | **33** |
| | | **Total** | **1342** |

### Per-event breakdown & job-execution baseline caveat

Needed for the union `on:` block (AC2) and for the skip-kind analysis (AC10).

**Caveat on executed vs. workflow-run counts:** The 1342 total is measured as workflow-run counts
via each stub's `total_count`. However, all five stubs have job-level `if:` conditions that can skip
role execution: (a) `pr-auto-review` skips Dependabot-authored events (`pr-auto-review.yml:60`),
(b) `pr-review` skips non-successful check_suites and certain pull_request_review states
(`pr-review.yml:162-169`), (c) `ci-failure-analyst` skips non-failed check runs. **Therefore 1342 is
an upper bound on executed role jobs for all five stubs**, not just the three others only. Proper
measurement for the post-collapse comparison requires querying each workflow run's job executions to
exclude skipped (non-executed) jobs on **both** the before and after sides, so the comparison is
valid directionally.

| Role | Events (7d) |
|---|---|
| `dev-lead` | `issue_comment` 190, `pull_request_review` 149, `pull_request_review_comment` 135, `repository_dispatch` 58, `check_run` 33, `pull_request` 11, `issues` 8 |
| `pr-review-mention` | `issue_comment` 190, `pull_request_review_comment` 135, `pull_request` 5 |
| `pr-auto-review` | `pull_request_review` 149, `check_suite` 32, `workflow_run` 16, `pull_request` 11 |
| `pr-review` | `pull_request_review` 149, `check_suite` 32, `pull_request` 6 |
| `ci-failure-analyst` | `check_run` 33 |

## AC10 — skip-kind classification is resolved for this repo

AC10 requires the two skip kinds to be measured separately, because a role that relied on an
**event-level `paths:` filter** starts paying a per-event runner cost once its filter moves inside
the reusable (kind **b**), while a job skipped by a job-level `if:` event filter is evaluated on the
Actions service and never assigned a runner (kind **a**).

**No collapsible caller in `markets` uses `paths:` or `paths-ignore:`** — verified across all five
stubs above; none uses a `paths:`/`paths-ignore:` event filter. Their non-path trigger constraints
must still be recorded so the AC2 union `on:` block preserves each role's original subscription and
does not run on unrelated branches or workflow completions. Two stubs carry a non-`types:` narrowing
that the union **must** preserve:

- `dev-lead`'s `pull_request` trigger narrows to **`branches: [main]`** (`dev-lead.yml:35-37`). This
  is not expressible per-job at the `on:` level, so it moves into the dev-lead job's `if:` as the
  payload predicate **`github.event.pull_request.base.ref == 'main'`** — exactly as the canonical
  ingress does (`docs/architecture/reference/agent-ingress.yml:74-78`). Dropping it would let a
  write-capable role run for PRs targeting release or other branches, expanding its scope and
  inflating the post-collapse count.
- `pr-auto-review`'s `workflow_run` trigger narrows to a **`workflows:` list** (`["CI"]`, the repo's
  CI workflow name; `pr-auto-review.yml`), so it does **not** subscribe to all repo workflows; the
  union must carry that constraint into that job's `if:` likewise.

The remaining stubs filter on event `types:` only. Crucially, **none of these narrowings is a
`paths:`/`paths-ignore:` filter** — they all collapse into job-level `if:` payload predicates
evaluated on the Actions service without assigning a runner. So **every post-collapse skip is kind
(a)** and no role incurs the kind (b) runner cost. AC10 is satisfiable here by measuring
kind (a) alone, and the finding should be re-verified per repo during fan-out rather than assumed —
`.github-private`'s own `dependency-advisory` shape is the known kind (b) case.

## Carve-outs and non-callers (excluded from the bound)

Excluded by the ADR and by #1729 AC1; listed so the eligible set is falsifiable.

| Workflow | Why excluded | Runs (7d) |
|---|---|---|
| `add-to-project.yml` | `pull_request_target` carve-out | 28 |
| `dependabot-automerge.yml` | `pull_request_target` carve-out | 11 |
| `dependabot-rebase.yml` | timer + `push` carve-out | (in Dependabot totals) |
| `auto-rebase.yml` | `push` + `workflow_dispatch`, keeps its own file | 5 |
| `apply-repo-settings.yml` | Class-2/3 timer | — |
| `feature-ideation.yml` | Class-2/3 timer (`schedule`/`discussion`) | 1 |
| `ci.yml` | not thin callers (inline logic) | 16 |
| `shell-tests.yml` | not thin callers (inline logic) | 4 |
| `sonarcloud.yml` | not thin callers (inline logic) | 16 |
| `copilot-setup-steps.yml` | not thin callers (inline logic) | — |
| `initiative-driver.yml` | not thin callers (inline logic) | 18 |
| `agent-shield.yml` | gate workflow, not an agentic role — out of scope per ADR-0007 & agentic-interaction-model | 16 |
| `dependency-audit.yml` | CI/gate workflow, not an agentic role — out of scope per ADR-0007 & agentic-interaction-model | 16 |

**Reconciliation to the 1531 repo-wide total.** Collapsible 1342 + enumerated carve-outs (28 + 11 +
5 + 1 + 16 + 4 + 16 + 18 + 16 + 16 = 131) = **1473**. The remaining **58** runs are the workflows
recorded above without a broken-out per-workflow figure: `dependabot-rebase.yml` (timer + `push`;
folded into the Dependabot totals rather than counted separately here) and the `—` rows
(`apply-repo-settings.yml`, `copilot-setup-steps.yml`), none of which is a collapse candidate. The
authoritative repo-wide figure is the 1531 `total_count`; the enumerated rows above are the
falsifiable eligible set, not a full per-workflow census.

### Classification of `agent-shield.yml` and `dependency-audit.yml` — resolved as carve-outs

Both are `agent-shield/v2-stable`/`dependency-audit/v2-stable` first-party thin callers on Class-1
events, so ADR-0007's caller-shape rule would admit them, but both are **gates rather than agentic
roles**. ADR-0007 excludes "non-agentic CI and gate workflows" from scope
([`0007-one-agent-ingress-stub-per-repo.md`](../architecture/adr/0007-one-agent-ingress-stub-per-repo.md)
lines 115–117), and `docs/agentic-interaction-model.md` lists `dependency-audit.yml` (CI
infrastructure) and `agent-shield.yml` (gate) on its out-of-scope surfaces. They are therefore
**excluded carve-outs**, recorded in the carve-out table above (16 runs each); they do **not** enter
the 1342 collapsible total, which is unchanged. #1729 AC1's "enumerate explicitly" requirement is
satisfied by this deliberate exclusion rather than by omission.

## Two pin defects observed while capturing this

Neither blocks the baseline; both affect the collapse, since the ingress carries each role's pin
forward per-job.

1. **`pr-review.yml` pins the deprecated bare-tier channel `pr-review/stable` rather than the
   canonical major-scoped `pr-review/v1-stable`.** This is a pin-contract failure in its own right —
   `reusable-pin-compliance` now reports a bare-tier pin as a failure, not a warning (AGENTS.md
   "Release channel tags & the mutable-ref exception"; #1493 AC #12) — separate from and independent
   of staleness. The ref also happens not to have moved since 2026-06-20 (`ceab48a1`). Fix by
   migrating the pin to `pr-review/v1-stable` before carrying it into the ingress; leave channel
   advancement to the health-gated promotion process (#501), and do **not** pin the immutable release
   `pr-review/v1.10.0` directly (that bypasses staged promotion). `v1-stable` records at the same
   `ceab48a1` commit today per `docs/release/versioning.md`, so this is a name-correctness fix, not a
   version bump.
2. **`ci-failure-analyst.yml` pins a bare SHA** (`e37e9eb4`) rather than a channel tag, so it
   receives no promotions at all. ADR-0002 makes the channel tag the canonical caller pin. **The
   intended target is the major-scoped stable channel `ci-failure-analyst/v1-stable`**, which today
   records at `cc0bc61f` (resolved via `git ls-remote origin ci-failure-analyst/v1-stable`) — **not** the pinned `e37e9eb4`. Because the
   channel resolves to different code than the current pin, the pin correction is a code upgrade and
   must be sequenced **separately from the collapse**, not folded into it: either migrate the pin to
   `ci-failure-analyst/v1-stable` and **recapture this baseline before** the collapse experiment, or
   hold `e37e9eb4`-equivalent code across the before/after comparison. Bundling the upgrade into the
   collapse would confound the executed-job delta — any change could come from the code bump rather
   than the ingress topology, so the collapse is **not** the natural upgrade point.
