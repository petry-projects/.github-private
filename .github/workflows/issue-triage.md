---
on:
  issues:
    types: [opened]
engine: claude-sonnet-4-6
permissions:
  issues: read
safe-outputs:
  add-labels:
    allowed:
      - bug
      - enhancement
      - documentation
      - question
      - needs-triage
      - good-first-issue
      - security
    max: 3
---

# Issue Triage

You are triaging a new GitHub issue for the `${REPO}` repository.

## Context

- **Repository:** `${REPO}`
- **Issue:** [#${ISSUE_NUMBER}](${ISSUE_URL}): ${ISSUE_TITLE}
- **Labels already applied:** ${ISSUE_LABELS}

**Issue body:**

${ISSUE_BODY}

## Task

If the issue already has **2 or more labels**, output `{"skip": true}` and stop — do not classify, do not comment.

Otherwise:

1. **Classify** the issue into the best-fit category:
   - `bug` — something is not working as expected
   - `enhancement` — request for new or extended functionality
   - `documentation` — unclear, missing, or incorrect docs
   - `question` — user asking how to do something
   - `security` — potential security vulnerability
   - `good-first-issue` — simple enough for a first-time contributor

2. **Select ≤ 3 labels** from the allowed set:
   `bug`, `enhancement`, `documentation`, `question`, `needs-triage`,
   `good-first-issue`, `security`.
   - Add `needs-triage` for bugs and ambiguous reports that need human review.
   - Add `good-first-issue` only when the scope is clearly small and
     self-contained.

3. **Write one welcoming comment** that:
   - Opens warmly and thanks the contributor.
   - Asks the **single most important** clarifying question for this issue type:
     - Bug → steps to reproduce + expected vs actual behaviour
     - Feature → use case / motivation
     - Question → what docs they checked and where they got stuck
     - Documentation → which page or section is unclear and what they expected
     - Security → (do not ask for details publicly; ask them to use the
       private security advisory channel)
   - Does **not** ask multiple unrelated questions.
   - Is concise (≤ 5 sentences).

## Output format

Output **exactly one** JSON object — no markdown fences, no preamble:

For a normal triage:
{"labels": ["label1", "label2"], "comment": "Your welcoming comment here."}

For a skip (issue already has 2+ labels):
{"skip": true}
