# Release Notes Generator — Test Scenarios

## Context

Triggered on every push to `main`. Finds PRs merged as part of that push, filters for
`feat` or `fix` labeled PRs, generates structured CHANGELOG entries using Claude, and
opens a PR updating `CHANGELOG.md`. Follows Keep-a-Changelog convention with sections
grouped by Added / Fixed / Changed.

Idempotency rule: if a PR updating CHANGELOG.md already exists for the same head SHA,
no second PR is opened.

---

## Scenario 1 — Push with feat/fix PRs: open changelog PR

**Input:**
- Push to `main` (before SHA → after SHA)
- Merged PRs in that push range include at least one PR labeled `feat` or `fix`
  - Example: PR #10 "Add user authentication" (label: `feat`)
  - Example: PR #11 "Fix null pointer in login flow" (label: `fix`)

**Expected:**
- `CHANGELOG.md` is updated with new entries:
  - Under `[Unreleased]` or a new version header
  - `### Added` section lists the `feat` PR
  - `### Fixed` section lists the `fix` PR
  - Entries include PR number and short description
- A new PR is opened against `main` with title `chore: update CHANGELOG for <short-sha>`
- PR body summarizes the changes included

---

## Scenario 2 — Push with only chore/ci PRs: no changelog PR

**Input:**
- Push to `main`
- Merged PRs in that push range are labeled only `chore` or `ci` (no `feat` or `fix`)
  - Example: PR #12 "Update GitHub Actions versions" (label: `ci`)
  - Example: PR #13 "Bump dependencies" (label: `chore`)

**Expected:**
- No PR is opened
- No `CHANGELOG.md` modification
- Workflow exits cleanly with a notice: "No feat/fix PRs found — skipping changelog"

---

## Scenario 3 (Edge) — CHANGELOG.md does not exist: create with header

**Input:**
- Push to `main` with at least one `feat` or `fix` PR
- `CHANGELOG.md` does not exist in the repository

**Expected:**
- `CHANGELOG.md` is created with the Keep-a-Changelog header:
  ```markdown
  # Changelog

  All notable changes to this project will be documented in this file.

  The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
  ```
- New entries are appended below the header
- A PR is opened with the new file

---

## Scenario 4 (Edge) — Duplicate run for same SHA: no second PR

**Input:**
- Push to `main` triggers the workflow
- A CHANGELOG update PR for this push's SHA already exists (open or merged)

**Expected:**
- Workflow detects the existing PR (searching by SHA marker in PR title or body)
- Workflow exits without opening a second PR
- Notice logged: "CHANGELOG PR already exists for SHA `<sha>` — skipping"

---

## Scenario 5 (Edge) — Push with mixed labels: include feat/fix, skip chore/ci

**Input:**
- Push to `main` with multiple PRs:
  - PR #14 "Add export feature" (label: `feat`)
  - PR #15 "Refactor internals" (label: `chore`)
  - PR #16 "Fix broken export path" (label: `fix`)

**Expected:**
- CHANGELOG entries generated only for PRs #14 and #16
- PR #15 is omitted from the CHANGELOG
- PR opened with the filtered entries

---

## DRY_RUN behavior

When `DRY_RUN=true` (the default staged configuration):
- Workflow identifies merged PRs and filters for `feat`/`fix` labels
- Claude generates the CHANGELOG content
- Generated content is printed to the step summary
- No branch is created, no `CHANGELOG.md` file is written, no PR is opened
- Output: step summary showing the generated CHANGELOG entries and the PR that would be opened
