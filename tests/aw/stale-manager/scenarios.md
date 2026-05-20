# Stale Manager — Test Scenarios

## Context

Org-wide scheduled workflow that identifies stale issues and PRs and either warns or closes them.
Staleness thresholds: issues > 60 days since last update, PRs > 30 days since last update.
Grace period before closing a stale item: 7 days with no activity after the `stale` label was applied.

Idempotency rule: if an item already has a stale label and a warning comment at the current run,
no second comment is posted.

---

## Scenario 1 — Issue stale: warn and label

**Input:**
- Open issue, last updated 61+ days ago
- Labels: none (no `pinned`, no `no-stale`, no `stale`)

**Expected:**
- Workflow posts a comment on the issue warning that it will be closed in 7 days due to inactivity
- Workflow adds the `stale` label to the issue
- Workflow does NOT close the issue

**Idempotency check:**
- If the workflow runs again before any activity occurs, no second warning comment is posted

---

## Scenario 2 — PR stale: warn and label

**Input:**
- Open PR, last updated 31+ days ago
- Labels: none (no `pinned`, no `no-stale`, no `stale`)

**Expected:**
- Workflow posts a comment on the PR warning that it will be closed in 7 days due to inactivity
- Workflow adds the `stale` label to the PR
- Workflow does NOT close the PR

**Idempotency check:**
- If the workflow runs again before any activity occurs, no second warning comment is posted

---

## Scenario 3 — Stale item with no activity for grace period: close

**Input:**
- Open issue or PR that already has the `stale` label
- Last activity (label applied or any update) was 7+ days ago

**Expected:**
- Workflow posts a closing comment explaining the issue/PR is being closed due to inactivity
- Workflow closes the issue/PR
- Closed item is NOT re-opened by the workflow

---

## Scenario 4 (Edge) — Pinned item: skip entirely

**Input:**
- Open issue or PR with the `pinned` label
- Last updated 90+ days ago (would otherwise qualify as stale)

**Expected:**
- Workflow takes no action
- No comment posted, no label added or removed, no close

---

## Scenario 5 (Edge) — No-stale item: skip entirely

**Input:**
- Open issue or PR with the `no-stale` label
- Last updated 90+ days ago (would otherwise qualify as stale)

**Expected:**
- Workflow takes no action
- No comment posted, no label added or removed, no close

---

## Scenario 6 (Edge) — Stale label present but item was updated: remove stale label

**Input:**
- Open issue or PR with the `stale` label already applied
- Item was updated (comment, push, or edit) after the `stale` label was applied
- Update was within the grace period (< 7 days since label was applied)

**Expected:**
- Workflow removes the `stale` label
- Workflow does NOT post a comment and does NOT close the item
- Item is treated as active again on the next run

---

## DRY_RUN behavior

When `DRY_RUN=true` (the default staged configuration):
- All scenarios above are evaluated and the intended action is logged to step summary
- No GitHub API write calls are made (no comments posted, no labels applied, no issues closed)
- Output: step summary listing each item, its staleness determination, and the action that would be taken
