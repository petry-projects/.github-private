# Scenarios: standards-sync

## Overview

The `standards-sync` workflow runs on a monthly schedule (first Monday of each month)
and checks all org repos against the org standards defined in `AGENTS.md`, `CODEOWNERS`,
and required workflow files. For any repo that is out of sync, it opens a PR with the
required additions.

**Trigger:** `schedule` (monthly, first Monday at 09:00 UTC — `0 9 1-7 * 1`)
**Outputs:** PRs opened on out-of-sync repos

---

## Scenario 1: Repo missing AGENTS.md

**Given** a repo in the `petry-projects` org does not have an `AGENTS.md` file
**When** the monthly schedule fires
**Then**
- the workflow detects the missing file
- a PR is opened on that repo adding `AGENTS.md` with the org-standard content
- the PR title is `chore: add AGENTS.md (standards-sync)`
- the PR is labelled `standards-sync`

**Assertions:**
- A PR is opened on the out-of-sync repo
- The PR diff contains `AGENTS.md` as a new file
- No PR is opened if the repo already has `AGENTS.md`

---

## Scenario 2: Repo missing CODEOWNERS

**Given** a repo does not have `.github/CODEOWNERS`
**When** the monthly schedule fires
**Then**
- the workflow detects the missing file
- a PR is opened adding a default `CODEOWNERS` pointing at org-wide owners

**Assertions:**
- PR contains `.github/CODEOWNERS` as a new file
- File content matches the org-standard template

---

## Scenario 3: Repo already compliant

**Given** a repo has all required files: `AGENTS.md`, `.github/CODEOWNERS`
**When** the monthly schedule fires
**Then**
- no PR is opened for that repo
- the workflow logs a "compliant" notice for the repo

**Assertions:**
- No new PRs are created for compliant repos
- Workflow exits 0

---

## Scenario 4: PR already open for the repo

**Given** a standards-sync PR is already open for a repo (from a previous run)
**When** the monthly schedule fires again
**Then**
- the workflow detects the existing open PR
- no duplicate PR is opened
- the workflow logs "skipping — PR already open" for that repo

**Assertions:**
- No duplicate PR is created
- Idempotency: running twice produces the same state

---

## Scenario 5: Archived or private repo

**Given** a repo in the org is archived
**When** the monthly schedule fires
**Then**
- the workflow skips archived repos
- no PR is opened on an archived repo (GitHub API would reject it anyway)

**Assertions:**
- Archived repos are excluded from the sync list
- Script does not emit errors for archived repos

---

## Scenario 6: Cross-org compliance summary

**Given** the workflow has run across all repos
**When** the run completes
**Then**
- a summary issue is opened in `.github-private` listing compliance status
- the issue shows: total repos scanned, compliant count, PRs opened count

**Assertions:**
- A summary issue is created in `petry-projects/.github-private`
- Issue body contains a compliance table or list
- Issue is labelled `standards-sync` and `automated-report`
