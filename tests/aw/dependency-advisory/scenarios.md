# Scenarios: dependency-advisory

## Overview

The `dependency-advisory` workflow triggers on pull requests that touch dependency
manifest files. It provides AI-powered risk assessment beyond what Dependabot offers:
flagging major version bumps, known-vulnerable packages, and unusual transitive deps.

**Trigger:** `pull_request` (opened, synchronize, reopened) touching `package.json`,
`package-lock.json`, `go.mod`, `go.sum`, `requirements.txt`, `Pipfile`, `Pipfile.lock`,
`Gemfile`, `Gemfile.lock`, `Cargo.toml`, `Cargo.lock`, `pyproject.toml`, `pom.xml`,
`build.gradle`, `build.gradle.kts`
**Outputs:** PR comment with risk assessment

---

## Scenario 1: Major version bump detected

**Given** a PR bumps a dependency from v1.x to v2.x in `package.json`
**When** the PR is opened or updated
**Then**
- the workflow extracts the before/after versions from the diff
- Claude assesses the risk of the major version change
- a PR comment is posted with risk rating (LOW / MEDIUM / HIGH / CRITICAL)
- the comment identifies potential breaking changes and migration notes

**Assertions:**
- A PR comment is created by the bot
- The comment contains a risk rating section
- The comment references the specific package and version change

---

## Scenario 2: No dependency files changed

**Given** a PR only modifies source code (no dep manifests)
**When** the PR is opened
**Then**
- the workflow is not triggered (path filter excludes it)

**Assertions:**
- The `dependency-advisory` check does not appear in the PR checks list

---

## Scenario 3: New direct dependency added

**Given** a PR adds a new package to `requirements.txt` that was not previously present
**When** the PR is opened
**Then**
- Claude checks whether the package has known CVEs or is unusually new/unvetted
- the comment flags risk level and suggests review of the package's maintenance status

**Assertions:**
- PR comment mentions the new package by name
- Comment includes a maintenance/reputation note

---

## Scenario 4: Multiple dep files changed in one PR

**Given** a PR modifies both `package.json` and `go.mod`
**When** the PR is opened
**Then**
- the workflow analyses changes across all modified dep files
- the comment groups findings by file

**Assertions:**
- PR comment has at least one section per changed dep file
- No duplicate comments are posted on re-push

---

## Scenario 5: Bot PR (Dependabot)

**Given** a Dependabot PR touches `package.json`
**When** the PR is opened
**Then**
- the advisory skips or runs with a reduced scope
- no blocking comment is posted for routine patch/minor bumps from Dependabot

**Assertions:**
- Workflow runs without error
- Comment (if posted) is non-blocking for patch/minor bumps

---

## Scenario 6: Dep file changed but diff is only a lockfile regeneration

**Given** only `package-lock.json` changes (no `package.json` version changes)
**When** the PR is opened
**Then**
- Claude recognises this is a lockfile-only change
- comment notes "lockfile regeneration — no direct version changes detected"

**Assertions:**
- PR comment is posted and indicates lockfile-only change
- Risk rating is LOW
