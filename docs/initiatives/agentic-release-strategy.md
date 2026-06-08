# Initiative: Safe Release Strategy for Agentic Workflows

**Status:** Proposed — for review
**Author:** dev-lead / Claude Code
**Date:** 2026-06-08
**Scope (confirmed):** Core agentic workflows + their delivery path — `dev-lead`, `pr-review`,
and the deploy/release mechanism that pushes them to consumer repos. Utility workflows
(fleet-monitor, compliance, token-report, ci-failure-analyst, etc.) are out of scope for now
and adopt the pattern later.
**Constraints (confirmed):** GitHub-native only (tags/releases, `@ref` pinning, Environments,
matrix-staged deploys) — no new repos, no external infrastructure. Canary / ring-0 = `.github-private`
itself (dogfood-first).
**GitHub Project:** [Initiatives](https://github.com/orgs/petry-projects/projects/1) →
Initiative field **“Release Strategy”**.

---

## 1. Executive summary

Our two most critical pieces of agentic infrastructure — the **dev-lead** agent (plans, implements,
and merges changes) and the **pr-review** agent (reviews and approves them) — are **self-hosting**:
they are the tools that build, review, and ship changes *to themselves*. Today there is **no version
boundary** between “the agent doing the work” and “the agent being changed”:

- **`.github/workflows/pr-review-reusable.yml`** calls `pr-review.yml@main`, meaning all callers
  of the reusable inherit a floating ref. There are **0 git tags and 0 releases** in the repo.
- A merge to `main` is therefore **instantly live** across the agents' own self-review duty *and*
  every consumer repo, with **no canary, no health gate, and no rollback**.
- Deployment to consumers is a blunt `PUT /contents` **overwrite of `main`** across all four
  consumer repos at once (`.github/workflows/deploy-pr-review.yml`).

The result is a **circular dependency that fails closed**: when a change breaks `pr-review.yml`, the
very agent that must approve the fix PR is the broken one, so clean fix-PRs stall at `REVIEW_REQUIRED`
indefinitely (issue #463). When a change breaks `dev-lead`, it can no longer reliably fix itself
(#466). The “known-good” version is destroyed the instant the new one lands, and there is no version
to roll back *to*.

This initiative proposes a **GitHub-native versioned-release model with concentric rings and
health-gated promotion**. The core move: production duty (the agents' own self-review and all consumer
repos) runs a **pinned, immutable “stable” version**, while new versions are exercised on a **`next`
channel in ring 0 (`.github-private` self-host)** and promoted ring-by-ring only after they prove
healthy. This breaks the circular dependency (a broken in-development version can no longer gate its
own fix), shrinks blast radius from “whole fleet, instantly” to “one ring at a time,” and makes
rollback a single pointer flip.

**Recommendation:** Option C — *Versioned releases + concentric rings with health-gated promotion*,
delivered in two phases (Phase 1 = versioning + pinning; Phase 2 = rings + automated promotion/rollback).

---

## 2. Problem statement

### 2.1 Two compounding root causes

**Root cause A — Self-hosting circular dependency.**
`dev-lead` and `pr-review` gate changes to themselves. The agent under change is also the agent
enforcing the merge gate on the change. When the in-flight version is broken, it blocks the fix for
its own breakage. There is no independent “known-good” instance holding production duty while the new
version is validated.

**Root cause B — No version boundary (`@main` everywhere).**
Consumers and the agents' own callers all reference `…/pr-review.yml@main` and the dev-lead reusable
at floating refs. With **0 tags / 0 releases**, there is no immutable artifact to pin to, promote, or
roll back. “Latest commit on main” *is* production, everywhere, simultaneously.

These compound. A bad change is (A) able to block its own fix **and** (B) already live across the
entire fleet before anyone notices — the worst of both failure modes at once.

### 2.2 How a bad change plays out today

```
 merge to main ──► @main resolves to the new (broken) commit
        │
        ├──► .github-private's own pr-review/dev-lead duty now broken
        │        └──► fix PR can't be reviewed/approved  ──► stuck at REVIEW_REQUIRED (#463)
        │        └──► dev-lead retry loop spins every 30 min forever (#466)
        │
        └──► all consumer repos (bmad-bgreat-suite, google-app-scripts, markets, ContentTwin)
                 pick up the broken version on their next PR — no gate, no canary
```

There is no point in this flow where a known-good version is preserved and serving traffic.

### 2.3 Delivery mechanism is fragile

`.github/workflows/deploy-pr-review.yml` / `.github/workflows/force-deploy-pr-review.yml`:

- `base64` + `PUT /repos/<repo>/contents/<path>` — a **direct overwrite of the file on `main`** of
  each consumer.
- Fans out to **all four consumer repos in one matrix run**, no staggering, no health check between
  repos, no verification that the new version actually works before the next repo gets it.
- No record of *what version* each consumer is on, and no mechanism to revert other than manually
  pushing the old file back.

---

## 3. Evidence & metrics

All figures pulled from the live repo / GitHub API on 2026-06-08.

| Metric | Value | Source |
|---|---|---|
| Immutable release artifacts (tags/releases) | **0 tags, 0 releases** | `git tag`, `gh release list` |
| Consumer reference model | **`@main`** (floating) — `.github/workflows/pr-review-reusable.yml` calls `pr-review.yml@main`, coupling all callers of the reusable to the floating ref | `.github/workflows/pr-review-reusable.yml` |
| Automated “failure detected” issues filed | **48** since 2026-05-06 (~daily) | `gh issue list --label automated-report` |
| …currently still OPEN (unresolved backlog) | **20**, oldest 2026-05-28 → **11 consecutive unresolved days** | same |
| PR Review Agent — last 20 runs | **0 successes** (all `cancelled`) | `gh run list --workflow=pr-review.yml` |
| Recent run cancellation rate | **34%** (68 of last 200 runs `cancelled`) | `gh run list --limit 200` |
| Deploy blast radius | **4 consumer repos overwritten on `main` simultaneously** | `.github/workflows/deploy-pr-review.yml` |
| Self-repair churn (peak) | **123 commits / week (W19)**, 25 PRs merged on 2026-05-20 alone | `git log` |
| Open issue mix | 82 health-check · 70 dev-lead · 14 bug | `gh issue list` label counts |

**Named stuck-state incidents** (the circular dependency in production):

- **#463** — Clean PRs (green CI, 0 unresolved threads) stuck at `REVIEW_REQUIRED` forever because the
  pr-review agent never reaches its approve path; the only eligible approver is the agent itself, which
  is broken/skipping. *The fix for pr-review is blocked by pr-review.*
- **#466** — dev-lead's blocked-retry cron re-dispatches every 30 minutes **indefinitely** on a lone
  cancelled check; the retry machinery retries the *agent*, but the blocker is the *check* — nothing
  in the loop can resolve it without a human.
- **#305** — PR #131 (7 pr-review safety checks) accumulated 28 merge-conflict sentinels and was
  **closed unfixable** because the agent's own scripts were being restructured underneath it on `main`.

**Interpretation.** The daily failure-report cadence (48 issues, 20 still open) and the 0/20 PR-review
success streak are not independent bugs — they are the *expected steady-state* of a self-hosting system
with no version boundary. Each fix ships to `@main`, instantly becomes production for the agent that
must validate the *next* fix, and any regression strands the queue. We are paying for the absence of a
release strategy in continuous operational toil.

---

## 4. Success criteria

The initiative is successful when **all** of the following hold (measurable acceptance criteria):

| # | Success criterion | Measure / target |
|---|---|---|
| SC1 | A known-good version is **always referenceable** and serving production duty | A `stable` pointer (tag/release) always resolves to a version that passed health gates; production callers never reference `@main` |
| SC2 | **Circular dependency eliminated** | A deliberately-broken in-development version of pr-review/dev-lead **cannot** block its own fix PR (validated by a regression test / game-day) |
| SC3 | **Blast radius is staged**, never fleet-wide-instant | No deploy path overwrites >1 ring at a time; ring N+1 only updates after ring N is healthy |
| SC4 | **Fast, one-action rollback** | Reverting to the previous known-good version is a single action (pointer flip / revert PR) completing in **< 5 minutes**, no manual file surgery |
| SC5 | **New versions validated before production** | Every promotion to `stable` is preceded by ring-0 (`.github-private`) health validation over a defined soak window |
| SC6 | **Operational toil falls** | Automated failure-report issue rate and the open backlog trend **down** (target: open `automated-report` backlog < 5, from 20; cancellation rate < 10%, from 34%) over the 60 days after rollout |
| SC7 | **Innovation velocity preserved or improved** | Time-to-merge for an agent change does not regress; developers can ship to `next` continuously without waiting on a full fleet rollout |
| SC8 | **Every consumer's version is known** | A single command/report shows which version each consumer + each ring is pinned to |

SC2 and SC4 are the **must-haves** (they directly neutralize the two root causes). SC6/SC7 are the
outcome metrics we track post-launch.

---

## 5. Industry patterns, mapped to GitHub-native primitives

Because the constraint is **GitHub-native only**, each classic pattern is translated to the primitives
we actually have (tags/releases, `@ref` pinning in `uses:`, Environments + required reviewers, matrix
staging, branch protection).

| Pattern | What it gives us | GitHub-native realization | Fit here |
|---|---|---|---|
| **Versioning** (semver / immutable refs) | A thing to pin, promote, roll back to | Release tags (`pr-review/vX.Y.Z`) or SHA pins; consumers use `uses: …@<tag-or-sha>` | **Foundational — required by all others** |
| **Blue/Green** | Two complete environments; flip traffic; instant rollback | Two channel pointers — `stable` (blue) and `next` (green) — as moving tags; “flip” = repoint consumers / update the production pointer | **Strong** — pointer flip = the rollback story |
| **Canary** | Small % exposure before full rollout | Ring 0 = `.github-private` self-host runs `next`; if healthy, promote | **Strong** — self-host is a natural canary |
| **Concentric rings** | Progressive exposure by blast radius | Ring 0 self-host → Ring 1 low-traffic consumer → Ring 2 remaining consumers; each ring pins its own ref, promoted in order | **Strong — the core of the recommendation** |
| **Progressive delivery / health-gated promotion** | Automated “advance only if healthy” | A health-gate job reads ring-N run success/cancellation metrics; promotes the pinned ref for ring N+1 via PR/pointer move only on green | **Strong** |
| **A/B testing** | Compare two variants on live traffic for quality | Possible (route some PRs to `next`, some to `stable`, compare review quality), but adds routing complexity | **Weak/optional** — defer; review “quality” is hard to measure objectively |
| **Feature flags** | Decouple deploy from release; kill-switch | Env-var/labels already used (`dev-lead:hands-off`, model flags); complements rings for sub-version toggles | **Complementary** — keep using, not a substitute |

**Key insight:** in a self-hosting setup, *versioning + rings + a stable pointer* together produce the
blue/green rollback story **and** break the circular dependency — because production review/dev duty
runs the pinned `stable` version, fully independent of whatever broken thing is sitting on `main`/`next`.

---

## 6. Options analysis

Five options, from “do nothing” to “full blue/green + A/B,” scored against the success criteria.

### Option A — Status quo / harden in place (baseline)
Keep `@main` everywhere; continue fixing individual stuck-state bugs (#463, #466) as they occur.

- **Pros:** No new machinery; each fix is small.
- **Cons:** Does **not** address either root cause. The circular dependency and instant-fleet-wide
  exposure remain; we keep paying the daily-failure toil. This is the trajectory the metrics already
  measure.
- **Verdict:** Rejected — it's the current failing baseline.

### Option B — Versioned releases + pinned refs (minimal)
Introduce immutable release tags for the reusable workflows; pin every consumer caller **and**
`.github-private`'s own production callers to a tag. Development happens on `main`; releases are cut
deliberately.

- **Pros:** Establishes the missing version boundary (Root cause B). A bad `main` no longer auto-ships.
  Rollback = re-pin to the prior tag. Low effort, pure GitHub-native.
- **Cons:** Manual promotion (no rings/automation yet). Doesn't *by itself* guarantee ring-0 validation
  before production, but it makes SC1/SC4 achievable. Partial fix for the circular dependency
  (production can run a pinned tag while `main` is broken — *if* we pin self-review duty too).
- **Verdict:** **Necessary foundation.** Adopt as **Phase 1**.

### Option C — Versioned releases + concentric rings + health-gated promotion *(RECOMMENDED)*
Build on B. Define a `stable` channel pointer (blue) and a `next` channel (green). Ring 0 =
`.github-private` self-host tracks `next`; Ring 1 = one low-traffic consumer; Ring 2 = remaining
consumers — each pinned to a ref that is promoted in order, gated by an automated health check that
reads the prior ring's run-success metrics. Rollback = move the pointer back (one action).

- **Pros:** Addresses **both** root causes. Production duty always on pinned `stable` ⇒ circular
  dependency broken (SC2). Blast radius staged ring-by-ring (SC3). One-action rollback via pointer
  flip (SC4). Ring-0 soak before any consumer sees a version (SC5). Innovation continues on `next`
  without risking production (SC7). All GitHub-native; no new repos.
- **Cons:** More moving parts than B (promotion workflow, health gate, pointer convention). Requires a
  defined health metric and soak window. Ring-0-as-canary means self-host *does* see new versions first
  — acceptable per the confirmed dogfood-first decision, mitigated by the `stable` pointer protecting
  the *production* self-review duty even while `next` is exercised.
- **Verdict:** **Recommended.** Phase 2 on top of B.

### Option D — Full blue/green with parallel live stacks + A/B quality routing
Run two complete parallel agent stacks; route a fraction of real PRs to each; compare review quality
(A/B) before promoting.

- **Pros:** Maximum safety and data on quality regressions.
- **Cons:** Heavy: needs traffic routing, dual secrets/identities, and an objective review-quality
  metric we don't have. Over-engineered for a solo-maintained org; high ongoing overhead (SC against
  it). Most of the safety benefit is already delivered by C.
- **Verdict:** Rejected for now; revisit A/B only if review-quality regressions become a measured
  problem.

### Option E — Adopt GitHub Merge Queue + environments as the gate (adjacent)
Lean on Merge Queue / Environments rather than versioned rings.

- **Pros:** Native, reduces some concurrency thrash (the 34% cancellation rate is partly concurrency).
- **Cons:** Solves *integration* ordering, not the **version boundary** or the self-hosting circular
  dependency — a merged-via-queue change is still instantly `@main`-live. Complementary, not a
  substitute. (Note: already under separate discussion, project item #358.)
- **Verdict:** Complementary — fold concurrency hardening in as a supporting task, not the strategy.

### 6.1 Scoring matrix

Scale: ✅ strong · 🟡 partial · ❌ none. (Effort/overhead: lower = better.)

| Criterion | A: Status quo | B: Versioning | **C: Rings (rec.)** | D: Blue/green + A/B |
|---|:--:|:--:|:--:|:--:|
| SC1 Known-good always referenceable | ❌ | ✅ | ✅ | ✅ |
| SC2 Circular dependency eliminated | ❌ | 🟡 | ✅ | ✅ |
| SC3 Staged blast radius | ❌ | 🟡 | ✅ | ✅ |
| SC4 One-action rollback (<5 min) | ❌ | ✅ | ✅ | ✅ |
| SC5 Validate before production | ❌ | 🟡 | ✅ | ✅ |
| SC6 Operational toil falls | ❌ | 🟡 | ✅ | 🟡 |
| SC7 Innovation velocity | 🟡 | 🟡 | ✅ | 🟡 |
| SC8 Every consumer's version is known | ❌ | 🟡 | ✅ | ✅ |
| Implementation effort | — | Low | **Medium** | High |
| Ongoing overhead | High (toil) | Low | **Low–Med** | High |
| Fits GitHub-native + solo maintainer | ✅ | ✅ | ✅ | ❌ |
| **Overall** | **Reject** | **Phase 1** | **✅ Recommend** | **Reject (defer A/B)** |

---

## 7. Recommended approach (Option C, phased)

### Phase 1 — Establish the version boundary *(unblocks SC1, SC4; partial SC2)*
1. Define a versioning scheme for the reusable workflows (per-agent semver tags, e.g.
   `pr-review/vMAJOR.MINOR.PATCH`, `dev-lead/vX.Y.Z`, plus the scripts they depend on).
2. Cut the first immutable release tag from current known-good `main`.
3. Repoint **all** callers — consumer repos *and* `.github-private`'s own production self-review/dev
   duty — from `@main` to the pinned tag. Development continues on `main`/feature branches.
4. Document the release-cut runbook.

After Phase 1: a broken `main` no longer auto-ships; rollback = re-pin to the prior tag.

### Phase 2 — Concentric rings + health-gated promotion *(completes SC2, SC3, SC5, SC8)*
5. Introduce two channel pointers: **`stable`** (blue, production) and **`next`** (green, candidate).
6. Define the rings:
   - **Ring 0** — `.github-private` self-host tracks `next` (dogfood/canary).
   - **Ring 1** — one low-traffic consumer.
   - **Ring 2** — remaining consumers.
   - **Production self-review/dev duty stays pinned to `stable`** even in ring 0 — this is what breaks
     the circular dependency: the agent validating fixes is never the broken candidate.
7. Replace the `PUT /contents` clobber deploy with a **versioned, ring-staged promotion** workflow.
   Promotion mechanism per ring:
   - **Ring 0** tracks the `next` moving tag directly — when `next` is advanced (moved to a new
     SHA/tag), ring 0 picks it up automatically via the moving pointer.
   - **Ring 1 and Ring 2** use **explicit pinned SHAs/tags** updated via automated bump PRs — the
     health-gate job opens a PR against each ring's caller with the new pinned ref; the PR merges
     only after the gate is green. This gives an explicit audit trail in each consumer's git history
     without requiring write access to consumer repos beyond the single file update.
   Ring N+1 advances only when an automated **health gate** confirms ring N is healthy
   (run-success rate, cancellation rate, no new failure-report issues over a soak window).
8. Implement **one-action rollback**: move `stable` back to the prior tag (revert pointer / revert PR).
9. Add **per-version observability**: a report showing each ring's/consumer's pinned version and the
   health metrics gating promotion (SC8).
10. **Game-day / regression test for SC2:** deliberately ship a broken `next`, prove the fix PR still
    merges (because production duty is on `stable`).

### What we explicitly defer
- A/B quality routing (Option D) — until review-quality regressions are a measured problem.
- Extending the model to utility workflows — after the agentic pattern is proven.

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Ring-0 = self-host means the source repo sees new versions first | Production self-review/dev duty stays pinned to `stable`; only the `next` lane runs the candidate. Confirmed dogfood-first trade-off. |
| Pinning to tags adds friction / staleness (consumers lag) | Automated promotion PRs bump the pinned ref; `next`-channel keeps innovation continuous. |
| Health gate gives false-green and promotes a bad version | Define a soak window + multiple signals (success rate, cancellation rate, failure-report issue creation); keep one-action rollback as the backstop. |
| “Two systems” increases maintenance | Phase 1 is intentionally minimal; Phase 2 automation pays for itself by eliminating daily toil (SC6). |
| Tag/release proliferation | Per-agent semver + a documented retention/runbook; floating `stable`/`next` pointers hide the churn from consumers. |
| Reusable workflows cannot natively determine their own running ref (unlike composite actions which expose `github.action_ref`), so local scripts (e.g., `scripts/dev-lead-fix-reviews.sh`) may be checked out at the caller's ref rather than the workflow's intended version | Pass the target ref as a required input to the reusable workflow so it can explicitly check out that version of `.github-private`; evaluate migrating core steps to composite actions (which expose `github.action_ref`) as a Phase 2 follow-on. |

---

## 9. Appendix

### 9.1 Glossary
- **Channel pointer (`stable`/`next`)** — a moving tag that consumers/rings reference; promotion = moving it.
- **Ring** — a cohort of consumers grouped by blast radius; updated in sequence.
- **Health gate** — an automated check that must pass before a ring advances.
- **Soak window** — the observation period a version must run healthy in a ring before promotion.

### 9.2 Key source references
- `.github/workflows/pr-review-reusable.yml` — `uses: …/pr-review.yml@main` (the `@main` coupling).
- `.github/workflows/deploy-pr-review.yml`, `force-deploy-pr-review.yml` — `PUT /contents` clobber deploy.
- Issues #463, #466, #305 — the circular dependency in production.
- `gh run list --workflow=pr-review.yml` — 0/20 success streak.

### 9.3 Decisions confirmed for this initiative
- Scope: core agentic + delivery.
- Infra: GitHub-native only (no new repos, no external infra).
- Canary / Ring 0: `.github-private` self-host.
