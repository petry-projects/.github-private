# Issue Triage — Scenario Spec

This spec defines the expected triage behaviour for representative inputs. All
scenarios must be validated before the workflow is promoted to live.

---

## Scenario 1 — Bug report (no labels)

**Input:**
- Title: `Login button is broken`
- Body: `When I click the login button nothing happens.`
- Existing labels: _(none)_

**Expected output:**
- Labels applied: `bug`, `needs-human-review`
- Comment posted: yes — asks for steps to reproduce and expected vs actual
  behaviour (e.g. "Could you share the steps to reproduce this? What did you
  expect to happen, and what actually happened instead?")

---

## Scenario 2 — Feature request (no labels)

**Input:**
- Title: `Add dark mode support`
- Body: `It would be great if the app supported dark mode.`
- Existing labels: _(none)_

**Expected output:**
- Labels applied: `enhancement`
- Comment posted: yes — acknowledges the feature request and asks about the
  use case (e.g. "Thanks for the suggestion! Could you tell us a bit more
  about your use case — how would dark mode help your workflow?")

---

## Scenario 3 — Question (no labels)

**Input:**
- Title: `How do I configure X?`
- Body: `I'm trying to configure X but can't find any documentation.`
- Existing labels: _(none)_

**Expected output:**
- Labels applied: `question`
- Comment posted: yes — points to docs and asks what the user has already
  tried (e.g. "Have you had a chance to check the docs at …? If so, what
  step are you getting stuck on?")

---

## Scenario 4 — Already labelled (edge case: no-op)

**Input:**
- Title: `Something is wrong`
- Body: `Not sure what's happening.`
- Existing labels: `bug`, `P1`  _(2 labels — threshold met)_

**Expected output:**
- Labels applied: _(none)_
- Comment posted: _(none)_
- Workflow exits silently (skip, no changes, no comment)

---

## Validation notes

- The allowed label set is: `bug`, `enhancement`, `documentation`, `question`,
  `needs-human-review`, `good first issue`, `security`.
- At most **3 labels** may be applied in a single run.
- The comment must be a **single** welcoming message; it must not ask multiple
  unrelated questions.
- For Scenario 4 the JSON output must be `{"skip": true}` and the safe-output
  step must apply zero GitHub API writes.
