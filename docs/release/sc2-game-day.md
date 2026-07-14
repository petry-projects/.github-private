# SC2 game-day — prove a broken `next` can't block its own fix

**Invariant (Safe Release SC2, epic #495 · story #503):** a broken in-development
version of an agentic workflow **cannot block the PR that fixes its own breakage.**
This is the circular-dependency failure the whole Safe Release strategy exists to
eliminate (`dev-lead`/`pr-review` build, review, and merge changes *to themselves*).

## Why the invariant holds

Two independent mechanisms guarantee it; either alone is sufficient, and together
they are belt-and-suspenders:

1. **Channel decoupling (structural).** New versions are exercised on `next`/`ring0`
   while production self-review/dev **duty stays pinned to `stable`**
   (`versioning.md`). A break in `next` therefore does not, by construction, take
   out the gate that reviews the fix — the fix PR is still evaluated by the last
   known-good `stable`.

2. **Break-glass (operational, #619).** For the residual case where a break *does*
   reach the gate that must review its own fix — e.g. a bug in `compute_ci_status`
   that marks the fix PR "failing" — a manual `FORCE_REVIEW` run (`@mention` /
   `workflow_dispatch`) bypasses **every** soft gate, including the `ci-failing`
   gate:
   - advisory-bot gate, `CHANGES_REQUESTED`, idempotency, and the review cap
     (pre-existing), **and**
   - the `ci-failing` gate (`scripts/review-one-pr.sh`, shipped in #1230).

   `FORCE_REVIEW` is **manual-only** (the scheduled sweep dispatches
   `force_review=false`), and GitHub's ruleset still blocks the merge on any
   failing **required** check, so the break-glass only unblocks the
   codeowner-approval gate — it cannot merge a genuinely-broken PR.

## Automated regression guard

`tests/test_review_one_pr_force_ci_failing.bats` codifies mechanism (2):

- a **normal** run on failing CI still skips (`reason=ci-failing`, exit 100) — the
  gate is not weakened for day-to-day operation;
- a **`FORCE_REVIEW=true`** run on failing CI **bypasses** the gate — the fix can
  be reviewed and approved.

If a future change re-couples the gate to its own fix, that test fails.

## Running the game-day (operational drill)

Run this after any material change to the CI gate (`compute_ci_status`,
`review-one-pr.sh` skip logic) or the channel-pinning layout.

1. **Break `next` deliberately.** On a scratch branch, introduce a change to the
   `next`-channel review gate that marks all PRs as `ci-failing` (e.g. force
   `compute_ci_status` to return `failing`). Promote it to `pr-review/next` only
   (`cut-release.sh --channel pr-review/next …`), never `stable`.
2. **Open the fix PR** that reverts/repairs the break, targeting `main`.
3. **Confirm the block reproduces.** The unattended cascade skips the fix PR with
   `reason=ci-failing` (the broken gate is reviewing its own fix).
4. **Apply the break-glass.** `@mention` the review bot (or `workflow_dispatch`
   the trigger with `force_review=true`) on the fix PR. Expect the
   `::warning::force-review: … bypassing the ci-failing gate (break-glass, #619)` line and an
   approval from the reviewer identity.
5. **Merge** (required checks green at the ruleset), which restores `next`.
6. **Restore** `pr-review/next` to the repaired version and record the drill
   outcome on #503.

**Pass criteria:** the fix PR is reviewed and approved via the break-glass within
one manual action, with no admin ruleset bypass and no manual file surgery — SC2
and SC4 (one-action) both satisfied.
