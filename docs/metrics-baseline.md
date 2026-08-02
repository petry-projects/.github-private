# Success Metrics — Definitions & Pre-Rollout Baseline

This document is the falsifiability contract for epic
[#1402](https://github.com/petry-projects/.github-private/issues/1402). It fixes the **three
success metrics** — convergence, redundancy, and noise — with unambiguous definitions, and
records a **dated pre-rollout baseline** so the epic's claims can be checked with before-and-after
evidence rather than asserted.

It gates the timer/behaviour changes in
[#1407](https://github.com/petry-projects/.github-private/issues/1407) and
[#1408](https://github.com/petry-projects/.github-private/issues/1408): the baseline below must be
captured **before** those changes alter the behaviour being measured, or the "before" is
contaminated.

## The substantive vs. trivial-stub-sync split

The PR population is **bimodal** and averaging across it hides the effect this initiative targets:

- **Substantive PRs** — a PR that changes non-generated source: any file **outside** the verbatim
  stub/baseline set (`.github/workflows/*.yml` caller stubs, `repo-template` seeds, generated
  READMEs) **and** whose net diff is non-empty. These are the PRs the convergence/redundancy claims
  are about.
- **Trivial stub-sync PRs** — verbatim propagation of a canonical stub/baseline (fleet stub-drift
  remediation, template/readme refresh). They merge in minutes yet still draw 5–8 bot comments, so
  they inflate the comment counts while telling us nothing about review convergence.

**Every metric below is reported for the substantive population.** Where a figure is stated for all
PRs it is labelled *(all PRs)*.

---

## 1. Convergence — cycles-to-merge and time-to-converge

| Field | Definition |
|---|---|
| **What is counted** | Two numbers per merged PR: **cycles-to-merge** = the number of automated review/fix cycles (commits that triggered a re-review) between open and merge; **time-to-converge** = wall-clock from PR creation to merge. |
| **Window** | Rolling `LOOKBACK_DAYS` (report default 7 for the after-run; the baseline uses the pre-change window stated below). |
| **PR scope** | Merged **substantive** PRs. Trivial stub-sync PRs are reported separately and never averaged in. |
| **Attribution** | Per PR, from GitHub's own commit/merge timestamps and the pr-review re-review events. Latency percentiles for the review workflow itself are surfaced by `scripts/pr_review_health.sh` ("Convergence latency" — p50/p95 of run duration). |

## 2. Redundancy — workflow runs per hour and runs per PR

| Field | Definition |
|---|---|
| **What is counted** | **Runs per hour** = review-related workflow runs ÷ hours in the window; **runs per PR** = review-related workflow runs ÷ distinct PRs touched in the window. |
| **Window** | Same rolling window. Runs-per-hour is normalised by the window length so baseline and after are comparable regardless of window size. |
| **PR scope** | Runs-per-PR is measured over all PRs (redundancy is a fan-out property, not a substance property), with the substantive subset reported alongside. |
| **Attribution** | Reuses the existing review-event accounting: `reviewer_report.sh` counts reviews as **events** ("a PR re-reviewed across N commits contributes N reviews") and reports **coverage overlap** (PRs reviewed by ≥2 bots) — the closest existing redundancy signal. Cost fan-out reuses `scripts/token_report.sh`'s "Most expensive PRs (top 10)" pipeline; no parallel accounting is invented. |

## 3. Noise — no-action agent comments per PR

| Field | Definition |
|---|---|
| **What is counted** | **No-action agent comments** as a count, as a **share** of all agent comments, and **per PR**. An *agent comment* is any comment/review carrying one of our automation markers; a *no-action* comment asks nothing of a human. Full definition and the marker/body list live in [`docs/reviewer-report.md` → Agent comment noise](./reviewer-report.md#agent-comment-noise-our-own-automation). |
| **Window** | Same rolling window and the same all-non-archived-repo sweep as the reviewer scorecard. |
| **PR scope** | Every PR active in the window (attribution is by marker, not author). |
| **Implementation** | Net-new — it did **not** exist before #1411. Pure classifier `scripts/lib/comment-noise.sh`, unit-tested in `tests/comment_noise.bats`, applied inside `reviewer_report.sh`'s existing collection pass so baseline and after share one code path. |

---

## Pre-rollout baseline snapshot

- **Captured (dated):** 2026-08-02
- **Pre-change window:** 2026-07-26T00:00:00Z – 2026-08-02T00:00:00Z (7-day rolling window, over all non-archived `petry-projects` repos)
- **Repository scope:** all non-archived repos in the `petry-projects` org (count logged by `reviewer_report.sh` at each run start)
- **PR cohorts:** substantive PRs = non-generated source changed, non-draft, merged in window; trivial stub-sync PRs = verbatim canonical-stub propagation (reported separately, never averaged into substantive figures)
- **Sample:** the known-working figures below are the measured pre-change references cited on epic
  #1402; they are reproduced (or corrected, with the discrepancy explained) by the same code path
  that produces every after-run — `scripts/reviewer_report.sh` (noise, redundancy overlap),
  `scripts/pr_review_health.sh` (convergence latency), and `scripts/token_report.sh` (cost fan-out).

| Metric | Baseline (substantive) | Baseline (all PRs) | Source of the after-measurement |
|---|---|---:|---|
| Convergence — time-to-converge | **~20–48 h** (p50 / p95 range) | — | `pr_review_health.sh` "Convergence latency" (p50/p95) |
| Convergence — cycles-to-merge | **~7–13 commits** per merged substantive PR | trivial stub-sync merges in minutes | pr-review re-review events |
| Redundancy — workflow runs/hr | — | **~52 runs/hr** (7-day window, all-PRs scope) | `pr_review_health.sh` run telemetry / `reviewer_report.sh` |
| Redundancy — coverage overlap | — | PRs reviewed by ≥2 bots (see scorecard) | `reviewer_report.sh` "Coverage overlap" |
| Noise — no-action comment share | — | **~12%** of first-party agent comments (our markers only); raw counts confirmed on first scheduled run (see denominator reconciliation note) | `reviewer_report.sh` "Agent comment noise" |

### Noise metric — raw measurement details

Because the classifier is net-new (#1411), no deterministic pre-change count existed before this
baseline was captured. The ~12% figure is the pre-rollout estimate; the first scheduled
`reviewer-report.yml` run will produce the exact values below via `cn_render_noise_section`:

| Field | Value | Note |
|---|---|---|
| Agent comments (total) | *confirmed on first run* | all marker-bearing comments/reviews in the 7-day window (first-party only — see denominator note below) |
| No-action comments | *confirmed on first run* | share of first-party agent comments (~12% pre-rollout estimate; see denominator note) |
| Active PRs (window) | *confirmed on first run* | distinct `kind:"pr"` records in the JSONL collection |
| Affected PRs (≥1 no-action) | *confirmed on first run* | distinct PRs with at least one no-action agent comment |
| No-action comments per PR | *confirmed on first run* | no-action count ÷ PRs with any agent comment |

Any divergence between the ~12% estimate and the first measured value is a measurement correction;
record it by appending a dated row here rather than overwriting this baseline.

### Reconciliation notes

- **Convergence** and **redundancy** baselines are quoted as ranges because the pre-change data is
  bimodal (see the split above); the substantive band (~20–48 h, ~7–13 commits) is the target of the
  initiative, while trivial stub-sync PRs sit far below it and are reported, not averaged in.
- **Noise ~12%** is the pre-rollout no-action estimate. Because the classifier is net-new, this figure
  had no prior deterministic source; the first scheduled `reviewer-report.yml` run confirms it via
  `cn_render_noise_section`. Any material divergence from ~12% on that first run is a measurement
  correction to record **here** (append a dated row), not a silent overwrite of this baseline.
- **Denominator scope (first-party only):** The `cn_render_noise_section` metric counts only
  first-party agent comments — bodies that carry one of our automation markers (`<!-- pr-review-agent
  …-->`, `<!-- dev-lead …-->`, etc.). Third-party reviewer bots (Codex, Qodo, SonarCloud, etc.) do
  not emit these markers and are classified as `non-agent`; they are already measured separately via
  the reviewer scorecard. The AC #4 ~12% figure cited in issue #1411 was also measured over
  first-party markers only (it pre-dates the classifier and was an estimate, not a live
  all-comments count), so the denominators are consistent. Any future comparison against an
  all-comments denominator should be labelled explicitly to avoid confusion.
- **No new scheduled workload:** every after-measurement rides an existing report/cron. This
  document is the fixed "before" the timer changes in #1407/#1408 are measured against.
