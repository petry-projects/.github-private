# SC2 game-day — prove a broken `next` can't block its own fix

**Invariant (Safe Release SC2, epic #495 · story #503):** a broken in-development
version of an agentic workflow **cannot block the PR that fixes its own breakage.**
This is the circular-dependency failure the whole Safe Release strategy exists to
eliminate (`dev-lead`/`pr-review` build, review, and merge changes *to themselves*).

## Why the invariant holds

Two mechanisms together guarantee it. For downstream consumer repos pinned to
`stable`, either alone is sufficient. For **this repo** (the ring-0 canary) the
two duties are split by design: `dev-lead.yml` (the dev/merge duty) pins a
**stable-tier** channel (`@dev-lead/v1-stable`) so mechanism (1) protects it here
exactly as it does a downstream consumer, while `pr-review-trigger.yml`
deliberately pins `next` to dogfood the candidate, so mechanism (2) is that
path's operative SC2 safety net:

1. **Channel decoupling (structural).** New versions are exercised on `next`/`ring0`
   while production self-review/dev duty stays pinned to `stable`
   ([versioning.md](./versioning.md)). A break in `next` does not, by
   construction, take out a `stable`-pinned gate — the fix PR is still evaluated by
   the last known-good `stable`. **This repo keeps its dev/merge duty
   (`dev-lead.yml`) pinned to `@dev-lead/v1-stable` even though it sits in ring
   `next`** — the deliberate SC2 exception (#1624). `pinned-version-report` flags
   that pin as a ⚠️ ring mismatch (it expects `next` for a ring-`next` repo); that
   flag is correct from the ring-rollout view and the stable pin is correct from
   the SC2 view — the two are reconciled, not contradictory (see
   [versioning.md](./versioning.md) "Production self-review/dev duty stays pinned
   to `stable`"). By contrast `pr-review-trigger.yml` pins `next` to dogfood the
   candidate, so for the pr-review path channel decoupling alone does not provide
   the SC2 guarantee — mechanism (2) is required there.

2. **Break-glass (operational, #619).** For the residual case where a break *does*
   reach the gate that must review its own fix — e.g. a bug in `compute_ci_status`
   that marks the fix PR "failing" — a manual `FORCE_REVIEW` run (`@mention` /
   `workflow_dispatch`) bypasses the following soft gates:
   - advisory-bot gate, `CHANGES_REQUESTED`, idempotency, and the review cap
     (pre-existing), **and**
   - the `ci-failing` gate (`scripts/review-one-pr.sh`, shipped in #1230).

   **Exception — per-PR automation budget (`enforce_pr_budget`).** `FORCE_REVIEW`
   does **not** bypass the `enforce_pr_budget` gate; a FORCE_REVIEW mention that
   finds the budget exhausted exits with
   `"reason":"automation-budget-exhausted"` before reaching the review cascade.
   The budget resets only on a human interaction (comment, push, or approval).
   If the fix PR has already exhausted its budget, a human must interact with the
   PR first to reset the budget before the break-glass can proceed.

   `FORCE_REVIEW` is **manual-only** (the scheduled sweep dispatches
   `force_review=false`), and GitHub's ruleset still blocks the merge on any
   failing **required** check, so the break-glass only unblocks the
   codeowner-approval gate — it cannot merge a genuinely-broken PR.

## Automated regression guards

`tests/test_sc2_self_review_channel.bats` codifies mechanism (1) for this repo:
it parses the `uses:` channel pin of `dev-lead.yml` (never a hardcoded version)
and asserts it resolves to a **stable-tier** channel — failing with an
SC2-naming message if a future "fix the ring drift" PR repins the dev/merge duty
to `next`/`ring*`/`@main`/a bare SHA and silently restores the circular
dependency. It is the automatable half of #503 (this repo's structural SC2
property), complementing the game-day drill below.

`tests/test_review_one_pr_force_ci_failing.bats` codifies mechanism (2):

- a **normal** run on failing CI still skips (`reason=ci-failing`, exit 100) — the
  gate is not weakened for day-to-day operation;
- a **`FORCE_REVIEW=true`** run on failing CI **bypasses** the `ci-failing` gate
  (exit is not 100; the run is not skipped with `reason=ci-failing`).

  Note: the test asserts the gate is not tripped (exit ≠ 100 and the bypass
  warning appears). It does not verify that a review is subsequently submitted
  and approved — a downstream engine or posting failure could still prevent
  approval even with a passing test.

If a future change re-couples the gate to its own fix, that test fails.

## Running the game-day (operational drill)

Run this after any material change to the CI gate (`compute_ci_status`,
`review-one-pr.sh` skip logic) or the channel-pinning layout.

1. **Break `next` deliberately.** On a scratch branch, introduce a change to the
   `next`-channel review gate that marks all PRs as `ci-failing` (e.g. force
   `compute_ci_status` to return `failing`). Promote it to `pr-review/next` only
   (`cut-release.sh pr-review <version> --channel next --push`), never `stable`.
2. **Open the fix PR** that reverts/repairs the break, targeting `main`.
3. **Confirm the block reproduces.** The unattended cascade skips the fix PR with
   `reason=ci-failing` (the broken gate is reviewing its own fix).
4. **Apply the break-glass.** `@mention` the review bot (or `workflow_dispatch`
   the trigger with `force_review=true` **and the fix PR's `pr_url`**) on the fix
   PR. Expect the
   `::warning::force-review: … bypassing the ci-failing gate (break-glass, #619)` line and an
   approval from the reviewer identity.
5. **Merge** (required checks green at the ruleset); the fix lands on `main`.
6. **Advance `pr-review/next`** to the repaired release:
   `cut-release.sh pr-review <version> --channel next --push`. Record the drill
   outcome on #503.

**Pass criteria:** the fix PR is reviewed and approved via the break-glass within
one manual action, with no admin ruleset bypass and no manual file surgery — SC2
and SC4 (one-action) both satisfied.
